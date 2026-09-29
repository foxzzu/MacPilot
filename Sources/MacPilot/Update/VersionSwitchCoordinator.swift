import Foundation

/// Canonical locations for everything the Version Manager owns on disk.
enum VersionManagerPaths {
    static var configurationDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppIdentity.configurationDirectoryName, isDirectory: true)
    }

    static var rootDirectory: URL {
        configurationDirectory.appendingPathComponent("VersionManager", isDirectory: true)
    }

    /// Where the standalone recovery helper lives inside a version switch.
    static var recoveryHelperDirectory: URL {
        rootDirectory.appendingPathComponent("Recovery", isDirectory: true)
    }

    static func successTokenURL(id: UUID) -> URL {
        UpdateSuccessTokenStore.directory(rootDirectory: rootDirectory)
            .appendingPathComponent("\(id.uuidString).json")
    }
}

enum VersionSwitchError: Error, Equatable {
    case alreadyRunning
    case sameVersion
    case configurationFlushFailed
    case restoreTargetMissingRelease
    case restoreTargetUnsupported
    case updaterLaunchFailed(String)
}

/// Orchestrates one complete version switch.
///
/// The order is deliberate and must not be reordered: the target package is
/// fully downloaded and verified *before* any configuration work starts, the
/// configuration is frozen and flushed *before* the snapshot, the snapshot is
/// verified *before* the update channel is touched, and only then is the
/// validated package handed to MacPilotUpdater. Every step is journaled into
/// `VersionManager/transactions/active.json` so a crash leaves an accurate
/// record for the next launch.
@MainActor
final class VersionSwitchCoordinator: ObservableObject {
    @Published private(set) var phase: VersionSwitchPhase?
    @Published private(set) var activeTransaction: VersionSwitchTransaction?

    let updater: SoftwareUpdater
    let snapshotManager: ConfigurationSnapshotManager
    let transactionStore: VersionSwitchTransactionStore
    let pendingRestoreStore: PendingConfigurationRestoreStore
    let recovery: AppRecoveryManager
    let fileManager: FileManager

    private let currentVersion: () -> String
    private let currentChannel: () -> AppChannel
    private let remoteClientIDs: () -> [String]
    private let mergedConfiguration: () -> Data?
    private let flushConfiguration: () throws -> Void
    private let applyChannelChange: (AppChannel) -> Void
    private let beginSwitching: () -> Void
    private let endSwitching: () -> Void
    private let applicationURL: () -> URL

    /// Injectable seams. Production values funnel into the one shared
    /// download/validate/install chain; tests replace them so a coordinator
    /// transaction can run without network or a real app replacement.
    var packageAcquirer: (SoftwareRelease) async throws -> VerifiedUpdatePackage
    var installer: (VerifiedUpdatePackage, UUID?) throws -> Void
    var terminateAfterInstall: () -> Void

    init(
        updater: SoftwareUpdater,
        snapshotManager: ConfigurationSnapshotManager,
        transactionStore: VersionSwitchTransactionStore,
        pendingRestoreStore: PendingConfigurationRestoreStore,
        recovery: AppRecoveryManager,
        fileManager: FileManager = .default,
        currentVersion: @escaping () -> String,
        currentChannel: @escaping () -> AppChannel,
        remoteClientIDs: @escaping () -> [String],
        mergedConfiguration: @escaping () -> Data?,
        flushConfiguration: @escaping () throws -> Void,
        applyChannelChange: @escaping (AppChannel) -> Void,
        beginSwitching: @escaping () -> Void,
        endSwitching: @escaping () -> Void,
        applicationURL: @escaping () -> URL = { Bundle.main.bundleURL }
    ) {
        self.updater = updater
        self.snapshotManager = snapshotManager
        self.transactionStore = transactionStore
        self.pendingRestoreStore = pendingRestoreStore
        self.recovery = recovery
        self.fileManager = fileManager
        self.currentVersion = currentVersion
        self.currentChannel = currentChannel
        self.remoteClientIDs = remoteClientIDs
        self.mergedConfiguration = mergedConfiguration
        self.flushConfiguration = flushConfiguration
        self.applyChannelChange = applyChannelChange
        self.beginSwitching = beginSwitching
        self.endSwitching = endSwitching
        self.applicationURL = applicationURL
        self.packageAcquirer = { release in
            try await updater.downloadAndValidate(release)
        }
        self.installer = { package, successTokenID in
            try updater.launchInstaller(for: package, successTokenID: successTokenID)
        }
        self.terminateAfterInstall = { updater.requestTerminateAfterInstall() }
    }

    /// Whether a version switch currently owns the app. Shared with the
    /// updater, the menu bar and the settings UI so nothing else can start a
    /// concurrent update, channel change, or second install.
    var isSwitching: Bool { phase != nil }

    func performSwitch(
        to release: SoftwareRelease,
        intent: InstallationIntent,
        targetSupportsRestore: Bool = false,
        restoreSnapshot: ConfigurationSnapshotManifest? = nil
    ) async throws {
        guard !isSwitching else { throw VersionSwitchError.alreadyRunning }
        guard release.version != SoftwareVersion(currentVersion()) else {
            throw VersionSwitchError.sameVersion
        }
        if restoreSnapshot != nil {
            // A pending restore can only be consumed by a target that runs the
            // Version Manager itself; otherwise the restore request would sit
            // there unconsumed forever.
            guard intent.allowsConfigurationRestore, targetSupportsRestore else {
                throw VersionSwitchError.restoreTargetUnsupported
            }
        }

        beginSwitching()
        try await runSwitch(
            to: release,
            intent: intent,
            restoreSnapshot: restoreSnapshot,
            prevalidatedPackage: nil,
            initialPhase: .downloading
        )
    }

    /// Entry for a manual install that already downloaded and validated its
    /// package through `SoftwareUpdater.install(release:intent:)`.
    func runTransaction(
        for release: SoftwareRelease,
        intent: InstallationIntent,
        package: VerifiedUpdatePackage
    ) async throws {
        guard !isSwitching else { throw VersionSwitchError.alreadyRunning }
        beginSwitching()
        try await runSwitch(
            to: release,
            intent: intent,
            restoreSnapshot: nil,
            prevalidatedPackage: package,
            initialPhase: .verifyingPackage
        )
    }

    private func runSwitch(
        to release: SoftwareRelease,
        intent: InstallationIntent,
        restoreSnapshot: ConfigurationSnapshotManifest?,
        prevalidatedPackage: VerifiedUpdatePackage?,
        initialPhase: VersionSwitchPhase
    ) async throws {
        var transaction = VersionSwitchTransaction(
            id: UUID(),
            sourceVersion: currentVersion(),
            sourceChannel: currentChannel(),
            targetVersion: release.version.description,
            targetChannel: release.isPrerelease ? .beta : .stable,
            intent: intent,
            startedAt: Date(),
            snapshotID: nil,
            restoreSnapshotID: restoreSnapshot?.id,
            phase: initialPhase,
            updatedAt: Date()
        )
        phase = initialPhase
        activeTransaction = transaction
        try? transactionStore.save(transaction)

        var package: VerifiedUpdatePackage?
        var didChangeChannel = false
        do {
            if let prevalidatedPackage {
                package = prevalidatedPackage
            } else {
                package = try await packageAcquirer(release)
            }
            transaction.phase = .verifyingPackage
            transaction.updatedAt = Date()
            try transactionStore.save(transaction)

            transaction.phase = .preparingConfiguration
            transaction.updatedAt = Date()
            phase = .preparingConfiguration
            activeTransaction = transaction
            try transactionStore.save(transaction)
            try flushConfiguration()

            transaction.phase = .snapshotting
            transaction.updatedAt = Date()
            phase = .snapshotting
            activeTransaction = transaction
            try transactionStore.save(transaction)

            // First the recovery ZIP (still needs the current bundle on
            // disk), then the configuration snapshot. Both sizes were part of
            // the disk-space estimate inside the snapshot manager.
            let recoveryInfo = try recovery.createRecoveryZIP(
                appURL: applicationURL(),
                version: currentVersion()
            )
            let context = ConfigurationSnapshotManager.SnapshotContext(
                sourceAppVersion: currentVersion(),
                sourceChannel: currentChannel(),
                targetVersion: release.version.description,
                targetChannel: release.isPrerelease ? .beta : .stable,
                intent: intent,
                remoteClientIDs: remoteClientIDs(),
                mergedConfiguration: mergedConfiguration(),
                appRecovery: recoveryInfo
            )
            let snapshot = try snapshotManager.create(
                context: context,
                additionalBytes: recoveryInfo.size
            )
            transaction.snapshotID = snapshot.manifest.id
            transaction.updatedAt = Date()

            transaction.phase = .readyToInstall
            phase = .readyToInstall
            activeTransaction = transaction
            try transactionStore.save(transaction)

            // The channel preference follows the explicitly chosen release.
            // This happens strictly after the snapshot captured the original
            // value; a restore additionally reuses the protected channel.
            let targetChannel = restoreSnapshot?.sourceChannel ?? (release.isPrerelease ? .beta : .stable)
            applyChannelChange(targetChannel)
            didChangeChannel = true
            try flushConfiguration()

            if let restoreSnapshot {
                try pendingRestoreStore.save(PendingConfigurationRestore(
                    snapshotID: restoreSnapshot.id,
                    transactionID: transaction.id,
                    requestedAt: Date(),
                    restoreKeychain: true
                ))
            }
            copyRecoveryHelperIfNeeded()

            if intent == .manualDowngrade || (restoreSnapshot == nil && release.relation(to: currentVersion()) == .older) {
                let records = snapshotManager.loadSnapshots()
                if let record = records.first(where: { $0.manifest.id == snapshot.manifest.id }) {
                    snapshotManager.activate(record)
                }
            }

            transaction.phase = .replacingApplication
            transaction.updatedAt = Date()
            phase = .replacingApplication
            activeTransaction = transaction
            try transactionStore.save(transaction)
            guard let package else { throw VersionSwitchError.updaterLaunchFailed("package missing") }
            try installer(package, transaction.id)

            transaction.phase = .awaitingRelaunch
            transaction.updatedAt = Date()
            phase = .awaitingRelaunch
            activeTransaction = transaction
            try? transactionStore.save(transaction)
            terminateAfterInstall()
        } catch {
            var failed = transaction
            failed.phase = .failed
            failed.updatedAt = Date()
            transactionStore.archive(failed)
            pendingRestoreStore.clear()
            if didChangeChannel {
                // The snapshot protected the original channel preference; an
                // install that never happened must not leave the new one.
                applyChannelChange(transaction.sourceChannel)
            }
            if let package {
                try? FileManager.default.removeItem(at: package.workingDirectory)
            }
            phase = nil
            activeTransaction = nil
            endSwitching()
            throw error
        }
    }

    /// Ships the standalone recovery helper next to the snapshots so a
    /// downgrade to a Version-Manager-less release keeps an external way back.
    private func copyRecoveryHelperIfNeeded() {
        let bundledHelper = applicationURL().appendingPathComponent("Contents/MacOS/MacPilotRecovery")
        guard fileManager.isExecutableFile(atPath: bundledHelper.path) else { return }
        try? fileManager.createDirectory(at: VersionManagerPaths.recoveryHelperDirectory, withIntermediateDirectories: true)
        let destination = VersionManagerPaths.recoveryHelperDirectory
            .appendingPathComponent("MacPilotRecovery", isDirectory: false)
        try? fileManager.removeItem(at: destination)
        try? fileManager.copyItem(at: bundledHelper, to: destination)
    }
}

/// Resolves whatever a previous version switch left behind. Runs at the very
/// start of app initialization, before the configuration store reads anything:
/// this is the only place a pending restore is allowed to touch files.
enum VersionSwitchStartup {
    @MainActor
    static func run(
        rootDirectory: URL = VersionManagerPaths.rootDirectory,
        configDirectory: URL = VersionManagerPaths.configurationDirectory,
        runningVersion: String = AppVersionInfo.current().version
    ) {
        // The new version is up and loading its configuration: the previous
        // app bundle kept by the updater is no longer needed.
        UpdateSuccessTokenStore.completeAll(rootDirectory: rootDirectory)

        let snapshotManager = ConfigurationSnapshotManager(
            rootDirectory: rootDirectory,
            configDirectory: configDirectory
        )
        let pendingStore = PendingConfigurationRestoreStore(rootDirectory: rootDirectory)
        if let pending = pendingStore.load() {
            if let record = snapshotManager.loadSnapshots().first(where: { $0.manifest.id == pending.snapshotID }) {
                do {
                    try snapshotManager.restore(
                        record.manifest,
                        applyPreferences: true,
                        restoreKeychain: pending.restoreKeychain
                    )
                    pendingStore.clear()
                    DiagnosticLog.write("SoftwareUpdate", "Version switch restored snapshot \(pending.snapshotID)")
                } catch {
                    // Leave the request in place: the next launch retries the
                    // restore instead of continuing with a half-applied state.
                    DiagnosticLog.write(
                        "SoftwareUpdate",
                        "Version switch restore failed: \(String(describing: error))"
                    )
                }
            } else {
                // The snapshot it references is gone; keeping the request
                // would block every future restore.
                pendingStore.clear()
            }
        }

        let store = VersionSwitchTransactionStore(rootDirectory: rootDirectory)
        guard var transaction = store.loadActive() else { return }
        switch transaction.phase {
        case .replacingApplication, .awaitingRelaunch, .runningTarget:
            transaction.phase = .completed
            transaction.updatedAt = Date()
            store.archive(transaction)
            DiagnosticLog.write(
                "SoftwareUpdate",
                "Version switch completed: \(transaction.sourceVersion) -> \(transaction.targetVersion)"
            )
        default:
            // Interrupted before the updater ever replaced the app. Nothing
            // was modified; keep the record for diagnosis.
            transaction.phase = .failed
            transaction.updatedAt = Date()
            store.archive(transaction)
            DiagnosticLog.write(
                "SoftwareUpdate",
                "Version switch abandoned in phase \(transaction.phase.rawValue)"
            )
        }
    }
}

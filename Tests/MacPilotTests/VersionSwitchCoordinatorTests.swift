import Foundation
import Testing
@testable import MacPilot

/// 方案第七、八、四十、四十七、五十一节：版本切换是事务；所有安装走同一
/// 链路；并发期间全局锁定；故障注入后配置不得丢失。这里覆盖
/// Stable→新/旧 Stable、Stable→Beta、Beta→新/旧 Beta、Beta→Stable 全组合。
@MainActor
struct VersionSwitchCoordinatorTests {
    private let fileManager = FileManager.default

    @MainActor
    final class SwitchLog {
        var begins = 0
        var ends = 0
        var channels: [AppChannel] = []
    }

    struct World {
        let base: URL
        let config: URL
        let coordinator: VersionSwitchCoordinator
        let snapshotManager: ConfigurationSnapshotManager
        let transactionStore: VersionSwitchTransactionStore
        let pendingStore: PendingConfigurationRestoreStore
        let log: SwitchLog

        func archivedTransactions() -> [VersionSwitchTransaction] {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: transactionStore.directory, includingPropertiesForKeys: nil
            )) ?? []
            return files.filter { $0.lastPathComponent != "active.json" }.compactMap { url in
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                return (try? Data(contentsOf: url)).flatMap { try? decoder.decode(VersionSwitchTransaction.self, from: $0) }
            }
        }
    }

    private let fileManagerForWorld = FileManager.default

    private func makeWorld(
        sourceVersion: String,
        sourceChannel: AppChannel
    ) -> World {
        let base = fileManager.temporaryDirectory
            .appendingPathComponent("CoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        // 版本管理根、配置目录、App 目录彼此分离（与生产布局一致：
        // recovery ZIP 永远不会归档到它自己的输出目录里）。
        let appDirectory = base.appendingPathComponent("App", isDirectory: true)
        let config = base.appendingPathComponent("MacPilot", isDirectory: true)
        let vmRoot = base.appendingPathComponent("VersionManager", isDirectory: true)
        try! fileManager.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        try! fileManager.createDirectory(at: config, withIntermediateDirectories: true)
        try! Data(#"{"quitAfter":30}"#.utf8).write(to: config.appendingPathComponent("config.json"))

        let updater = SoftwareUpdater(currentVersion: sourceVersion, applicationURL: appDirectory)
        let snapshotManager = ConfigurationSnapshotManager(
            rootDirectory: vmRoot,
            configDirectory: config,
            keychainManager: KeychainSnapshotManager(
                secretStore: InMemorySecretStore(),
                remoteService: "test.remote",
                screenService: "test.app",
                screenAccount: "tester"
            ),
            recovery: AppRecoveryManager(rootDirectory: vmRoot)
        )
        let transactionStore = VersionSwitchTransactionStore(rootDirectory: vmRoot)
        let pendingStore = PendingConfigurationRestoreStore(rootDirectory: vmRoot)
        let recovery = AppRecoveryManager(rootDirectory: vmRoot)
        let log = SwitchLog()

        let coordinator = VersionSwitchCoordinator(
            updater: updater,
            snapshotManager: snapshotManager,
            transactionStore: transactionStore,
            pendingRestoreStore: pendingStore,
            recovery: recovery,
            currentVersion: { sourceVersion },
            currentChannel: { sourceChannel },
            remoteClientIDs: { [] },
            mergedConfiguration: { nil },
            flushConfiguration: {},
            applyChannelChange: { log.channels.append($0) },
            beginSwitching: { log.begins += 1 },
            endSwitching: { log.ends += 1 },
            applicationURL: { appDirectory }
        )
        return World(
            base: base,
            config: config,
            coordinator: coordinator,
            snapshotManager: snapshotManager,
            transactionStore: transactionStore,
            pendingStore: pendingStore,
            log: log
        )
    }

    private func stubInstall(_ world: World) {
        world.coordinator.packageAcquirer = { _ in
            VerifiedUpdatePackage(
                applicationURL: world.base.appendingPathComponent("Target.app"),
                workingDirectory: world.base.appendingPathComponent("staging-\(UUID().uuidString)")
            )
        }
        world.coordinator.installer = { _, _ in }
        world.coordinator.terminateAfterInstall = {}
    }

    private func release(_ version: String, prerelease: Bool = false) -> SoftwareRelease {
        SoftwareRelease(
            version: SoftwareVersion(version)!,
            releaseNotes: "",
            archiveURL: URL(string: "https://github.com/misswell/MacPilot/releases/download/v\(version)/MacPilot-\(version)-arm64-macos.zip")!,
            sha256: String(repeating: "d", count: 64),
            isPrerelease: prerelease
        )
    }

    @Test func combinationsCoverEveryUpgradeDowngradeAndChannelMove() async throws {
        // (源版本, 源通道, 目标, 目标是否预发布, 预期通道)
        let combinations: [(String, AppChannel, String, Bool, AppChannel)] = [
            ("1.1.479", .stable, "1.1.480", false, .stable),      // Stable → 新 Stable
            ("1.1.479", .stable, "1.1.478", false, .stable),      // Stable → 旧 Stable
            ("1.1.479", .stable, "1.2.0-beta.1", true, .beta),    // Stable → Beta
            ("1.2.0-beta.4", .beta, "1.2.0-beta.5", true, .beta), // Beta → 新 Beta
            ("1.2.0-beta.4", .beta, "1.2.0-beta.3", true, .beta), // Beta → 旧 Beta
            ("1.2.0-beta.4", .beta, "1.1.479", false, .stable)    // Beta → Stable
        ]
        for (sourceVersion, sourceChannel, targetVersion, targetPrerelease, expectedChannel) in combinations {
            let world = makeWorld(sourceVersion: sourceVersion, sourceChannel: sourceChannel)
            defer { try? fileManager.removeItem(at: world.base) }
            stubInstall(world)

            let target = release(targetVersion, prerelease: targetPrerelease)
            let intent: InstallationIntent = target.relation(to: sourceVersion) == .newer
                ? .manualUpgrade
                : .manualDowngrade

            try await world.coordinator.performSwitch(to: target, intent: intent)

            #expect(world.transactionStore.loadActive()?.phase == .awaitingRelaunch)
            let snapshots = world.snapshotManager.loadSnapshots()
            #expect(snapshots.count == 1, "\(sourceVersion) -> \(targetVersion)")
            #expect(snapshots.first?.manifest.sourceAppVersion == sourceVersion)
            #expect(snapshots.first?.manifest.targetAppVersion == targetVersion)
            #expect(snapshots.first?.manifest.intent == intent)
            #expect(world.log.channels == [expectedChannel])
            #expect(world.log.begins == 1 && world.log.ends == 0, "成功切换保持全局锁定直到退出")
            #expect(world.coordinator.phase == .awaitingRelaunch)
            // 恢复包记录了源版本；外部恢复路径（Recovery Helper）依赖它。
            #expect(snapshots.first?.manifest.appRecovery != nil)
        }
    }

    @Test func downgradeMarksTheSnapshotAsActiveProtection() async throws {
        let world = makeWorld(sourceVersion: "1.2.0-beta.4", sourceChannel: .beta)
        defer { try? fileManager.removeItem(at: world.base) }
        stubInstall(world)

        try await world.coordinator.performSwitch(
            to: release("1.1.479"),
            intent: .manualDowngrade
        )
        #expect(world.snapshotManager.loadSnapshots().first?.manifest.status == .downgradeActive)
    }

    @Test func upgradeKeepsTheSnapshotAsPlainHistory() async throws {
        let world = makeWorld(sourceVersion: "1.1.479", sourceChannel: .stable)
        defer { try? fileManager.removeItem(at: world.base) }
        stubInstall(world)

        try await world.coordinator.performSwitch(
            to: release("1.1.480"),
            intent: .manualUpgrade
        )
        #expect(world.snapshotManager.loadSnapshots().first?.manifest.status == .ready)
    }

    @Test func secondSwitchWhileOneIsRunningIsRefused() async {
        let world = makeWorld(sourceVersion: "1.1.479", sourceChannel: .stable)
        defer { try? fileManager.removeItem(at: world.base) }
        stubInstall(world)
        // 挂起第一次切换：acquirer 永不返回。
        let gate = PendingState()
        world.coordinator.packageAcquirer = { _ in
            await gate.wait()
            return VerifiedUpdatePackage(
                applicationURL: world.base.appendingPathComponent("Target.app"),
                workingDirectory: world.base
            )
        }
        world.coordinator.installer = { _, _ in }
        world.coordinator.terminateAfterInstall = {}

        let firstTask = Task {
            try await world.coordinator.performSwitch(
                to: release("1.1.480"), intent: .manualUpgrade
            )
        }
        // 等 acquirer 真正挂起后再尝试并发第二次切换。
        try? await Task.sleep(for: .milliseconds(80))
        await #expect(throws: VersionSwitchError.alreadyRunning) {
            try await world.coordinator.performSwitch(to: release("1.1.481"), intent: .manualUpgrade)
        }
        gate.open()
        _ = try? await firstTask.value
        // 成功的切换刻意保留全局锁直到应用重启（updater 接管后随即退出）；
        // 失败路径的解锁由 downloadFailureLeavesConfigurationAndChannelUntouched 覆盖。
        #expect(world.coordinator.isSwitching)
        #expect(world.coordinator.phase == .awaitingRelaunch)
    }

    @Test func sameVersionSwitchIsRejected() async {
        let world = makeWorld(sourceVersion: "1.1.479", sourceChannel: .stable)
        defer { try? fileManager.removeItem(at: world.base) }
        stubInstall(world)

        await #expect(throws: VersionSwitchError.sameVersion) {
            try await world.coordinator.performSwitch(to: release("1.1.479"), intent: .manualUpgrade)
        }
        #expect(!world.coordinator.isSwitching)
        #expect(world.snapshotManager.loadSnapshots().isEmpty)
    }

    @Test func restoreToTargetWithoutVersionManagerIsRefused() async {
        let world = makeWorld(sourceVersion: "1.1.479", sourceChannel: .stable)
        defer { try? fileManager.removeItem(at: world.base) }
        stubInstall(world)

        await #expect(throws: VersionSwitchError.restoreTargetUnsupported) {
            try await world.coordinator.performSwitch(
                to: release("1.1.100"),
                intent: .manualUpgrade,
                targetSupportsRestore: false,
                restoreSnapshot: Self.makeManifest(source: "1.2.0-beta.4", target: "1.1.100", status: .ready)
            )
        }
    }

    @Test func downloadFailureLeavesConfigurationAndChannelUntouched() async {
        let world = makeWorld(sourceVersion: "1.1.479", sourceChannel: .stable)
        defer { try? fileManager.removeItem(at: world.base) }
        struct DownloadFailed: Error {}
        world.coordinator.packageAcquirer = { _ in throw DownloadFailed() }

        await #expect(throws: DownloadFailed.self) {
            try await world.coordinator.performSwitch(to: release("1.1.478"), intent: .manualDowngrade)
        }
        #expect(world.log.channels.isEmpty, "失败时绝不改通道")
        #expect(world.snapshotManager.loadSnapshots().isEmpty, "下载失败不产生任何快照")
        #expect(world.log.begins == 1 && world.log.ends == 1, "失败后释放全局锁")
        let archived = world.archivedTransactions()
        #expect(archived.count == 1)
        #expect(archived.first?.phase == .failed)
        #expect(world.transactionStore.loadActive() == nil)
    }

    @Test func snapshotFailureBlocksTheInstallAndKeepsOriginalChannel() async {
        let world = makeWorld(sourceVersion: "1.1.479", sourceChannel: .stable)
        defer { try? fileManager.removeItem(at: world.base) }
        stubInstall(world)
        // 注入快照失败：把快照根变成一个文件，快照目录创建必然抛错。
        let blocker = world.base
            .appendingPathComponent("VersionManager/snapshots")
        try? fileManager.createDirectory(at: blocker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("x".utf8).write(to: blocker)

        do {
            try await world.coordinator.performSwitch(to: release("1.1.478"), intent: .manualDowngrade)
            Issue.record("switch should have failed")
        } catch {
            // 预期失败
        }
        #expect(world.log.channels.isEmpty)
        #expect(world.log.ends == 1, "失败后释放全局锁")
        #expect(world.archivedTransactions().first?.phase == .failed)
    }

    @Test func pendingRestoreIsWrittenBeforeInstallForRestoreSwitches() async throws {
        let world = makeWorld(sourceVersion: "1.1.479", sourceChannel: .stable)
        defer { try? fileManager.removeItem(at: world.base) }
        stubInstall(world)

        let restoreManifest = Self.makeManifest(
            source: "1.2.0-beta.4", target: "1.1.479", status: .downgradeActive
        )
        try await world.coordinator.performSwitch(
            to: release("1.2.0-beta.4", prerelease: true),
            intent: .manualUpgrade,
            targetSupportsRestore: true,
            restoreSnapshot: restoreManifest
        )
        let pending = world.pendingStore.load()
        #expect(pending?.snapshotID == restoreManifest.id)
        #expect(pending?.restoreKeychain == true)
        // 恢复切换把通道还原为快照记录的原通道（Beta）。
        #expect(world.log.channels == [.beta])
    }

    private static func makeManifest(
        source: String, target: String, status: SnapshotStatus
    ) -> ConfigurationSnapshotManifest {
        ConfigurationSnapshotManifest(
            schemaVersion: 1,
            id: UUID(),
            createdAt: Date(),
            sourceAppVersion: source,
            sourceChannel: .beta,
            sourceConfigurationVersion: 26,
            targetAppVersion: target,
            targetChannel: .stable,
            intent: .manualDowngrade,
            files: [],
            includesRightClickDatabase: false,
            includesDockGroups: false,
            includesPreferences: false,
            includesKeychainBackup: true,
            clipboardContentBackedUp: false,
            keychain: KeychainSnapshotInfo(
                remotePairingItemCount: 1,
                screenCredentialPresent: true,
                remotePairingAccounts: ["A"]
            ),
            appRecovery: nil,
            status: status
        )
    }
}

private final class PendingState: @unchecked Sendable {
    nonisolated(unsafe) private var isOpen = false

    func open() {
        isOpen = true
    }

    func wait() async {
        while !isOpen {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

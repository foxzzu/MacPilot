import Foundation
import MacPilotRightClickKit

/// Creates, verifies, restores and retires configuration protection snapshots.
///
/// A snapshot is the mandatory precondition for a manual downgrade: it captures
/// the whole configuration surface (split config files, Dock Groups incl.
/// custom icons, the RightClick SQLite store via the backup API, the entire
/// UserDefaults persistent domain and in-Keychain copies of secrets) into a
/// persistent directory under `~/Library/Application Support/MacPilot/
/// VersionManager/snapshots/`, and every file is re-hashed before the snapshot
/// is allowed to protect anything.
///
/// Deliberately not copied: `Clipboard/` content files (potentially hundreds of
/// megabytes of user content). The manifest records that honestly via
/// `clipboardContentBackedUp == false`, and version switching never runs the
/// clipboard content store's cleanup paths.
struct ConfigurationSnapshotManager {
    /// The canonical file list lives with the store that writes those files.
    static var configurationFileNames: [String] { ConfigStore.snapshotFileNames }
    static let dockGroupsDirectoryName = "DockGroups"
    static let rightClickDatabaseRelativePath = "RightClick/RClickDatabase-v2.sqlite"
    static let rightClickSnapshotFileName = "RClickDatabase.snapshot.sqlite"
    static let preferencesFileName = "preferences.plist"
    static let mergedConfigurationFileName = "merged-config.json"
    static let manifestFileName = "manifest.json"
    static let safetyMarginBytes: UInt64 = 100 * 1_048_576
    static let maximumArchivedSnapshots = 5

    let rootDirectory: URL
    let configDirectory: URL
    let fileManager: FileManager
    let keychainManager: KeychainSnapshotManager
    let recovery: AppRecoveryManager

    init(
        rootDirectory: URL,
        configDirectory: URL,
        fileManager: FileManager = .default,
        keychainManager: KeychainSnapshotManager = KeychainSnapshotManager(),
        recovery: AppRecoveryManager? = nil
    ) {
        self.rootDirectory = rootDirectory
        self.configDirectory = configDirectory
        self.fileManager = fileManager
        self.keychainManager = keychainManager
        self.recovery = recovery ?? AppRecoveryManager(rootDirectory: rootDirectory)
    }

    var snapshotsDirectory: URL {
        rootDirectory.appendingPathComponent("snapshots", isDirectory: true)
    }

    var dockGroupsDirectory: URL {
        configDirectory.appendingPathComponent(Self.dockGroupsDirectoryName, isDirectory: true)
    }

    var rightClickDatabaseURL: URL {
        configDirectory.appendingPathComponent(Self.rightClickDatabaseRelativePath)
    }

    // MARK: - Creation

    struct CreateResult: Equatable {
        let manifest: ConfigurationSnapshotManifest
        let directory: URL
    }

    func create(context: SnapshotContext, additionalBytes: UInt64 = 0) throws -> CreateResult {
        let estimatedBytes = estimateConfigurationBytes() + additionalBytes + Self.safetyMarginBytes
        try ensureDiskSpace(availableForImportantUsage: estimatedBytes)

        // A new snapshot demotes the previous active protection to history:
        // only one downgrade test can be current at a time.
        for existing in loadSnapshots() where existing.manifest.status == .downgradeActive {
            updateStatus(of: existing, to: .ready)
        }

        let directory = snapshotsDirectory.appendingPathComponent(
            snapshotDirectoryName(context: context), isDirectory: true
        )
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var files: [SnapshotFile] = []
        var includesDockGroups = false
        var includesDatabase = false
        do {
            files += try copyConfigurationFiles(into: directory)
            if let merged = context.mergedConfiguration {
                let url = directory.appendingPathComponent(Self.mergedConfigurationFileName)
                try merged.write(to: url, options: .atomic)
                files.append(try snapshotFile(for: url, relativeTo: directory))
            }
            let dockResult = try copyDockGroups(into: directory)
            files += dockResult.files
            includesDockGroups = dockResult.copied
            let databaseResult = try copyRightClickDatabase(into: directory)
            files += databaseResult.files
            includesDatabase = databaseResult.copied
            files += try copyPreferences(into: directory)
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }

        let keychainInfo: KeychainSnapshotInfo
        do {
            keychainInfo = try keychainManager.create(
                snapshotID: context.snapshotID,
                remoteClientIDs: context.remoteClientIDs
            )
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }

        var manifest = ConfigurationSnapshotManifest(
            schemaVersion: ConfigurationSchemaSnapshot.manifestSchemaVersion,
            id: context.snapshotID,
            createdAt: Date(),
            sourceAppVersion: context.sourceAppVersion,
            sourceChannel: context.sourceChannel,
            sourceConfigurationVersion: ConfigurationSchema.configSchemaVersion(),
            targetAppVersion: context.targetVersion,
            targetChannel: context.targetChannel,
            intent: context.intent,
            files: files,
            includesRightClickDatabase: includesDatabase,
            includesDockGroups: includesDockGroups,
            includesPreferences: files.contains { $0.relativePath == Self.preferencesFileName },
            includesKeychainBackup: keychainInfo.keychainSnapshot,
            clipboardContentBackedUp: false,
            keychain: keychainInfo,
            appRecovery: context.appRecovery,
            status: .preparing
        )
        let manifestURL = directory.appendingPathComponent(Self.manifestFileName)
        do {
            try write(manifest, to: manifestURL)
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }

        // Nothing protects anything until the finished snapshot passes a full
        // re-hash plus parse/integrity pass. A failed snapshot refuses the
        // downgrade instead of degrading into a false sense of safety.
        do {
            try verify(manifest)
            manifest.status = .ready
            try write(manifest, to: manifestURL)
        } catch {
            manifest.status = .corrupted
            try? write(manifest, to: manifestURL)
            throw error
        }
        pruneSnapshots()
        return CreateResult(manifest: manifest, directory: directory)
    }

    struct SnapshotContext {
        let snapshotID = UUID()
        let sourceAppVersion: String
        let sourceChannel: AppChannel
        let targetVersion: String
        let targetChannel: AppChannel
        let intent: InstallationIntent
        let remoteClientIDs: [String]
        let mergedConfiguration: Data?
        var appRecovery: AppRecoveryInfo?
    }

    private func snapshotDirectoryName(context: SnapshotContext) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let stamp = formatter.string(from: Date())
        return "\(stamp)_\(context.sourceAppVersion)_to_\(context.targetVersion)"
    }

    // MARK: - Enumeration & lifecycle

    struct SnapshotRecord: Identifiable, Equatable {
        let manifest: ConfigurationSnapshotManifest
        let directory: URL
        let sizeBytes: UInt64

        var id: UUID { manifest.id }
    }

    func loadSnapshots() -> [SnapshotRecord] {
        let contents = (try? fileManager.contentsOfDirectory(
            at: snapshotsDirectory, includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        return contents
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .compactMap { directory -> SnapshotRecord? in
                guard let manifest = readManifest(at: directory) else { return nil }
                return SnapshotRecord(
                    manifest: manifest,
                    directory: directory,
                    sizeBytes: (try? fileManagerDirectorySize(directory)) ?? 0
                )
            }
            .sorted { $0.manifest.createdAt > $1.manifest.createdAt }
    }

    func readManifest(at directory: URL) -> ConfigurationSnapshotManifest? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(Self.manifestFileName)) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ConfigurationSnapshotManifest.self, from: data)
    }

    func updateStatus(of record: SnapshotRecord, to status: SnapshotStatus) {
        var manifest = record.manifest
        manifest.status = status
        try? write(manifest, to: record.directory.appendingPathComponent(Self.manifestFileName))
    }

    func activate(_ record: SnapshotRecord) {
        updateStatus(of: record, to: .downgradeActive)
    }

    /// Explicit user deletion. The active downgrade protection refuses to go
    /// away this way; automatic cleanup refuses as well (see `pruneSnapshots`).
    /// The on-disk manifest is re-read so a stale record cannot sneak past.
    func delete(_ record: SnapshotRecord) throws {
        guard let current = readManifest(at: record.directory) else {
            throw SnapshotManifestError.missingManifest
        }
        guard current.status != .downgradeActive else {
            throw SnapshotManifestError.cannotDeleteActiveSnapshot
        }
        keychainManager.remove(snapshotID: current.id, info: current.keychain)
        recovery.removeRecoveryZIP(for: current.appRecovery)
        try fileManager.removeItem(at: record.directory)
    }

    /// Keeps at most the newest `maximumArchivedSnapshots` completed
    /// snapshots. Active protection and corrupted-but-unresolved records are
    /// never auto-removed.
    func pruneSnapshots() {
        let records = loadSnapshots()
        let removable = records.filter {
            $0.manifest.status == .ready || $0.manifest.status == .restored || $0.manifest.status == .archived
        }
        guard removable.count > Self.maximumArchivedSnapshots else { return }
        for record in removable.suffix(from: Self.maximumArchivedSnapshots) {
            keychainManager.remove(snapshotID: record.manifest.id, info: record.manifest.keychain)
            try? fileManager.removeItem(at: record.directory)
        }
    }

    // MARK: - Verification

    /// Re-hashes every captured file and re-parses JSON / plist / SQLite so a
    /// half-written snapshot can never masquerade as a valid restore point.
    func verify(_ manifest: ConfigurationSnapshotManifest) throws {
        guard let directory = directory(for: manifest) else {
            throw SnapshotManifestError.missingManifest
        }
        for entry in manifest.files {
            let url = directory.appendingPathComponent(entry.relativePath)
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            guard size == entry.size else {
                throw SnapshotManifestError.integrityVerificationFailed(entry.relativePath)
            }
            let digest = try UpdatePackageValidator.sha256(of: url)
            guard digest == entry.sha256 else {
                throw SnapshotManifestError.integrityVerificationFailed(entry.relativePath)
            }
            try validateReadable(entry: entry, url: url)
        }
    }

    private func validateReadable(entry: SnapshotFile, url: URL) throws {
        if entry.relativePath == Self.preferencesFileName {
            _ = try PreferenceSnapshotManager.readSnapshot(from: url)
            return
        }
        if entry.relativePath.hasSuffix(".json") {
            let data = try Data(contentsOf: url)
            guard (try? JSONSerialization.jsonObject(with: data)) != nil else {
                throw SnapshotManifestError.integrityVerificationFailed(entry.relativePath)
            }
            return
        }
        if url.lastPathComponent == Self.rightClickSnapshotFileName {
            guard SQLiteSnapshot.integrityCheckSucceeds(url) else {
                throw SnapshotManifestError.integrityVerificationFailed(entry.relativePath)
            }
        }
    }

    private func directory(for manifest: ConfigurationSnapshotManifest) -> URL? {
        loadSnapshots().first { $0.manifest.id == manifest.id }?.directory
    }

    // MARK: - Restore

    /// Restores a snapshot into the live configuration. Must only run while no
    /// feature runtime is reading or writing configuration (startup finalizer
    /// or after the app has quit). Files are staged and verified first; only
    /// then are they moved into place, so a bad snapshot cannot half-destroy
    /// the current configuration.
    func restore(
        _ manifest: ConfigurationSnapshotManifest,
        applyPreferences: Bool,
        restoreKeychain: Bool
    ) throws {
        guard let directory = directory(for: manifest) else {
            throw SnapshotManifestError.missingManifest
        }
        try verify(manifest)

        let staging = rootDirectory.appendingPathComponent(
            "restore-staging-\(UUID().uuidString)", isDirectory: true
        )
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        for entry in manifest.files {
            let source = directory.appendingPathComponent(entry.relativePath)
            let staged = staging.appendingPathComponent(entry.relativePath)
            try fileManager.createDirectory(
                at: staged.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try fileManager.copyItem(at: source, to: staged)
        }

        // Commit only after the staging copies passed the same verification.
        for entry in manifest.files where entry.relativePath.hasPrefix("configuration/") {
            try commitStaged(
                staged: staging.appendingPathComponent(entry.relativePath),
                destination: configDirectory.appendingPathComponent(entry.dropConfigurationPrefix)
            )
        }
        for entry in manifest.files where entry.relativePath.hasPrefix("dock-groups/") {
            try commitStaged(
                staged: staging.appendingPathComponent(entry.relativePath),
                destination: configDirectory.appendingPathComponent(entry.relativePath)
            )
        }
        if manifest.includesRightClickDatabase {
            let staged = staging.appendingPathComponent(
                "right-click/\(Self.rightClickSnapshotFileName)"
            )
            try commitStaged(staged: staged, destination: rightClickDatabaseURL)
        }
        if applyPreferences, manifest.includesPreferences {
            try PreferenceSnapshotManager.restore(
                from: staging.appendingPathComponent(Self.preferencesFileName)
            )
        }
        if restoreKeychain, let info = manifest.keychain, info.keychainSnapshot {
            try keychainManager.restore(snapshotID: manifest.id, info: info)
        }

        if let record = loadSnapshots().first(where: { $0.manifest.id == manifest.id }) {
            updateStatus(of: record, to: .restored)
        }
    }

    private func commitStaged(staged: URL, destination: URL) throws {
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".restore-\(UUID().uuidString)")
        try fileManager.copyItem(at: staged, to: temporary)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
    }

    // MARK: - Copy helpers

    private func copyConfigurationFiles(into directory: URL) throws -> [SnapshotFile] {
        var files: [SnapshotFile] = []
        let configurationDirectory = directory.appendingPathComponent("configuration", isDirectory: true)
        try fileManager.createDirectory(at: configurationDirectory, withIntermediateDirectories: true)
        for name in Self.configurationFileNames {
            let source = configDirectory.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let destination = configurationDirectory.appendingPathComponent(name)
            try fileManager.copyItem(at: source, to: destination)
            files.append(try snapshotFile(for: destination, relativeTo: directory))
        }
        return files
    }

    private func copyDockGroups(into directory: URL) throws -> (files: [SnapshotFile], copied: Bool) {
        guard fileManager.fileExists(atPath: dockGroupsDirectory.path) else {
            return ([], false)
        }
        let destination = directory.appendingPathComponent("dock-groups", isDirectory: true)
        try fileManager.copyItem(at: dockGroupsDirectory, to: destination)
        let files = try recursiveSnapshotFiles(directory: destination, relativeTo: directory)
        return (files, !files.isEmpty)
    }

    private func copyRightClickDatabase(into directory: URL) throws -> (files: [SnapshotFile], copied: Bool) {
        guard fileManager.fileExists(atPath: rightClickDatabaseURL.path) else {
            return ([], false)
        }
        let rightClickDirectory = directory.appendingPathComponent("right-click", isDirectory: true)
        try fileManager.createDirectory(at: rightClickDirectory, withIntermediateDirectories: true)
        let destination = rightClickDirectory.appendingPathComponent(Self.rightClickSnapshotFileName)
        do {
            try SQLiteSnapshot.create(from: rightClickDatabaseURL, to: destination)
        } catch {
            throw SnapshotBackupError.sqliteSnapshotFailed(rightClickDatabaseURL.path)
        }
        return ([try snapshotFile(for: destination, relativeTo: directory)], true)
    }

    private func copyPreferences(into directory: URL) throws -> [SnapshotFile] {
        let url = directory.appendingPathComponent(Self.preferencesFileName)
        do {
            try PreferenceSnapshotManager.writeSnapshot(
                PreferenceSnapshotManager.snapshotDomain(), to: url
            )
        } catch {
            throw SnapshotBackupError.preferenceSnapshotFailed(url.path)
        }
        return [try snapshotFile(for: url, relativeTo: directory)]
    }

    private func snapshotFile(for url: URL, relativeTo directory: URL) throws -> SnapshotFile {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        // 标准化两侧路径（/tmp 的符号链接会让原始 path 出现 /private 前缀差异）。
        let basePath = directory.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        guard filePath.hasPrefix(basePath + "/") else {
            throw SnapshotBackupError.configurationFileMissing(url.path)
        }
        return SnapshotFile(
            relativePath: String(filePath.dropFirst(basePath.count + 1)),
            size: size,
            sha256: try UpdatePackageValidator.sha256(of: url)
        )
    }

    private func recursiveSnapshotFiles(directory: URL, relativeTo base: URL) throws -> [SnapshotFile] {
        let contents = try fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey]
        )
        var files: [SnapshotFile] = []
        for url in contents {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                files += try recursiveSnapshotFiles(directory: url, relativeTo: base)
            } else {
                files.append(try snapshotFile(for: url, relativeTo: base))
            }
        }
        return files
    }

    private func write(_ manifest: ConfigurationSnapshotManifest, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: url, options: .atomic)
    }

    // MARK: - Disk space

    private func estimateConfigurationBytes() -> UInt64 {
        var total: UInt64 = 0
        for name in Self.configurationFileNames {
            total += sizeIfPresent(at: configDirectory.appendingPathComponent(name))
        }
        total += sizeIfPresent(at: dockGroupsDirectory)
        total += sizeIfPresent(at: rightClickDatabaseURL)
        return total
    }

    private func sizeIfPresent(at url: URL) -> UInt64 {
        guard fileManager.fileExists(atPath: url.path) else { return 0 }
        var isDirectory: ObjCBool = false
        fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if isDirectory.boolValue {
            return (try? fileManagerDirectorySize(url)) ?? 0
        }
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    private func fileManagerDirectorySize(_ directory: URL) throws -> UInt64 {
        var total: UInt64 = 0
        let contents = try fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey]
        )
        for url in contents {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            if values.isDirectory == true {
                total += try fileManagerDirectorySize(url)
            } else {
                total += UInt64(values.fileSize ?? 0)
            }
        }
        return total
    }

    private func ensureDiskSpace(availableForImportantUsage required: UInt64) throws {
        let values = try configDirectory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        let available = UInt64(max(0, values.volumeAvailableCapacityForImportantUsage ?? 0))
        guard available >= required else {
            throw SnapshotBackupError.insufficientDiskSpace(required: required, available: available)
        }
    }
}

extension SnapshotFile {
    /// `configuration/config.json` → `config.json` (snapshot layout keeps the
    /// original file names so restores put them back verbatim).
    var dropConfigurationPrefix: String {
        String(relativePath.dropFirst("configuration/".count))
    }
}

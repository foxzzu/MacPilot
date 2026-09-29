import Foundation
import MacPilotUpdaterSupport

/// One version switch (upgrade, downgrade, channel move) tracked as a durable
/// transaction. The current record is written atomically to
/// `VersionManager/transactions/active.json` at every phase change, so a crash,
/// a `kill -9`, or an updater failure still leaves an accurate account of what
/// was in progress for the next launch to resolve.
struct VersionSwitchTransaction: Codable, Equatable {
    let id: UUID
    let sourceVersion: String
    let sourceChannel: AppChannel
    let targetVersion: String
    let targetChannel: AppChannel
    let intent: InstallationIntent
    let startedAt: Date
    /// Snapshot protecting the configuration of the version being left.
    var snapshotID: UUID?
    /// Snapshot to restore at target launch ("恢复降级前配置").
    var restoreSnapshotID: UUID?
    var phase: VersionSwitchPhase
    var updatedAt: Date
}

enum VersionSwitchPhase: String, Codable, Equatable {
    case downloading
    case verifyingPackage
    case preparingConfiguration
    case snapshotting
    case readyToInstall
    case replacingApplication
    case awaitingRelaunch
    case runningTarget
    case completed
    case failed
}

extension InstallationIntent {
    var allowsConfigurationRestore: Bool {
        switch self {
        case .automatic: false
        case .manualUpgrade, .manualDowngrade, .channelSwitch: true
        }
    }
}

/// Reads and writes the durable transaction record. Everything goes through
/// atomic writes so no phase change can tear the file.
struct VersionSwitchTransactionStore {
    let directory: URL

    init(rootDirectory: URL) {
        directory = rootDirectory.appendingPathComponent("transactions", isDirectory: true)
    }

    var activeURL: URL { directory.appendingPathComponent("active.json") }

    func loadActive() -> VersionSwitchTransaction? {
        guard let data = try? Data(contentsOf: activeURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(VersionSwitchTransaction.self, from: data)
    }

    func save(_ transaction: VersionSwitchTransaction) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(transaction).write(to: activeURL, options: .atomic)
    }

    /// Moves the active record into `transactions/<id>.json` so history stays
    /// auditable without keeping an "active" file that no longer is.
    func archive(_ transaction: VersionSwitchTransaction) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(transaction) {
            try? data.write(to: directory.appendingPathComponent("\(transaction.id.uuidString).json"), options: .atomic)
        }
        try? FileManager.default.removeItem(at: activeURL)
    }
}

/// Pending configuration restore requested by a version switch. Consumed once,
/// at the next launch, before the configuration store reads anything.
struct PendingConfigurationRestore: Codable, Equatable {
    let snapshotID: UUID
    let transactionID: UUID
    let requestedAt: Date
    let restoreKeychain: Bool
}

struct PendingConfigurationRestoreStore {
    static let fileName = "pending.json"
    let directory: URL

    init(rootDirectory: URL) {
        directory = rootDirectory.appendingPathComponent("restores", isDirectory: true)
    }

    var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    func load() -> PendingConfigurationRestore? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PendingConfigurationRestore.self, from: data)
    }

    func save(_ restore: PendingConfigurationRestore) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(restore).write(to: fileURL, options: .atomic)
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

/// Success tokens written by MacPilotUpdater when it deliberately kept the
/// previous app bundle as a rollback copy (the record type lives in
/// MacPilotUpdaterSupport so the updater and the app share one format). The
/// next successful launch deletes the backup and the token; a token that
/// survives means the new version never came up, and the backup is still there.
enum UpdateSuccessTokenStore {
    static func directory(rootDirectory: URL) -> URL {
        rootDirectory.appendingPathComponent("update-success", isDirectory: true)
    }

    static func write(
        rootDirectory: URL,
        id: UUID,
        backupPath: String,
        targetVersion: String
    ) {
        UpdateSuccessToken.write(
            to: directory(rootDirectory: rootDirectory).appendingPathComponent("\(id.uuidString).json"),
            backupPath: backupPath,
            targetVersion: targetVersion
        )
    }

    /// Deletes every recorded backup and its token. Called only after this
    /// process has loaded its configuration and initialized — "the new version
    /// runs" is what the token was waiting for.
    static func completeAll(rootDirectory: URL) {
        let directory = directory(rootDirectory: rootDirectory)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return }
        for file in files where file.pathExtension == "json" {
            if let token = UpdateSuccessToken.read(from: file), !token.backupPath.isEmpty {
                try? FileManager.default.removeItem(atPath: token.backupPath)
            }
            try? FileManager.default.removeItem(at: file)
        }
    }
}

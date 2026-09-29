import Foundation

/// Provenance and integrity record for one configuration protection snapshot.
/// Secrets never appear here (or anywhere in the snapshot directory): Keychain
/// material stays in the Keychain, and the manifest only records that a
/// Keychain backup exists and how many items it covers.
struct ConfigurationSnapshotManifest: Codable, Equatable, Identifiable {
    let schemaVersion: Int
    let id: UUID
    let createdAt: Date

    let sourceAppVersion: String
    let sourceChannel: AppChannel
    let sourceConfigurationVersion: Int

    let targetAppVersion: String
    let targetChannel: AppChannel

    let intent: InstallationIntent

    var files: [SnapshotFile]

    var includesRightClickDatabase: Bool
    var includesDockGroups: Bool
    var includesPreferences: Bool
    var includesKeychainBackup: Bool
    /// V1 never copies the large clipboard history files; the manifest states
    /// this explicitly instead of letting users assume a full content backup.
    var clipboardContentBackedUp: Bool
    var keychain: KeychainSnapshotInfo?
    var appRecovery: AppRecoveryInfo?

    var status: SnapshotStatus
}

struct SnapshotFile: Codable, Equatable {
    let relativePath: String
    let size: UInt64
    let sha256: String
}

struct KeychainSnapshotInfo: Codable, Equatable {
    var keychainSnapshot: Bool = true
    var remotePairingItemCount: Int
    var screenCredentialPresent: Bool
    /// Client IDs whose pairing keys were copied. These are metadata (the same
    /// IDs config.json already stores); the secrets themselves stay Keychain-only.
    var remotePairingAccounts: [String]
}

struct AppRecoveryInfo: Codable, Equatable {
    let fileName: String
    let size: UInt64
    let sha256: String
    let sourceAppVersion: String
}

enum SnapshotStatus: String, Codable {
    case preparing
    case ready
    case downgradeActive
    case restored
    case archived
    case corrupted
}

enum SnapshotManifestError: Error, Equatable {
    case integrityVerificationFailed(String)
    case missingManifest
    case snapshotInUse
    case cannotDeleteActiveSnapshot
}

enum ConfigurationSchemaSnapshot {
    /// Bump when the manifest layout itself changes. Restore code refuses
    /// manifests it does not understand instead of guessing.
    static let manifestSchemaVersion = 1
}

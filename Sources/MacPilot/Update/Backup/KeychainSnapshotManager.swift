import Foundation

/// Copies Keychain secrets into Keychain backup items before a downgrade.
///
/// The secrets (remote pairing keys, the Mac unlock password) must never be
/// written to a snapshot file, a plist, or Application Support — but they also
/// cannot be ignored: an old version will delete `pairing.<clientID>` the
/// moment the user removes that iPhone, and a later "restore pre-downgrade
/// configuration" would otherwise bring back device metadata pointing at a
/// Keychain key that no longer exists. So each secret is duplicated under a
/// backup service name derived from the snapshot ID, still inside the
/// Keychain, and restored from there. Disk only learns the item counts.
struct KeychainSnapshotManager {
    static let backupServicePrefix = "com.misswell.macpilot.version-backup."

    let secretStore: SecretStore
    let remoteService: String
    let screenService: String
    let screenAccount: String

    init(
        secretStore: SecretStore = KeychainSecretStore(),
        remoteService: String? = nil,
        screenService: String? = nil,
        screenAccount: String = NSUserName()
    ) {
        self.secretStore = secretStore
        self.remoteService = remoteService
            ?? "\((Bundle.main.bundleIdentifier ?? AppIdentity.bundleIdentifier)).remote"
        self.screenService = screenService ?? (Bundle.main.bundleIdentifier ?? AppIdentity.bundleIdentifier)
        self.screenAccount = screenAccount
    }

    static func backupService(for snapshotID: UUID) -> String {
        backupServicePrefix + snapshotID.uuidString
    }

    /// Copies every live secret into the backup service. Any copy failure
    /// aborts the snapshot: a partial Keychain backup must not look complete.
    func create(snapshotID: UUID, remoteClientIDs: [String]) throws -> KeychainSnapshotInfo {
        let backupService = Self.backupService(for: snapshotID)
        var accounts: [String] = []
        for clientID in remoteClientIDs {
            let account = "pairing.\(clientID)"
            guard let data = secretStore.read(service: remoteService, account: account) else {
                continue
            }
            guard secretStore.write(
                data,
                service: backupService,
                account: account,
                label: "MacPilot Version Backup (Remote Pairing)"
            ) else {
                throw SnapshotBackupError.keychainWriteFailed(account)
            }
            accounts.append(clientID)
        }

        var screenPresent = false
        if let password = secretStore.read(service: screenService, account: screenAccount) {
            guard secretStore.write(
                password,
                service: backupService,
                account: screenAccount,
                label: "MacPilot Version Backup (Unlock Password)"
            ) else {
                throw SnapshotBackupError.keychainWriteFailed("screen-unlock")
            }
            screenPresent = true
        }
        return KeychainSnapshotInfo(
            remotePairingItemCount: accounts.count,
            screenCredentialPresent: screenPresent,
            remotePairingAccounts: accounts
        )
    }

    /// Copies the backup items back to the canonical services. Backup items are
    /// intentionally kept afterwards; they age out together with the snapshot.
    func restore(snapshotID: UUID, info: KeychainSnapshotInfo) throws {
        let backupService = Self.backupService(for: snapshotID)
        for clientID in info.remotePairingAccounts {
            let account = "pairing.\(clientID)"
            guard let data = secretStore.read(service: backupService, account: account) else {
                throw SnapshotBackupError.keychainBackupMissing(account)
            }
            guard secretStore.write(
                data,
                service: remoteService,
                account: account,
                label: "MacPilot Remote Pairing"
            ) else {
                throw SnapshotBackupError.keychainWriteFailed(account)
            }
        }
        if info.screenCredentialPresent {
            guard let data = secretStore.read(service: backupService, account: screenAccount) else {
                throw SnapshotBackupError.keychainBackupMissing("screen-unlock")
            }
            guard secretStore.write(
                data,
                service: screenService,
                account: screenAccount,
                label: ScreenCredentialStore.itemLabel
            ) else {
                throw SnapshotBackupError.keychainWriteFailed("screen-unlock")
            }
        }
    }

    /// Removes the backup items for a deleted snapshot.
    func remove(snapshotID: UUID, info: KeychainSnapshotInfo?) {
        let backupService = Self.backupService(for: snapshotID)
        for clientID in info?.remotePairingAccounts ?? [] {
            secretStore.delete(service: backupService, account: "pairing.\(clientID)")
        }
        if info?.screenCredentialPresent == true {
            secretStore.delete(service: backupService, account: screenAccount)
        }
    }
}

enum SnapshotBackupError: Error, Equatable {
    case keychainWriteFailed(String)
    case keychainBackupMissing(String)
    case sqliteSnapshotFailed(String)
    case preferenceSnapshotFailed(String)
    case configurationFileMissing(String)
    case insufficientDiskSpace(required: UInt64, available: UInt64)
}

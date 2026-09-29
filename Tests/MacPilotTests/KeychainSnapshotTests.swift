import Foundation
import Testing
@testable import MacPilot

/// 方案第二十、二十一、五十节：Keychain Secret Snapshot 继续保存在
/// Keychain，磁盘 manifest 只记录数量；恢复必须同时还原配对密钥与解锁密码，
/// 且降级期间被删除/新增的项不影响原快照内容。
struct KeychainSnapshotTests {
    private let secrets = InMemorySecretStore()
    private let remoteService = "test.macpilot.remote"
    private let screenService = "test.macpilot.app"
    private let screenAccount = "tester"
    private var manager: KeychainSnapshotManager {
        KeychainSnapshotManager(
            secretStore: secrets,
            remoteService: remoteService,
            screenService: screenService,
            screenAccount: screenAccount
        )
    }

    private var snapshotID: UUID { UUID() }

    @Test func createCopiesSecretsIntoKeychainBackupItems() throws {
        let id = snapshotID
        secrets.write(Data("key-A".utf8), service: remoteService, account: "pairing.A", label: "pairing")
        secrets.write(Data("key-B".utf8), service: remoteService, account: "pairing.B", label: "pairing")
        secrets.write(Data("password".utf8), service: screenService, account: screenAccount, label: "unlock")

        let info = try manager.create(snapshotID: id, remoteClientIDs: ["A", "B"])
        #expect(info.keychainSnapshot)
        #expect(info.remotePairingItemCount == 2)
        #expect(info.screenCredentialPresent)
        #expect(info.remotePairingAccounts == ["A", "B"])

        // 备份项仍在 Keychain 内（InMemory 模拟同一存储），service 前缀正确。
        let backupService = KeychainSnapshotManager.backupService(for: id)
        #expect(secrets.read(service: backupService, account: "pairing.A") == Data("key-A".utf8))
        #expect(secrets.read(service: backupService, account: "pairing.B") == Data("key-B".utf8))
        #expect(secrets.read(service: backupService, account: screenAccount) == Data("password".utf8))
    }

    @Test func restoreBringsBackDeletedPairingKeys() throws {
        let id = snapshotID
        secrets.write(Data("key-A".utf8), service: remoteService, account: "pairing.A", label: "pairing")
        secrets.write(Data("key-B".utf8), service: remoteService, account: "pairing.B", label: "pairing")
        let info = try manager.create(snapshotID: id, remoteClientIDs: ["A", "B"])

        // 降级期间：删除一台 iPhone（旧版本会删掉它的 Keychain key）。
        secrets.delete(service: remoteService, account: "pairing.A")

        try manager.restore(snapshotID: id, info: info)
        #expect(secrets.read(service: remoteService, account: "pairing.A") == Data("key-A".utf8))
        #expect(secrets.read(service: remoteService, account: "pairing.B") == Data("key-B".utf8))
    }

    @Test func restoreReplaysOriginalDevicesAndNotOnesAddedDuringDowngrade() throws {
        let id = snapshotID
        secrets.write(Data("key-A".utf8), service: remoteService, account: "pairing.A", label: "pairing")
        let info = try manager.create(snapshotID: id, remoteClientIDs: ["A"])

        // 降级期间删除 A、新增 C。
        secrets.delete(service: remoteService, account: "pairing.A")
        secrets.write(Data("key-C".utf8), service: remoteService, account: "pairing.C", label: "pairing")

        try manager.restore(snapshotID: id, info: info)
        #expect(secrets.read(service: remoteService, account: "pairing.A") == Data("key-A".utf8))
        // C 是降级期间的新增项，不属于原快照；恢复不会把 C 抹掉（快照只
        // 负责还原自己的内容），但也不会把 C 当作原配置的一部分。
        #expect(!info.remotePairingAccounts.contains("C"))
    }

    @Test func unlockPasswordSurvivesADeleteDuringDowngrade() throws {
        let id = snapshotID
        secrets.write(Data("password".utf8), service: screenService, account: screenAccount, label: "unlock")
        let info = try manager.create(snapshotID: id, remoteClientIDs: [])

        secrets.delete(service: screenService, account: screenAccount)
        try manager.restore(snapshotID: id, info: info)
        #expect(secrets.read(service: screenService, account: screenAccount) == Data("password".utf8))
    }

    @Test func missingBackupItemFailsRestoreLoudly() throws {
        let id = snapshotID
        secrets.write(Data("key-A".utf8), service: remoteService, account: "pairing.A", label: "pairing")
        let info = try manager.create(snapshotID: id, remoteClientIDs: ["A"])
        // 备份项被清掉：恢复必须报错，而不是静默半还原。
        secrets.delete(service: KeychainSnapshotManager.backupService(for: id), account: "pairing.A")
        #expect(throws: SnapshotBackupError.keychainBackupMissing("pairing.A")) {
            try manager.restore(snapshotID: id, info: info)
        }
    }

    @Test func removeCleansBackupItemsOnly() throws {
        let id = snapshotID
        secrets.write(Data("key-A".utf8), service: remoteService, account: "pairing.A", label: "pairing")
        let info = try manager.create(snapshotID: id, remoteClientIDs: ["A"])
        manager.remove(snapshotID: id, info: info)
        #expect(secrets.read(service: KeychainSnapshotManager.backupService(for: id), account: "pairing.A") == nil)
        #expect(secrets.read(service: remoteService, account: "pairing.A") == Data("key-A".utf8))
    }
}

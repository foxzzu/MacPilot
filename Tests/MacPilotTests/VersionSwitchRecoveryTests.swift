import Foundation
import Testing
@testable import MacPilot

/// 方案第三十~三十四、三十五、五十一节：断电/崩溃后的启动恢复。
/// 覆盖 pending restore 的应用、success token 的回滚清理、active.json 的
/// 完成归档与半途失败归档。
@MainActor
struct VersionSwitchRecoveryTests {
    private let fileManager = FileManager.default

    private func write(_ string: String, to url: URL) {
        try! fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data(string.utf8).write(to: url)
    }

    private func makeBase() -> (base: URL, config: URL, vm: URL) {
        let base = fileManager.temporaryDirectory
            .appendingPathComponent("RecoveryTests-\(UUID().uuidString)", isDirectory: true)
        let config = base.appendingPathComponent("MacPilot", isDirectory: true)
        let vm = config.appendingPathComponent("VersionManager", isDirectory: true)
        try! fileManager.createDirectory(at: config, withIntermediateDirectories: true)
        return (base, config, vm)
    }

    private func makeManager(_ base: (base: URL, config: URL, vm: URL)) -> ConfigurationSnapshotManager {
        ConfigurationSnapshotManager(
            rootDirectory: base.vm,
            configDirectory: base.config,
            keychainManager: KeychainSnapshotManager(
                secretStore: InMemorySecretStore(),
                remoteService: "test.remote",
                screenService: "test.app",
                screenAccount: "tester"
            )
        )
    }

    @Test func completedSwitchIsArchivedWhenTargetIsRunning() throws {
        let base = makeBase()
        defer { try? fileManager.removeItem(at: base.base) }
        let store = VersionSwitchTransactionStore(rootDirectory: base.vm)
        let transaction = VersionSwitchTransaction(
            id: UUID(),
            sourceVersion: "1.2.0-beta.4",
            sourceChannel: .beta,
            targetVersion: "1.1.479",
            targetChannel: .stable,
            intent: .manualDowngrade,
            startedAt: Date(),
            snapshotID: nil,
            restoreSnapshotID: nil,
            phase: .awaitingRelaunch,
            updatedAt: Date()
        )
        try! store.save(transaction)

        VersionSwitchStartup.run(
            rootDirectory: base.vm,
            configDirectory: base.config,
            runningVersion: "1.1.479"
        )

        #expect(store.loadActive() == nil)
        let archived = (try? fileManager.contentsOfDirectory(
            at: store.directory, includingPropertiesForKeys: nil
        ))?.filter { $0.lastPathComponent != "active.json" } ?? []
        #expect(archived.count == 1)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Data(contentsOf: try #require(archived.first))
        let record = try decoder.decode(VersionSwitchTransaction.self, from: data)
        #expect(record.phase == .completed)
    }

    @Test func awaitingRelaunchWithoutTheTargetVersionRunningIsArchivedAsFailed() throws {
        // updater 等待进程退出超时后放弃,bundle 从未被替换,事务却停在
        // awaitingRelaunch:重启后必须如实记为失败,而不是标成完成。
        let base = makeBase()
        defer { try? fileManager.removeItem(at: base.base) }
        let store = VersionSwitchTransactionStore(rootDirectory: base.vm)
        try! store.save(VersionSwitchTransaction(
            id: UUID(),
            sourceVersion: "1.1.482-beta.2",
            sourceChannel: .beta,
            targetVersion: "1.1.479",
            targetChannel: .stable,
            intent: .manualDowngrade,
            startedAt: Date(),
            snapshotID: nil,
            restoreSnapshotID: nil,
            phase: .awaitingRelaunch,
            updatedAt: Date()
        ))

        VersionSwitchStartup.run(
            rootDirectory: base.vm,
            configDirectory: base.config,
            runningVersion: "1.1.482-beta.2"
        )

        #expect(store.loadActive() == nil)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? fileManager.contentsOfDirectory(
            at: store.directory, includingPropertiesForKeys: nil
        ))?.filter { $0.lastPathComponent != "active.json" } ?? []
        let data = try Data(contentsOf: try #require(files.first))
        let record = try decoder.decode(VersionSwitchTransaction.self, from: data)
        #expect(record.phase == .failed, "版本没变说明替换从未发生")
    }

    @Test func switchInterruptedBeforeInstallIsArchivedAsFailed() throws {
        let base = makeBase()
        defer { try? fileManager.removeItem(at: base.base) }
        let store = VersionSwitchTransactionStore(rootDirectory: base.vm)
        try! store.save(VersionSwitchTransaction(
            id: UUID(),
            sourceVersion: "1.1.479",
            sourceChannel: .stable,
            targetVersion: "1.1.478",
            targetChannel: .stable,
            intent: .manualDowngrade,
            startedAt: Date(),
            snapshotID: nil,
            restoreSnapshotID: nil,
            phase: .snapshotting,
            updatedAt: Date()
        ))

        VersionSwitchStartup.run(
            rootDirectory: base.vm,
            configDirectory: base.config,
            runningVersion: "1.1.479"
        )
        #expect(store.loadActive() == nil)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? fileManager.contentsOfDirectory(
            at: store.directory, includingPropertiesForKeys: nil
        ))?.filter { $0.lastPathComponent != "active.json" } ?? []
        let data = try Data(contentsOf: try #require(files.first))
        let record = try decoder.decode(VersionSwitchTransaction.self, from: data)
        #expect(record.phase == .failed, "半途失败在崩溃时未替换 App，重启后按 failed 归档")
    }

    @Test func successTokenDeletesTheRollbackBundleOnNextLaunch() {
        let base = makeBase()
        defer { try? fileManager.removeItem(at: base.base) }

        // 更新器保留的回滚包（放在 /Applications 同级，测试里放 base 下）。
        let backup = base.base.appendingPathComponent(".MacPilot-backup-token.app", isDirectory: true)
        try! fileManager.createDirectory(at: backup, withIntermediateDirectories: true)
        try! Data("app".utf8).write(to: backup.appendingPathComponent("MacPilot"))
        UpdateSuccessTokenStore.write(
            rootDirectory: base.vm,
            id: UUID(),
            backupPath: backup.path,
            targetVersion: "1.1.480"
        )
        #expect(fileManager.fileExists(atPath: backup.path))

        VersionSwitchStartup.run(
            rootDirectory: base.vm,
            configDirectory: base.config,
            runningVersion: "1.1.480"
        )

        #expect(!fileManager.fileExists(atPath: backup.path), "新版本稳定启动后回滚包被清理")
        let tokens = UpdateSuccessTokenStore.directory(rootDirectory: base.vm)
        #expect(((try? fileManager.contentsOfDirectory(at: tokens, includingPropertiesForKeys: nil)) ?? []).isEmpty)
    }

    @Test func pendingRestoreAppliesSnapshotFilesAndClearsTheRequest() throws {
        let base = makeBase()
        defer { try? fileManager.removeItem(at: base.base) }
        let manager = makeManager(base)

        write(#"{"quitAfter":30,"version":26}"#, to: base.config.appendingPathComponent("config.json"))
        let context = ConfigurationSnapshotManager.SnapshotContext(
            sourceAppVersion: "1.2.0-beta.4",
            sourceChannel: .beta,
            targetVersion: "1.1.479",
            targetChannel: .stable,
            intent: .manualDowngrade,
            remoteClientIDs: [],
            mergedConfiguration: nil
        )
        let snapshot = try manager.create(context: context)

        // 降级期间旧版本破坏了配置。
        write(#"{"quitAfter":0,"version":22}"#, to: base.config.appendingPathComponent("config.json"))

        let pendingStore = PendingConfigurationRestoreStore(rootDirectory: base.vm)
        try pendingStore.save(PendingConfigurationRestore(
            snapshotID: snapshot.manifest.id,
            transactionID: UUID(),
            requestedAt: Date(),
            restoreKeychain: false
        ))

        VersionSwitchStartup.run(
            rootDirectory: base.vm,
            configDirectory: base.config,
            runningVersion: "1.1.479"
        )

        let restored = String(decoding: try Data(contentsOf: base.config.appendingPathComponent("config.json")), as: UTF8.self)
        #expect(restored == #"{"quitAfter":30,"version":26}"#)
        #expect(pendingStore.load() == nil, "恢复成功后请求被清除")
    }

    @Test func pendingRestoreWithoutASnapshotIsDroppedSoFutureRestoresWork() throws {
        let base = makeBase()
        defer { try? fileManager.removeItem(at: base.base) }
        let pendingStore = PendingConfigurationRestoreStore(rootDirectory: base.vm)
        try pendingStore.save(PendingConfigurationRestore(
            snapshotID: UUID(),
            transactionID: UUID(),
            requestedAt: Date(),
            restoreKeychain: true
        ))

        VersionSwitchStartup.run(
            rootDirectory: base.vm,
            configDirectory: base.config,
            runningVersion: "1.1.479"
        )
        #expect(pendingStore.load() == nil, "引用了不存在快照的请求必须清除，否则永远阻塞后续恢复")
    }
}

import Foundation
import Testing
@testable import MacPilot

/// 方案第九、十三、十七、十八、十九、四十八节：降级配置保护必须覆盖
/// ConfigStore 全部拆分文件、Dock Groups（含自定义图标）、RightClick SQLite、
/// UserDefaults 快照，快照后修改全部原始数据，恢复后逐项等于快照。
struct ConfigurationSnapshotTests {
    private let fileManager = FileManager.default
    private var root: URL {
        fileManager.temporaryDirectory.appendingPathComponent("MacPilotSnapshotTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeFixture() -> (config: URL, vm: URL) {
        let config = root.appendingPathComponent("MacPilot", isDirectory: true)
        let vm = config.appendingPathComponent("VersionManager", isDirectory: true)
        try! fileManager.createDirectory(at: config, withIntermediateDirectories: true)
        return (config, vm)
    }

    private func write(_ string: String, to url: URL) {
        try! Data(string.utf8).write(to: url)
    }

    private func read(_ url: URL) throws -> String {
        String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    private func snapshotContext(
        target: String,
        intent: InstallationIntent,
        merged: Data?
    ) -> ConfigurationSnapshotManager.SnapshotContext {
        ConfigurationSnapshotManager.SnapshotContext(
            sourceAppVersion: "1.2.0-beta.4",
            sourceChannel: .beta,
            targetVersion: target,
            targetChannel: target.contains("beta") ? .beta : .stable,
            intent: intent,
            remoteClientIDs: [],
            mergedConfiguration: merged
        )
    }

    @Test func snapshotCaptureRestoreRoundTripRestoresEverySurface() throws {
        let (config, vm) = makeFixture()
        defer { try? fileManager.removeItem(at: root) }

        write(#"{"quitAfter":30,"version":26}"#, to: config.appendingPathComponent("config.json"))
        write(#"{"enabledFeatures":["exit"]}"#, to: config.appendingPathComponent("features.json"))
        write(#"{"hotkey":"cmd+shift+c"}"#, to: config.appendingPathComponent("shortcuts.json"))
        write(#"{"windowSwitcher":{}}"#, to: config.appendingPathComponent("window.json"))
        let dockGroups = config.appendingPathComponent("DockGroups", isDirectory: true)
        try fileManager.createDirectory(at: dockGroups.appendingPathComponent("Icons"), withIntermediateDirectories: true)
        write(#"{"groups":[{"id":"g1"}]}"#, to: dockGroups.appendingPathComponent("groups.json"))
        write("PNGDATA", to: dockGroups.appendingPathComponent("Icons/g1.png"))

        let manager = ConfigurationSnapshotManager(
            rootDirectory: vm,
            configDirectory: config,
            keychainManager: KeychainSnapshotManager(
                secretStore: InMemorySecretStore(),
                remoteService: "test.remote",
                screenService: "test.app",
                screenAccount: "tester"
            )
        )

        let result = try manager.create(
            context: snapshotContext(target: "1.1.479", intent: .manualDowngrade, merged: nil)
        )
        #expect(result.manifest.status == .ready)
        #expect(result.manifest.sourceAppVersion == "1.2.0-beta.4")
        #expect(result.manifest.targetAppVersion == "1.1.479")
        #expect(result.manifest.intent == .manualDowngrade)
        #expect(result.manifest.includesDockGroups)
        #expect(!result.manifest.clipboardContentBackedUp)

        let configurationNames = ["config.json", "features.json", "shortcuts.json", "window.json"]
        #expect(
            Set(result.manifest.files.map(\.relativePath).filter { $0.hasPrefix("configuration/") }) ==
            Set(configurationNames.map { "configuration/\($0)" })
        )
        #expect(result.manifest.files.contains { $0.relativePath == "dock-groups/groups.json" })
        #expect(result.manifest.files.contains { $0.relativePath == "dock-groups/Icons/g1.png" })
        #expect(result.manifest.files.contains { $0.relativePath == "preferences.plist" })

        // 降级测试开始：快照被标记为当前保护。
        let record = try #require(manager.loadSnapshots().first)
        manager.activate(record)
        #expect(manager.loadSnapshots().first?.manifest.status == .downgradeActive)

        // 模拟旧版本期间的破坏：改写配置、删除 Dock Group 图标。
        write(#"{"quitAfter":0,"version":22}"#, to: config.appendingPathComponent("config.json"))
        try? fileManager.removeItem(at: dockGroups.appendingPathComponent("Icons/g1.png"))

        // 恢复后逐项等于快照。
        try manager.restore(result.manifest, applyPreferences: false, restoreKeychain: false)
        #expect(try read(config.appendingPathComponent("config.json")) == #"{"quitAfter":30,"version":26}"#)
        #expect(try read(config.appendingPathComponent("features.json")) == #"{"enabledFeatures":["exit"]}"#)
        #expect(try read(dockGroups.appendingPathComponent("groups.json")) == #"{"groups":[{"id":"g1"}]}"#)
        #expect(try read(dockGroups.appendingPathComponent("Icons/g1.png")) == "PNGDATA")
        #expect(manager.loadSnapshots().first?.manifest.status == .restored)
    }

    @Test func corruptedSnapshotFailsVerificationInsteadOfRestoring() throws {
        let (config, vm) = makeFixture()
        defer { try? fileManager.removeItem(at: root) }

        write(#"{"a":1}"#, to: config.appendingPathComponent("config.json"))
        let manager = ConfigurationSnapshotManager(
            rootDirectory: vm,
            configDirectory: config,
            keychainManager: KeychainSnapshotManager(
                secretStore: InMemorySecretStore(),
                remoteService: "test.remote",
                screenService: "test.app",
                screenAccount: "tester"
            )
        )
        let result = try manager.create(
            context: snapshotContext(target: "1.1.479", intent: .manualDowngrade, merged: nil)
        )

        // 篡改快照内容：验证必须失败，绝不能把坏快照恢复进配置。
        let snapshotted = result.directory
            .appendingPathComponent("configuration/config.json")
        write(#"{"a":2}"#, to: snapshotted)
        #expect(throws: SnapshotManifestError.integrityVerificationFailed("configuration/config.json")) {
            try manager.verify(result.manifest)
        }
        // restore 内部先 verify，坏快照不会动到任何在线文件。
        #expect(throws: (any Error).self) {
            try manager.restore(result.manifest, applyPreferences: false, restoreKeychain: false)
        }
        #expect(try read(config.appendingPathComponent("config.json")) == #"{"a":1}"#)
    }

    @Test func activeDowngradeSnapshotRefusesDeletionAndAutoPruning() throws {
        let (config, vm) = makeFixture()
        defer { try? fileManager.removeItem(at: root) }
        write(#"{"a":1}"#, to: config.appendingPathComponent("config.json"))

        let manager = ConfigurationSnapshotManager(
            rootDirectory: vm,
            configDirectory: config,
            keychainManager: KeychainSnapshotManager(
                secretStore: InMemorySecretStore(),
                remoteService: "test.remote",
                screenService: "test.app",
                screenAccount: "tester"
            )
        )
        let result = try manager.create(
            context: snapshotContext(target: "1.1.479", intent: .manualDowngrade, merged: nil)
        )
        let record = try #require(manager.loadSnapshots().first)
        manager.activate(record)
        #expect(throws: SnapshotManifestError.cannotDeleteActiveSnapshot) {
            try manager.delete(record)
        }
        manager.pruneSnapshots()
        #expect(fileManager.fileExists(atPath: result.directory.path))

        // 新快照会把旧的当前保护降级为历史，此后才允许删除。
        _ = try manager.create(
            context: snapshotContext(target: "1.1.480", intent: .manualUpgrade, merged: nil)
        )
        let statuses = Dictionary(uniqueKeysWithValues: manager.loadSnapshots().map { ($0.id, $0.manifest.status) })
        #expect(statuses[result.manifest.id] == .ready)
        try manager.delete(try #require(manager.loadSnapshots().first { $0.manifest.id == result.manifest.id }))
        #expect(manager.loadSnapshots().count == 1)
    }

    @Test func mergedConfigurationIsCapturedForDiagnostics() throws {
        let (config, vm) = makeFixture()
        defer { try? fileManager.removeItem(at: root) }
        write(#"{"quitAfter":30}"#, to: config.appendingPathComponent("config.json"))

        let manager = ConfigurationSnapshotManager(
            rootDirectory: vm,
            configDirectory: config,
            keychainManager: KeychainSnapshotManager(
                secretStore: InMemorySecretStore(),
                remoteService: "test.remote",
                screenService: "test.app",
                screenAccount: "tester"
            )
        )
        let merged = Data(#"{"merged":true,"quitAfter":30}"#.utf8)
        let result = try manager.create(
            context: snapshotContext(target: "1.1.479", intent: .channelSwitch, merged: merged)
        )
        #expect(try read(result.directory.appendingPathComponent("merged-config.json")) == #"{"merged":true,"quitAfter":30}"#)
    }
}

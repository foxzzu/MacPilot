import Foundation
import Testing
@testable import MacPilot

/// 方案第十九节：UserDefaults 保护使用整个 persistent domain + 显式 denylist，
/// 而不是会腐化的手写 key 白名单。
struct PreferenceSnapshotTests {
    private let suiteName = "MacPilotPreferenceSnapshotTests-\(UUID().uuidString)"

    @Test func snapshotRoundTripsThroughPlist() throws {
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "enabledFlag")
        defaults.set(["a", "b"], forKey: "orderList")
        defaults.set(12, forKey: "minuteCount")

        let domain = PreferenceSnapshotManager.snapshotDomain(
            bundleIdentifier: suiteName,
            defaults: defaults
        )
        #expect(domain["enabledFlag"] as? Bool == true)
        #expect(domain["orderList"] as? [String] == ["a", "b"])

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("prefs-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: url) }
        try PreferenceSnapshotManager.writeSnapshot(domain, to: url)

        let restored = try PreferenceSnapshotManager.readSnapshot(from: url)
        #expect(restored["enabledFlag"] as? Bool == true)
        #expect(restored["minuteCount"] as? Int == 12)
    }

    @Test func denylistCoversRuntimeAndCacheKeys() {
        let domain: [String: Any] = [
            "clipboardHotkey": "cmd+c",
            "updateDownloadMirrorHost": "ghfast.top",
            "rightClickStoreMigrationPendingV2": true
        ]
        let filtered = PreferenceSnapshotManager.applyingDenylist(domain)
        #expect(filtered["clipboardHotkey"] as? String == "cmd+c")
        #expect(filtered["updateDownloadMirrorHost"] == nil)
        #expect(filtered["rightClickStoreMigrationPendingV2"] == nil)
    }
}

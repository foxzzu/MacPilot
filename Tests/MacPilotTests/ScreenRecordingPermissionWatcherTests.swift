import AppKit
import Testing
@testable import MacPilot

/// 屏幕录制授权守望器：授权缺失时轮询、回到前台复检，授权恢复时恰好
/// 广播一次 `.screenRecordingPermissionGranted` 并停止监视——这是「更新后
/// 重新确认授权，功能自动恢复，无需重启」闭环的核心契约。
@MainActor
struct ScreenRecordingPermissionWatcherTests {
    private final class PermissionProbe: @unchecked Sendable {
        var granted: Bool
        init(granted: Bool) { self.granted = granted }
    }

    private final class GrantedRecorder: @unchecked Sendable {
        private(set) var count = 0
        func record() { count += 1 }
    }

    @Test func grantedPermissionStartsNoWatcherAndFiresNoEvent() {
        let center = NotificationCenter()
        let watcher = ScreenRecordingPermissionWatcher(
            preflight: { true },
            pollInterval: .milliseconds(10),
            notificationCenter: center
        )
        #expect(watcher.isGranted)
        watcher.beginWatchingIfDenied()
        #expect(!watcher.isWatching)
        let recorder = GrantedRecorder()
        center.addObserver(
            forName: .screenRecordingPermissionGranted,
            object: nil,
            queue: nil
        ) { _ in recorder.record() }
        watcher.recheckNow()
        #expect(recorder.count == 0)
    }

    @Test func deniedPermissionWatchesAndFiresGrantedExactlyOnce() async {
        let center = NotificationCenter()
        let probe = PermissionProbe(granted: false)
        let watcher = ScreenRecordingPermissionWatcher(
            preflight: { probe.granted },
            pollInterval: .milliseconds(10),
            notificationCenter: center
        )
        let recorder = GrantedRecorder()
        center.addObserver(
            forName: .screenRecordingPermissionGranted,
            object: nil,
            queue: nil
        ) { _ in recorder.record() }

        watcher.beginWatchingIfDenied()
        #expect(watcher.isWatching)
        #expect(!watcher.isGranted)

        probe.granted = true
        await awaitCountOrTimeout(recorder, expected: 1)
        #expect(watcher.isGranted)
        #expect(!watcher.isWatching)

        // 再跑一轮预检也不得重复广播。
        watcher.recheckNow()
        #expect(recorder.count == 1)
        watcher.stopWatching()
    }

    @Test func appActivationRecheckPicksUpAnAlreadyGrantedPermission() async {
        let center = NotificationCenter()
        let probe = PermissionProbe(granted: false)
        let watcher = ScreenRecordingPermissionWatcher(
            preflight: { probe.granted },
            pollInterval: .seconds(60),
            notificationCenter: center
        )
        let recorder = GrantedRecorder()
        center.addObserver(
            forName: .screenRecordingPermissionGranted,
            object: nil,
            queue: nil
        ) { _ in recorder.record() }

        watcher.beginWatchingIfDenied()
        // 用户在系统设置里打开授权后回到应用：didBecomeActive 触发复检。
        probe.granted = true
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await awaitCountOrTimeout(recorder, expected: 1)
        #expect(watcher.isGranted)
        #expect(!watcher.isWatching)
    }

    @Test func recheckWhileStillDeniedKeepsWatching() {
        let center = NotificationCenter()
        let probe = PermissionProbe(granted: false)
        let watcher = ScreenRecordingPermissionWatcher(
            preflight: { probe.granted },
            pollInterval: .seconds(60),
            notificationCenter: center
        )
        watcher.beginWatchingIfDenied()
        watcher.recheckNow()
        #expect(watcher.isWatching)
        #expect(!watcher.isGranted)
        watcher.stopWatching()
    }

    /// 广播经队列异步派发；轮询等待到目标次数或超时。
    private func awaitCountOrTimeout(_ recorder: GrantedRecorder, expected: Int) async {
        for _ in 0..<200 {
            if recorder.count >= expected { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("expected \(expected) granted event(s), saw \(recorder.count)")
    }
}

/// 消费方自愈契约：授权恢复事件到达后，截图模型清掉固化的拒绝状态，
/// 并且在自动截图配置开着的情况下把循环重新拉起来——无需重启应用。
@MainActor
struct ScreenCapturePermissionRecoveryTests {
    @Test func permissionGrantedRecoveryClearsDeniedStateAndRestartsLoop() async {
        let model = ScreenCaptureModel()
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MacPilotRecoveryTest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        model.setEnabled(true)
        model.setScreenshotEnabled(true)
        model.setOutputFolder(folder)
        model.activateFromConfiguration()

        NotificationCenter.default.post(name: .screenRecordingPermissionGranted, object: nil)
        await awaitCondition { model.hasScreenPermission && !model.isPermissionError && model.isLoopRunning }

        #expect(model.hasScreenPermission)
        #expect(!model.isPermissionError)
        #expect(model.isLoopRunning)
        model.shutdown()
    }

    private func awaitCondition(_ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("permission recovery state was not reached")
    }
}

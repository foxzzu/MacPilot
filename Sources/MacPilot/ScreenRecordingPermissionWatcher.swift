import AppKit
import Foundation

extension Notification.Name {
    /// macOS 屏幕录制授权在运行期间从「未授权」变为「已授权」时发出。
    /// 捕获类功能监听它来自愈（清掉固化的失败状态、重建会话），无需重启。
    static let screenRecordingPermissionGranted =
        Notification.Name("com.misswell.macpilot.screenRecordingPermissionGranted")
}

/// Watches macOS screen-recording consent and broadcasts its recovery.
///
/// macOS re-flags the screen-recording consent whenever the app bundle is
/// replaced (every update) and periodically on recent systems; capture then
/// fails until the user re-confirms in System Settings. Every consumer used to
/// latch the denied state at launch or first failure, so a restart was also
/// required. The watcher closes that loop: while permission is missing it
/// polls cheaply and re-checks whenever the user returns from System Settings
/// (app activation), and on the denied → granted transition it posts
/// `.screenRecordingPermissionGranted` exactly once so features recover
/// themselves.
@MainActor
final class ScreenRecordingPermissionWatcher: ObservableObject {
    @Published private(set) var isGranted: Bool
    @Published private(set) var isWatching = false

    private let preflight: () -> Bool
    private let pollInterval: Duration
    private let notificationCenter: NotificationCenter
    private var pollTask: Task<Void, Never>?
    /// Only touched from this actor and from deinit, which runs after the last
    /// strong reference is gone — no concurrent access is possible.
    nonisolated(unsafe) private var activationObserver: NSObjectProtocol?

    init(
        preflight: @escaping () -> Bool = CGPreflightScreenCaptureAccess,
        pollInterval: Duration = .seconds(2),
        notificationCenter: NotificationCenter = .default
    ) {
        self.preflight = preflight
        self.pollInterval = pollInterval
        self.notificationCenter = notificationCenter
        isGranted = preflight()
    }

    deinit {
        pollTask?.cancel()
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
    }

    /// Starts watching while permission is missing; a no-op when granted.
    func beginWatchingIfDenied() {
        guard !isGranted else { return }
        installActivationObserverIfNeeded()
        guard pollTask == nil else { return }
        isWatching = true
        let interval = pollInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.preflight() {
                    self.markGranted()
                    return
                }
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Immediate re-check for moments that imply the user just acted, such as
    /// returning to the app from System Settings.
    func recheckNow() {
        guard preflight() else {
            beginWatchingIfDenied()
            return
        }
        markGranted()
    }

    func stopWatching() {
        pollTask?.cancel()
        pollTask = nil
        isWatching = false
    }

    private func markGranted() {
        stopWatching()
        guard !isGranted else { return }
        isGranted = true
        notificationCenter.post(name: .screenRecordingPermissionGranted, object: nil)
    }

    private func installActivationObserverIfNeeded() {
        guard activationObserver == nil else { return }
        activationObserver = notificationCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.recheckNow()
            }
        }
    }
}

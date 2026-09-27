import OSLog
import UIKit

/// Bridges the SwiftUI app to the window scene's interface orientation.
///
/// The trackpad page refuses system rotation on principle, with one exception:
/// when the remote keyboard opens while the user holds the phone in a
/// landscape orientation, the scene rotates to that hold so the keyboard
/// rises from the long edge. The supported mask lives in one place so the
/// app delegate and the geometry requests cannot drift apart.
@MainActor
final class InterfaceOrientationController {
    static let shared = InterfaceOrientationController()

    private static let logger = Logger(subsystem: "com.misswell.macpilot.remote", category: "Trackpad")

    /// The interface orientations the app currently admits. Portrait except
    /// while the keyboard is up in a landscape hold.
    private(set) var supportedMask: UIInterfaceOrientationMask = .portrait

    func setSupported(_ mask: UIInterfaceOrientationMask) {
        guard mask != supportedMask else { return }
        supportedMask = mask
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else {
            return
        }
        // SwiftUI's root hosting controller caches its answer; without this
        // invalidation the geometry request below is denied and the scene
        // silently stays portrait.
        for window in scene.windows where window.isKeyWindow {
            window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
            Self.logger.error("interface rotation denied: \(String(describing: error), privacy: .public)")
        }
    }

    /// The hold's matching interface orientation: the right-edge-up hold
    /// (`.right`) reads upright as `landscapeRight`, and the left-edge-up
    /// hold as `landscapeLeft`.
    static func mask(for hold: TrackpadOrientation) -> UIInterfaceOrientationMask {
        switch hold {
        case .left: return .landscapeLeft
        case .right: return .landscapeRight
        case .top, .bottom: return .portrait
        }
    }
}

/// Reports the controller's mask so the geometry request is actually honored.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        MainActor.assumeIsolated {
            InterfaceOrientationController.shared.supportedMask
        }
    }
}

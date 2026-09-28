import ApplicationServices
import Foundation
import MacPilotRemoteProtocol
import MacPilotRemoteTransport

/// AX queries can stall in another process, so polling never runs on the
/// input actor. Only focus transitions are sent, retried if the video is busy.
final class RemoteKeyboardFocusMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.misswell.macpilot.video.focus", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var lastTarget: AXUIElement?
    private var lastEditable: Bool?
    private let transport: RemoteVideoTransport

    init(transport: RemoteVideoTransport) { self.transport = transport }

    func start() {
        queue.async {
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(500))
            timer.setEventHandler { [weak self] in self?.poll() }
            self.timer = timer; timer.resume()
        }
    }

    private func poll() {
        guard AXIsProcessTrusted() else { return }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.1)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &raw) == .success else { return }
        let target: AXUIElement?
        if let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() { target = unsafeDowncast(raw, to: AXUIElement.self) }
        else { target = nil }
        var editable = false
        if let target {
            AXUIElementSetMessagingTimeout(target, 0.1)
            var role: CFTypeRef?
            var writable: CFTypeRef?
            var enabled: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(target, kAXRoleAttribute as CFString, &role)
            _ = AXUIElementCopyAttributeValue(target, kAXIsEditableAttribute as CFString, &writable)
            _ = AXUIElementCopyAttributeValue(target, kAXEnabledAttribute as CFString, &enabled)
            let roleName = role as? String
            editable = enabled as? Bool != false && writable as? Bool != false
                && (roleName == kAXTextFieldRole as String || roleName == kAXTextAreaRole as String
                    || (roleName == kAXComboBoxRole as String && writable as? Bool == true))
        }
        let sameTarget: Bool
        if let target, let lastTarget { sameTarget = CFEqual(target, lastTarget) }
        else { sameTarget = target == nil && lastTarget == nil }
        guard lastEditable != editable || (editable && !sameTarget),
              let data = try? JSONEncoder().encode(editable) else { return }
        if transport.send(RemoteVideoPacket(frameType: .focus, payload: data)) {
            lastTarget = target; lastEditable = editable
        }
    }

    func stop() { queue.async { self.timer?.cancel(); self.timer = nil; self.lastTarget = nil } }
}

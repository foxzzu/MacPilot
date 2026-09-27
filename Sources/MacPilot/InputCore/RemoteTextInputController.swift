import ApplicationServices
import CoreGraphics
import Foundation
import MacPilotRemoteProtocol

/// Binds remote typing to the editable element beneath the pointer. Each
/// command rechecks focus so a delayed phone edit cannot reach another app.
@MainActor
final class RemoteTextInputController {
    private var targets: [UUID: AXUIElement] = [:]
    private let source = CGEventSource(stateID: .hidSystemState)

    func begin(connectionID: UUID) -> Bool {
        targets.removeValue(forKey: connectionID)
        guard AXIsProcessTrusted(), let point = CGEvent(source: source)?.location else { return false }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        var raw: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &raw) == .success,
              let raw, let target = editableAncestor(of: raw) else { return false }
        if !isFocused(target, system: system) {
            _ = AXUIElementSetAttributeValue(target, kAXFocusedAttribute as CFString, kCFBooleanTrue!)
        }
        guard isFocused(target, system: system) else { return false }
        targets[connectionID] = target
        return true
    }

    func end(connectionID: UUID) {
        targets.removeValue(forKey: connectionID)
    }

    func handle(_ operation: RemoteTextInputOperation, connectionID: UUID) -> Bool {
        guard let target = targets[connectionID], AXIsProcessTrusted() else { return false }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        guard isFocused(target, system: system) else {
            end(connectionID: connectionID)
            return false
        }
        switch operation {
        case let .insert(text):
            return postText(text)
        case .deleteBackward:
            return postKey(51)
        case .returnKey:
            return postKey(36)
        }
    }

    private func editableAncestor(of element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element
        for _ in 0..<8 {
            guard let candidate = current else { break }
            var roleValue: CFTypeRef?
            var editableValue: CFTypeRef?
            var enabledValue: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(candidate, kAXRoleAttribute as CFString, &roleValue)
            _ = AXUIElementCopyAttributeValue(candidate, kAXIsEditableAttribute as CFString, &editableValue)
            _ = AXUIElementCopyAttributeValue(candidate, kAXEnabledAttribute as CFString, &enabledValue)
            if let role = roleValue as? String,
               Self.isEditableRole(role, editable: editableValue as? Bool, enabled: enabledValue as? Bool) {
                return candidate
            }
            var parentValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(candidate, kAXParentAttribute as CFString, &parentValue) == .success,
                  let parentValue, CFGetTypeID(parentValue) == AXUIElementGetTypeID() else { break }
            current = unsafeDowncast(parentValue, to: AXUIElement.self)
        }
        return nil
    }

    static func isEditableRole(_ role: String, editable: Bool?, enabled: Bool?) -> Bool {
        guard enabled != false, editable != false else { return false }
        return role == kAXTextFieldRole as String
            || role == kAXTextAreaRole as String
            || (role == kAXComboBoxRole as String && editable == true)
    }

    private func isFocused(_ target: AXUIElement, system: AXUIElement) -> Bool {
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        return CFEqual(focused, target)
    }

    private func postText(_ text: String) -> Bool {
        guard let source else { return false }
        var chunk = ""
        var count = 0
        for character in text {
            let length = String(character).utf16.count
            if count + length > 20 {
                guard postUnicode(chunk, source: source) else { return false }
                chunk = ""
                count = 0
            }
            chunk.append(character)
            count += length
        }
        return chunk.isEmpty || postUnicode(chunk, source: source)
    }

    private func postUnicode(_ text: String, source: CGEventSource) -> Bool {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return false }
        let units = Array(text.utf16)
        units.withUnsafeBufferPointer { buffer in
            down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: buffer.baseAddress)
            up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: buffer.baseAddress)
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    private func postKey(_ keyCode: UInt16) -> Bool {
        guard let source,
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { return false }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}

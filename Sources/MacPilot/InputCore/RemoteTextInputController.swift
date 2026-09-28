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
    private let targetResolver = RemoteTextInputTargetResolver(accessibility: SystemRemoteTextInputAccessibility())

    func begin(connectionID: UUID, focused: Bool = false) -> Bool {
        targets.removeValue(forKey: connectionID)
        guard AXIsProcessTrusted(), let point = CGEvent(source: source)?.location else { return false }
        guard let target = targetResolver.begin(at: point, focused: focused) else { return false }
        targets[connectionID] = target
        return true
    }

    func end(connectionID: UUID) {
        targets.removeValue(forKey: connectionID)
    }

    func handle(_ operation: RemoteTextInputOperation, connectionID: UUID) -> Bool {
        guard let target = targets[connectionID], AXIsProcessTrusted() else { return false }
        guard targetResolver.isFocused(target) else {
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

    static func isEditableRole(_ role: String, editable: Bool?, enabled: Bool?) -> Bool {
        guard enabled != false, editable != false else { return false }
        return role == kAXTextFieldRole as String
            || role == kAXTextAreaRole as String
            || (role == kAXComboBoxRole as String && editable == true)
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

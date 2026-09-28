import AppKit
import ApplicationServices

@MainActor
struct SystemRemoteTextInputAccessibility: RemoteTextInputAccessibility {
    func element(at point: CGPoint) -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &element) == .success else { return nil }
        return element
    }

    func focusedElement() -> AXUIElement? {
        // System-wide AXFocusedUIElement can fail for Electron even when the
        // foreground application's own focus query succeeds.
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.25)
        guard let focused = elementAttribute(kAXFocusedUIElementAttribute, of: application),
              processID(of: focused) == app.processIdentifier else { return nil }
        return focused
    }

    func editableAncestor(of element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element
        for _ in 0..<8 {
            guard let candidate = current else { break }
            AXUIElementSetMessagingTimeout(candidate, 0.25)
            if let role = attribute(kAXRoleAttribute, of: candidate) as? String,
               RemoteTextInputController.isEditableRole(
                   role,
                   editable: attribute(kAXIsEditableAttribute, of: candidate) as? Bool,
                   enabled: attribute(kAXEnabledAttribute, of: candidate) as? Bool
               ) {
                return candidate
            }
            current = elementAttribute(kAXParentAttribute, of: candidate)
        }
        return nil
    }

    func frame(of element: AXUIElement) -> CGRect? {
        guard let position = attribute(kAXPositionAttribute, of: element),
              let size = attribute(kAXSizeAttribute, of: element),
              CFGetTypeID(position) == AXValueGetTypeID(),
              CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(position, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeDowncast(size, to: AXValue.self), .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    func processID(of element: AXUIElement) -> Int32? {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : nil
    }

    func sameElement(_ lhs: AXUIElement, _ rhs: AXUIElement) -> Bool { CFEqual(lhs, rhs) }

    func focus(_ element: AXUIElement) {
        _ = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue!)
    }

    private func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private func elementAttribute(_ name: String, of element: AXUIElement) -> AXUIElement? {
        guard let value = attribute(name, of: element), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }
}

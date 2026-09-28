import CoreGraphics

/// The AX boundary is injectable so container hit tests and focus changes can
/// be replayed without sending keyboard events to the user's foreground app.
@MainActor
protocol RemoteTextInputAccessibility {
    associatedtype Element
    func element(at point: CGPoint) -> Element?
    func focusedElement() -> Element?
    func editableAncestor(of element: Element) -> Element?
    func frame(of element: Element) -> CGRect?
    func processID(of element: Element) -> Int32?
    func sameElement(_ lhs: Element, _ rhs: Element) -> Bool
    func focus(_ element: Element)
}

@MainActor
struct RemoteTextInputTargetResolver<Accessibility: RemoteTextInputAccessibility> {
    let accessibility: Accessibility

    func begin(at point: CGPoint, focused: Bool) -> Accessibility.Element? {
        let target: Accessibility.Element
        if focused {
            guard let current = accessibility.focusedElement() else { return nil }
            // An explicit keyboard request is the user's typing intent. A
            // custom editor need not advertise a standard editable AX role,
            // but its focus must still remain pinned before each operation.
            target = accessibility.editableAncestor(of: current) ?? current
        } else {
            guard let hit = accessibility.element(at: point) else { return nil }
            if let editable = accessibility.editableAncestor(of: hit) {
                target = editable
            } else {
                // Electron webviews can hit-test to a surrounding container
                // even inside the focused textarea. Accept the focused field
                // only in the same process and inside its actual bounds.
                guard let current = accessibility.focusedElement(),
                      let editable = accessibility.editableAncestor(of: current),
                      let hitPID = accessibility.processID(of: hit),
                      hitPID == accessibility.processID(of: editable),
                      let frame = accessibility.frame(of: editable),
                      !frame.isEmpty, frame.contains(point) else { return nil }
                target = editable
            }
        }
        if !isFocused(target) { accessibility.focus(target) }
        return isFocused(target) ? target : nil
    }

    func isFocused(_ target: Accessibility.Element) -> Bool {
        guard let current = accessibility.focusedElement() else { return false }
        return accessibility.sameElement(accessibility.editableAncestor(of: current) ?? current, target)
    }
}

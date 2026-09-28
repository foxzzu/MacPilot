import ApplicationServices
import Testing
@testable import MacPilot

@Suite("Remote text target selection")
@MainActor
struct RemoteTextInputTests {
    @Test func standardEditableRolesAreAccepted() {
        #expect(RemoteTextInputController.isEditableRole(kAXTextFieldRole as String, editable: nil, enabled: true))
        #expect(RemoteTextInputController.isEditableRole(kAXTextAreaRole as String, editable: true, enabled: nil))
        #expect(RemoteTextInputController.isEditableRole(kAXComboBoxRole as String, editable: true, enabled: true))
    }

    @Test func disabledOrReadOnlyControlsAreRejected() {
        #expect(!RemoteTextInputController.isEditableRole(kAXTextFieldRole as String, editable: false, enabled: true))
        #expect(!RemoteTextInputController.isEditableRole(kAXTextAreaRole as String, editable: true, enabled: false))
        #expect(!RemoteTextInputController.isEditableRole(kAXComboBoxRole as String, editable: nil, enabled: true))
        #expect(!RemoteTextInputController.isEditableRole(kAXButtonRole as String, editable: true, enabled: true))
    }

    @Test func webviewContainerHitInsideFocusedTextAreaStartsTyping() {
        let accessibility = TextInputAccessibilityFixture()
        let resolver = RemoteTextInputTargetResolver(accessibility: accessibility)
        #expect(resolver.begin(at: CGPoint(x: 150, y: 120), focused: false) == "field")
        #expect(accessibility.focusRequests.isEmpty)
    }

    @Test func containerHitOutsideFocusedFieldDoesNotOpenKeyboard() {
        let accessibility = TextInputAccessibilityFixture()
        let resolver = RemoteTextInputTargetResolver(accessibility: accessibility)
        #expect(resolver.begin(at: CGPoint(x: 150, y: 200), focused: false) == nil)
        #expect(accessibility.focusRequests.isEmpty)
    }

    @Test func anotherApplicationsContainerCannotReuseFocusedField() {
        let accessibility = TextInputAccessibilityFixture()
        accessibility.processIDs["container"] = 2
        let resolver = RemoteTextInputTargetResolver(accessibility: accessibility)
        #expect(resolver.begin(at: CGPoint(x: 150, y: 120), focused: false) == nil)
    }

    @Test func missingOrEmptyBoundsCannotActivateContainerFallback() {
        let accessibility = TextInputAccessibilityFixture()
        let resolver = RemoteTextInputTargetResolver(accessibility: accessibility)
        accessibility.fieldFrame = nil
        #expect(resolver.begin(at: CGPoint(x: 150, y: 120), focused: false) == nil)
        accessibility.fieldFrame = .zero
        #expect(resolver.begin(at: .zero, focused: false) == nil)
    }

    @Test func readOnlyFocusAndFailedHitTestsDoNotOpenKeyboard() {
        let accessibility = TextInputAccessibilityFixture()
        let resolver = RemoteTextInputTargetResolver(accessibility: accessibility)
        accessibility.editableElements.remove("field")
        #expect(resolver.begin(at: CGPoint(x: 150, y: 120), focused: false) == nil)
        accessibility.editableElements.insert("field")
        accessibility.hit = nil
        #expect(resolver.begin(at: CGPoint(x: 150, y: 120), focused: false) == nil)
    }

    @Test func directTextFieldHitStillFocusesTheClickedField() {
        let accessibility = TextInputAccessibilityFixture()
        accessibility.hit = "otherField"
        let resolver = RemoteTextInputTargetResolver(accessibility: accessibility)
        #expect(resolver.begin(at: CGPoint(x: 150, y: 120), focused: false) == "otherField")
        #expect(accessibility.focusRequests == ["otherField"])
    }

    @Test func failedFocusTransferDoesNotStartTyping() {
        let accessibility = TextInputAccessibilityFixture()
        accessibility.hit = "otherField"
        accessibility.acceptsFocus = false
        let resolver = RemoteTextInputTargetResolver(accessibility: accessibility)
        #expect(resolver.begin(at: CGPoint(x: 150, y: 120), focused: false) == nil)
    }

    @Test func textChildFocusMatchesItsEditorButSwitchingEditorsStopsTyping() {
        let accessibility = TextInputAccessibilityFixture()
        accessibility.currentFocus = "textChild"
        let resolver = RemoteTextInputTargetResolver(accessibility: accessibility)
        #expect(resolver.begin(at: CGPoint(x: 150, y: 120), focused: false) == "field")
        #expect(resolver.isFocused("field"))
        accessibility.currentFocus = "otherField"
        #expect(!resolver.isFocused("field"))
    }

    @Test func explicitFocusedModeDoesNotRequirePointerOverField() {
        let resolver = RemoteTextInputTargetResolver(accessibility: TextInputAccessibilityFixture())
        #expect(resolver.begin(at: .zero, focused: true) == "field")
    }

    @Test func explicitKeyboardRequestCanBindACustomEditorButAutomaticProbeCannot() {
        let accessibility = TextInputAccessibilityFixture()
        accessibility.currentFocus = "customEditor"
        let resolver = RemoteTextInputTargetResolver(accessibility: accessibility)
        #expect(resolver.begin(at: .zero, focused: false) == nil)
        #expect(resolver.begin(at: .zero, focused: true) == "customEditor")
        #expect(resolver.isFocused("customEditor"))
        accessibility.currentFocus = "otherField"
        #expect(!resolver.isFocused("customEditor"))
    }

    @Test func explicitKeyboardRequestStillRequiresAFocusedElement() {
        let accessibility = TextInputAccessibilityFixture()
        accessibility.currentFocus = nil
        let resolver = RemoteTextInputTargetResolver(accessibility: accessibility)
        #expect(resolver.begin(at: .zero, focused: true) == nil)
    }
}

@MainActor
private final class TextInputAccessibilityFixture: RemoteTextInputAccessibility {
    var hit: String? = "container"
    var currentFocus: String? = "field"
    var fieldFrame: CGRect? = CGRect(x: 100, y: 100, width: 300, height: 50)
    var processIDs: [String: Int32] = ["container": 1, "field": 1, "otherField": 1]
    var editableElements: Set<String> = ["field", "otherField"]
    var acceptsFocus = true
    var focusRequests: [String] = []

    func element(at point: CGPoint) -> String? { hit }
    func focusedElement() -> String? { currentFocus }
    func editableAncestor(of element: String) -> String? {
        let candidate = element == "textChild" ? "field" : element
        return editableElements.contains(candidate) ? candidate : nil
    }
    func frame(of element: String) -> CGRect? { element == "field" ? fieldFrame : nil }
    func processID(of element: String) -> Int32? { processIDs[element] }
    func sameElement(_ lhs: String, _ rhs: String) -> Bool { lhs == rhs }
    func focus(_ element: String) {
        focusRequests.append(element)
        if acceptsFocus { currentFocus = element }
    }
}

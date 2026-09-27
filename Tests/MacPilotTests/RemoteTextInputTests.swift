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
}

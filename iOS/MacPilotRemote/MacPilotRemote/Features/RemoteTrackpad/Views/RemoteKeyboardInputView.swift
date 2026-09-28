import MacPilotRemoteProtocol
import SwiftUI
import UIKit

/// A one-point text responder that presents the native iPhone keyboard while
/// the trackpad remains visible. Marked IME text stays local until committed.
struct RemoteKeyboardInputView: UIViewRepresentable {
    @ObservedObject var model: RemoteTrackpadModel
    var usesSceneOrientation = false

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> KeyboardTextView {
        let view = KeyboardTextView()
        view.delegate = context.coordinator
        view.onEmptyDelete = { [weak model] in model?.sendTextInput(.deleteBackward) }
        view.backgroundColor = .clear
        view.textColor = .clear
        view.tintColor = .clear
        view.isScrollEnabled = false
        view.autocorrectionType = .no
        view.spellCheckingType = .no
        view.smartDashesType = .no
        view.smartQuotesType = .no
        view.textContainerInset = .zero
        view.returnKeyType = .default
        return view
    }

    func updateUIView(_ view: KeyboardTextView, context: Context) {
        if model.keyboardActive {
            guard !view.isFirstResponder else { return }
            context.coordinator.summonKeyboard(view: view, model: model, usesSceneOrientation: usesSceneOrientation)
        } else {
            context.coordinator.cancelFocus()
            if view.isFirstResponder {
                view.resignFirstResponder()
            }
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        private let model: RemoteTrackpadModel
        private var focusAttempts = 0
        private var summonInFlight = false

        /// The keyboard takes the scene's orientation when it is presented, so
        /// in a landscape hold wait for the rotation the model requested to
        /// land before summoning it. Bounded: a rotation that never lands
        /// still presents the keyboard.
        func summonKeyboard(view: KeyboardTextView, model: RemoteTrackpadModel, usesSceneOrientation: Bool) {
            guard view.window != nil, !summonInFlight else { return }
            let desired = usesSceneOrientation ? InterfaceOrientationController.shared.supportedMask : InterfaceOrientationController.mask(for: model.orientation)
            let current = view.window?.windowScene?.interfaceOrientation
            let settled: Bool
            if current == nil {
                settled = true
            } else if desired == .portrait {
                settled = current == .portrait
            } else {
                settled = current?.isLandscape == true
            }
            if settled || focusAttempts >= Self.maximumFocusAttempts {
                focusAttempts = 0
                view.becomeFirstResponder()
                return
            }
            focusAttempts += 1
            summonInFlight = true
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.focusRetryInterval) { [weak self, weak view, weak model] in
                guard let self else { return }
                self.summonInFlight = false
                guard let view, let model, model.keyboardActive else { return }
                self.summonKeyboard(view: view, model: model, usesSceneOrientation: usesSceneOrientation)
            }
        }

        func cancelFocus() {
            focusAttempts = 0
            summonInFlight = false
        }

        private static let maximumFocusAttempts = 24
        private static let focusRetryInterval: TimeInterval = 0.05

        init(model: RemoteTrackpadModel) { self.model = model }

        func textViewDidChange(_ textView: UITextView) {
            guard textView.markedTextRange == nil, !textView.text.isEmpty else { return }
            let committed = textView.text ?? ""
            textView.text = ""
            model.sendTextInput(.insert(committed))
        }

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText text: String
        ) -> Bool {
            guard text == "\n", textView.markedTextRange == nil else { return true }
            model.sendTextInput(.returnKey)
            return false
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            model.dismissKeyboard()
        }
    }
}

final class KeyboardTextView: UITextView {
    var onEmptyDelete: (() -> Void)?

    override func deleteBackward() {
        let wasEmpty = text.isEmpty && markedTextRange == nil
        super.deleteBackward()
        if wasEmpty { onEmptyDelete?() }
    }
}

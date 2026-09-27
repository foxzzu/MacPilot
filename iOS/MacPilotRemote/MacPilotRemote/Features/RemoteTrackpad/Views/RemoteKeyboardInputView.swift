import MacPilotRemoteProtocol
import SwiftUI
import UIKit

/// A one-point text responder that presents the native iPhone keyboard while
/// the trackpad remains visible. Marked IME text stays local until committed.
struct RemoteKeyboardInputView: UIViewRepresentable {
    @ObservedObject var model: RemoteTrackpadModel

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
            DispatchQueue.main.async { [weak view, weak model] in
                guard let view, model?.keyboardActive == true, view.window != nil else { return }
                view.becomeFirstResponder()
            }
        } else if view.isFirstResponder {
            view.resignFirstResponder()
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        private let model: RemoteTrackpadModel

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

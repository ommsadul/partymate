import SwiftUI
import UIKit

/// An invisible text field that opens the system emoji keyboard, so you can pick any emoji
/// (with the keyboard's own search). iOS has no public emoji picker, so this is the standard way.
/// Set `isActive` to true to bring the keyboard up; it closes after one emoji is picked.
struct EmojiKeyboardField: UIViewRepresentable {
    @Binding var emoji: String
    @Binding var isActive: Bool

    func makeUIView(context: Context) -> EmojiOnlyTextField {
        let field = EmojiOnlyTextField()
        field.delegate = context.coordinator
        field.tintColor = .clear
        field.textColor = .clear
        field.autocorrectionType = .no
        return field
    }

    func updateUIView(_ field: EmojiOnlyTextField, context: Context) {
        context.coordinator.parent = self
        if isActive, !field.isFirstResponder {
            field.becomeFirstResponder()
        } else if !isActive, field.isFirstResponder {
            field.resignFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: EmojiKeyboardField

        init(_ parent: EmojiKeyboardField) {
            self.parent = parent
        }

        func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
            // Keep the field empty; take the first emoji typed and close the keyboard.
            if let picked = string.first(where: \.isEmoji) {
                parent.emoji = String(picked)
                parent.isActive = false
            }
            return false
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            parent.isActive = false
        }
    }
}

/// A text field whose keyboard is always the emoji keyboard.
final class EmojiOnlyTextField: UITextField {
    // A unique context stops iOS from restoring whichever keyboard was used last.
    override var textInputContextIdentifier: String? { "partymate.emoji" }

    override var textInputMode: UITextInputMode? {
        UITextInputMode.activeInputModes.first { $0.primaryLanguage == "emoji" } ?? super.textInputMode
    }
}

extension Character {
    /// True for characters drawn as emoji (including skin tones, flags, and ZWJ sequences).
    var isEmoji: Bool {
        guard let first = unicodeScalars.first else { return false }
        return first.properties.isEmojiPresentation
            || (first.properties.isEmoji && unicodeScalars.count > 1)
    }
}

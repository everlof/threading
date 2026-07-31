import AppKit

// MARK: - Text Prompt Request

/// A one-field prompt: a title, a field, and a button that accepts what was typed.
struct TextPromptRequest {
    let title: String
    var message: String?
    let confirmTitle: String

    /// A second affirmative that answers with nothing rather than with the field — "Use Agent's
    /// Name", and any future sibling. It sits between confirm and cancel because it is
    /// something the sheet does, not a way out of it.
    var clearTitle: String?
    var cancelTitle: String = L10n.string("Cancel")

    var current: String = ""
    var placeholder: String = ""

    /// Whether an empty field is an answer. Renames allow it — clearing a custom name is a
    /// thing to mean — while a branch name or a host is not worth accepting blank.
    var allowsEmpty: Bool = false

    var fieldSize = NSSize(
        width: TextPromptDefaults.fieldWidth,
        height: TextPromptDefaults.fieldHeight
    )
}

enum TextPromptDefaults {
    static let fieldWidth: CGFloat = 240
    /// An accessory view is given a frame rather than asked for its intrinsic size, so the
    /// field's own height has to be restated here — from the same token, or the one field the
    /// app puts in front of a decision is the tightest one it draws.
    static let fieldHeight: CGFloat = Design.Size.fieldHeight
}

// MARK: - Text Prompt Alert

/// Every "type a short string" prompt in the app.
///
/// It is not a confirmation and carries no `ConfirmationPrompt`: nothing here can be answered
/// once and remembered, because the answer *is* the input. It lives beside `ConfirmationAlert`
/// anyway, and that is deliberate — `scripts/theme_boundary_lint.swift` bans reading
/// `alertNthButtonReturn` outside `UI/Alerts`, and these five prompts were the only sites where
/// that read meant something other than a decision. Keeping them here is what lets the lint's
/// exception list stay at one entry instead of holing five files that also hold real
/// confirmations.
///
/// The five were five copies of the same dozen lines, and they had drifted: two trimmed
/// whitespace only, three trimmed newlines too, so a pasted name kept its trailing return in
/// some places and not others.
@MainActor
enum TextPromptAlert {

    enum Answer: Equatable {
        /// What was typed, trimmed. Empty only when the request allows it.
        case text(String)

        /// The second affirmative — answer with the default rather than the field.
        case cleared
    }

    /// `nil` is Cancel, and so is an empty field the request did not allow: both mean the
    /// caller does nothing, and separating them would invite a caller to act on a blank.
    static func ask(_ request: TextPromptRequest) -> Answer? {
        let alert = ThemedAlert()
        alert.messageText = request.title
        if let message = request.message {
            alert.informativeText = message
        }
        alert.addButton(withTitle: request.confirmTitle)
        if let clearTitle = request.clearTitle {
            alert.addButton(withTitle: clearTitle)
        }
        alert.addButton(withTitle: request.cancelTitle)

        let field = ThemedTextField(frame: NSRect(origin: .zero, size: request.fieldSize))
        field.stringValue = request.current
        field.placeholderString = request.placeholder
        alert.accessoryView = field
        alert.initialFirstResponder = field

        let optionCount = request.clearTitle == nil ? 1 : 2
        switch ConfirmationAlert.chosenIndex(alert.runModal(), optionCount: optionCount) {
        case 0:
            let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard request.allowsEmpty || !trimmed.isEmpty else { return nil }
            return .text(trimmed)
        case 1:
            return .cleared
        default:
            return nil
        }
    }
}

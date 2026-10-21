import AppKit

/// A one-field prompt: a title, a field, and a button that accepts what was typed.
struct TextPromptRequest {
    let title: String
    var message: String?
    let confirmTitle: String

    /// A second affirmative that answers with the **same** field and differs only in what the
    /// caller then does with it — "Add to Chat" holds the comment in the composer, "Send" hands
    /// it to the agent now. It carries ⌘↩, so a comment is one decision at the keyboard rather
    /// than a trip to the mouse, and `ThemedAlert` draws both chords once either exists.
    var immediateTitle: String?

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

    /// The field for a sentence rather than for a name. A comment on a diff line or an
    /// attachment is prose — "the axis labels are too small to read at this size" — and the
    /// 240pt box a branch name lives in scrolls that out of sight while it is being written.
    static let commentFieldWidth: CGFloat = 420
}

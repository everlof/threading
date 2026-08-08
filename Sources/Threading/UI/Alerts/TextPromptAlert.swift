import AppKit

// MARK: - Text Prompt Request

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

        /// The same field, through the accelerated affirmative — ⌘↩, "Send".
        case immediate(String)

        /// The affirmative that answers with the default rather than the field.
        case cleared
    }

    /// Which affirmative a button index means. Built beside the buttons so the two orders
    /// cannot drift: an index read against a hand-counted `optionCount` was the shape of this
    /// before there were three of them.
    private enum Affirmative {
        case confirm
        case immediate
        case cleared
    }

    /// The buttons a request asks for, in the order `ThemedAlert` is given them.
    static func affirmatives(for request: TextPromptRequest) -> [String] {
        order(for: request).map { affirmative in
            switch affirmative {
            case .confirm: return request.confirmTitle
            case .immediate: return request.immediateTitle ?? ""
            case .cleared: return request.clearTitle ?? ""
            }
        }
    }

    private static func order(for request: TextPromptRequest) -> [Affirmative] {
        var order: [Affirmative] = [.confirm]
        if request.immediateTitle != nil { order.append(.immediate) }
        if request.clearTitle != nil { order.append(.cleared) }
        return order
    }

    /// Built without being run, so a test can read the wording, the button order, and which
    /// button carries Return and which carries ⌘Return.
    static func makeAlert(
        _ request: TextPromptRequest,
        field: NSView,
        supportingView: NSView? = nil
    ) -> ThemedAlert {
        let alert = ThemedAlert()
        alert.messageText = request.title
        if let message = request.message {
            alert.informativeText = message
        }
        for affirmative in order(for: request) {
            switch affirmative {
            case .confirm:
                alert.addButton(withTitle: request.confirmTitle)
            case .immediate:
                let button = alert.addButton(withTitle: request.immediateTitle ?? "")
                button.shortcut = KeyboardShortcut(key: "\r", modifiers: .command)
            case .cleared:
                alert.addButton(withTitle: request.clearTitle ?? "")
            }
        }
        alert.addButton(withTitle: request.cancelTitle)
        alert.accessoryView = accessory(field: field, supportingView: supportingView)
        alert.initialFirstResponder = field
        return alert
    }

    /// `nil` is Cancel, and so is an empty field the request did not allow: both mean the
    /// caller does nothing, and separating them would invite a caller to act on a blank.
    static func ask(_ request: TextPromptRequest, supportingView: NSView? = nil) -> Answer? {
        let field = ThemedTextField(frame: NSRect(origin: .zero, size: request.fieldSize))
        field.stringValue = request.current
        field.placeholderString = request.placeholder

        let order = order(for: request)
        let alert = makeAlert(request, field: field, supportingView: supportingView)
        guard let index = ConfirmationAlert.chosenIndex(
            alert.runModal(),
            optionCount: order.count
        ) else { return nil }

        if order[index] == .cleared { return .cleared }
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard request.allowsEmpty || !trimmed.isEmpty else { return nil }
        return order[index] == .immediate ? .immediate(trimmed) : .text(trimmed)
    }

    /// Places read-only context above the field without making that context the sheet's first
    /// responder. The wrapper uses a fixed, request-owned width because `ThemedAlert` receives
    /// accessory views by frame; its height remains the bounded preview plus the ordinary field.
    private static func accessory(field: NSView, supportingView: NSView?) -> NSView {
        guard let supportingView else { return field }
        return TextPromptAccessoryView(field: field, supportingView: supportingView)
    }
}

// MARK: - Accessory Layout

/// Structural layout only. Both visible children remain design-system components.
@MainActor
private final class TextPromptAccessoryView: NSView {
    private let field: NSView
    private let supportingView: NSView
    private let spacing = Design.Spacing.medium
    private let fieldHeight: CGFloat
    private let supportingHeight: CGFloat

    init(field: NSView, supportingView: NSView) {
        self.field = field
        self.supportingView = supportingView
        fieldHeight = max(max(field.frame.height, field.fittingSize.height), 1)
        supportingHeight = max(max(
            supportingView.intrinsicContentSize.height,
            supportingView.fittingSize.height
        ), 1)
        let width = max(max(field.frame.width, supportingView.fittingSize.width), 1)
        super.init(frame: NSRect(
            x: 0,
            y: 0,
            width: width,
            height: supportingHeight + Design.Spacing.medium + fieldHeight
        ))
        addSubview(supportingView)
        addSubview(field)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        field.frame = NSRect(x: 0, y: 0, width: bounds.width, height: fieldHeight)
        supportingView.frame = NSRect(
            x: 0,
            y: fieldHeight + spacing,
            width: bounds.width,
            height: supportingHeight
        )
    }
}

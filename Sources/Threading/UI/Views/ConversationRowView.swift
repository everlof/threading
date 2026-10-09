import AppKit
#if os(Linux)
@testable import CoreSlice
#endif

// MARK: - Conversation Row View

/// Builds the view for one `ConversationTimeline.Row`.
///
/// Split out of `ConversationViewController` so that "what a row looks like" is answerable
/// without a session, a project, a live CLI or a window: the render harness in the tests draws
/// whole fixture conversations through this same function, which is the only way a change to
/// the conversation's appearance can be looked at before it ships.
///
/// One factory rather than a method per row kind on the controller, because the controller was
/// the only caller and every one of those methods was really a constructor. Placement and
/// spacing remain the renderer's business, not the row's.
@MainActor
enum ConversationRowView {

    // MARK: - Rows

    /// The shared design component owns short/long bubble selection and right alignment.
    static func userBubble(_ text: String) -> NSView {
        ConversationUserRow.make(text)
    }

    /// The rule drawn above a user's turn.
    ///
    /// A conversation is a sequence of exchanges, but rendered as one column of evenly spaced
    /// rows it reads as a single stream and the eye cannot find where one exchange ends. Extra
    /// spacing alone was not enough — the rows on either side of it are themselves separated by
    /// space, so a bigger gap is only a bigger gap.
    static func turnDivider() -> NSView {
        let rule = NSView()
        rule.translatesAutoresizingMaskIntoConstraints = false
        rule.wantsLayer = true
        rule.applyLayerBackground(Design.Chat.turnDivider)
        rule.heightAnchor.constraint(equalToConstant: Design.Chat.turnDividerHeight).isActive = true
        return rule
    }

    /// Reasoning, quieter than the reply it precedes — an aside, not the answer.
    static func thinking(_ text: String) -> NSView {
        MarkdownView(markdown: text, style: .thinking)
    }

    /// The durable end marker for a turn that did not produce an ordinary completed answer.
    /// User interruption is neutral; provider failure is an error. The distinction comes from
    /// the provider's typed outcome, never from matching its prose.
    static func turnOutcome(_ outcome: TurnOutcome) -> NSView {
        let (text, color): (String, NSColor) = switch outcome {
        case .completed:
            (L10n.string("Completed"), Design.Text.tertiary)
        case .stopped:
            (L10n.string("Interrupted"), Design.Text.tertiary)
        case .failed:
            (L10n.string("Failed"), Design.Status.negative)
        }
        return label(text, role: .subheading, color: color)
    }

    /// Neither said nor tool output: a truncation banner, a failed turn, an orphan result.
    static func notice(_ text: String, kind: ConversationTimeline.NoticeKind) -> NSView {
        label(
            text,
            role: .subheading,
            color: kind == .error ? Design.Status.negative : Design.Text.tertiary
        )
    }

    /// The reply as it streams. Plain text, replaced by rendered markdown when the message
    /// finishes: rendering markdown per token would reflow the whole block on every keystroke,
    /// and the finished message is authoritative anyway. Set in the Markdown's own face and
    /// leading (`ProseLabel`), so the paragraph keeps its line box across that replacement.
    static func streaming(_ text: String) -> ProseLabel {
        ProseLabel(text: text)
    }

    // MARK: - Private Methods

    /// Takes a role rather than a font: these rows are the transcript, so they resolve in the
    /// `.conversation` surface — a streaming reply that arrived in the chrome font would change
    /// face the moment it finished and became rendered markdown — and recording the role is what
    /// lets a live theme or font-override switch reach them.
    private static func label(_ text: String, role: Design.FontRole, color: NSColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.applyFont(role, in: .conversation)
        label.textColor = color
        label.isSelectable = true
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }
}

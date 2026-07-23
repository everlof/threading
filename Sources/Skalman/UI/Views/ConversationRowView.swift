import AppKit

// MARK: - Conversation Row View

/// Builds the view for one `ConversationTimeline.Row`.
///
/// Split out of `ConversationViewController` so that "what a row looks like" is answerable
/// without a session, a project, a live CLI or a window: the render harness in the tests draws
/// whole fixture conversations through this same function, which is the only way a change to
/// the conversation's appearance can be looked at before it ships.
///
/// One factory rather than a method per row kind on the controller, because the controller was
/// the only caller and every one of those methods was really a constructor. `addRow` still
/// belongs to the controller — placement and spacing are its business, not the row's.
enum ConversationRowView {

    /// The view for a row, and whether it opens a new exchange.
    ///
    /// `startsTurn` is the row's own property rather than the caller's guess: what deserves
    /// space above it is a user turn beginning, which only the row kind knows.
    static func make(for row: ConversationTimeline.Row) -> (view: NSView, startsTurn: Bool) {
        switch row {
        case .userMessage(let text):
            return (userBubble(text), true)

        case .assistant(let markdown):
            return (MarkdownView(markdown: markdown), false)

        case .thinking(let text):
            return (thinking(text), false)

        case .notice(let text, let kind):
            return (notice(text, kind: kind), false)

        case .toolCall(let call):
            let view = ToolCallView(tool: call.tool, summary: call.summary, diff: call.diff)
            if let result = call.result {
                view.setResult(result.text, isError: result.isError)
            }
            return (view, false)
        }
    }

    // MARK: - Rows

    /// The user's turn: a right-aligned bubble, capped so a short instruction is not a
    /// full-width banner. A bubble suits an instruction; flowing text suits a long answer, and
    /// forcing either into the other's shape is what makes agent UIs read as log viewers.
    static func userBubble(_ text: String) -> NSView {
        let bubble = NSView()
        bubble.translatesAutoresizingMaskIntoConstraints = false
        bubble.applySurface(fill: Design.Chat.bubbleFill, radius: Design.Radius.panel)

        let label = NSTextField(wrappingLabelWithString: text)
        label.font = Design.Typography.body()
        label.textColor = Design.Text.label
        label.isSelectable = true
        label.translatesAutoresizingMaskIntoConstraints = false
        bubble.addSubview(label)

        let pad = Design.Spacing.medium
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: bubble.topAnchor, constant: pad),
            label.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -pad),
            label.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: pad),
            label.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -pad)
        ])

        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(bubble)
        NSLayoutConstraint.activate([
            bubble.topAnchor.constraint(equalTo: row.topAnchor),
            bubble.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            bubble.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            bubble.leadingAnchor.constraint(greaterThanOrEqualTo: row.leadingAnchor),
            bubble.widthAnchor.constraint(
                lessThanOrEqualTo: row.widthAnchor,
                multiplier: Design.Chat.bubbleMaxWidthFraction
            )
        ])

        return row
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
        label(text, font: Design.Typography.body(), color: Design.Text.tertiary)
    }

    /// Neither said nor tool output: a truncation banner, a failed turn, an orphan result.
    static func notice(_ text: String, kind: ConversationTimeline.NoticeKind) -> NSView {
        label(
            text,
            font: Design.Typography.subheading(),
            color: kind == .error ? Design.Status.negative : Design.Text.tertiary
        )
    }

    /// The reply as it streams. Plain text, replaced by rendered markdown when the message
    /// finishes: rendering markdown per token would reflow the whole block on every keystroke,
    /// and the finished message is authoritative anyway.
    static func streaming(_ text: String) -> NSTextField {
        label(text, font: Design.Typography.body(), color: Design.Text.label)
    }

    // MARK: - Private Methods

    private static func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = font
        label.textColor = color
        label.isSelectable = true
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }
}

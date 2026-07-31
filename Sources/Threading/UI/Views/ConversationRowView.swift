import AppKit

// MARK: - Conversation Row Presentation

/// The chronological units a compact transcript draws.
///
/// The timeline deliberately retains every tool call as a first-class row. Compact surfaces
/// can reduce only adjacent calls into a disclosure without losing their position among the
/// agent's prose or changing the canonical conversation model.
enum ConversationRowPresentation {
    enum Item: Equatable {
        case row(ConversationTimeline.Row)
        case toolCalls([ConversationTimeline.ToolCall])
    }

    static func compact(_ rows: [ConversationTimeline.Row]) -> [Item] {
        var result: [Item] = []
        var calls: [ConversationTimeline.ToolCall] = []

        func flushCalls() {
            guard !calls.isEmpty else { return }
            result.append(.toolCalls(calls))
            calls.removeAll(keepingCapacity: true)
        }

        for row in rows {
            if case .toolCall(let call) = row {
                calls.append(call)
            } else {
                flushCalls()
                result.append(.row(row))
            }
        }
        flushCalls()
        return result
    }
}

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
@MainActor
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
                view.setResult(result.text, outcome: result.outcome)
            }
            return (view, false)
        }
    }

    // MARK: - Rows

    /// The user's turn: a right-aligned bubble, capped so a short instruction is not a
    /// full-width banner. A bubble suits an instruction; flowing text suits a long answer, and
    /// forcing either into the other's shape is what makes agent UIs read as log viewers.
    ///
    /// A *long* message — a pasted log, a briefing — collapses behind a fade instead
    /// (`UserMessageBubbleView`): the user wrote it, so drawn in full it drowns the answer it
    /// was written to get.
    static func userBubble(_ text: String) -> NSView {
        if ConversationDefaults.collapsesUserMessage(text) {
            return rightAligned(UserMessageBubbleView(text: text))
        }

        let bubble = NSView()
        bubble.translatesAutoresizingMaskIntoConstraints = false
        bubble.applySurface(fill: Design.Chat.bubbleFill, radius: .panel)

        let label = NSTextField(wrappingLabelWithString: text)
        label.applyFont(.body, in: .conversation)
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

        return rightAligned(bubble)
    }

    /// The row wrapper both bubble shapes share: trailing-aligned, capped to the bubble
    /// fraction of the pane.
    private static func rightAligned(_ bubble: NSView) -> NSView {
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
        label(text, role: .body, color: Design.Text.tertiary)
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
    /// and the finished message is authoritative anyway.
    static func streaming(_ text: String) -> NSTextField {
        label(text, role: .body, color: Design.Text.label)
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

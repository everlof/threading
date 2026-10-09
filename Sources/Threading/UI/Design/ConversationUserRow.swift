import AppKit

/// Shared anatomy for both user-message shapes. The host owns text identity and expansion.
@MainActor
enum ConversationUserRow {
    /// The user's turn: a right-aligned bubble, capped so a short instruction is not a
    /// full-width banner. A bubble suits an instruction; flowing text suits a long answer, and
    /// forcing either into the other's shape is what makes agent UIs read as log viewers.
    ///
    /// A *long* message — a pasted log, a briefing — collapses behind a fade instead
    /// (`UserMessageBubbleView`): the user wrote it, so drawn in full it drowns the answer it
    /// was written to get.
    static func make(
        _ text: String,
        expanded: Bool = false,
        onExpansionChanged: ((Bool) -> Void)? = nil
    ) -> NSView {
        if ConversationUserRowDefaults.collapsesUserMessage(text) {
            let bubble = UserMessageBubbleView(text: text)
            bubble.setExpanded(expanded, notifying: false)
            bubble.onExpansionChanged = onExpansionChanged
            return rightAligned(bubble)
        }

        let bubble = NSView()
        bubble.translatesAutoresizingMaskIntoConstraints = false
        bubble.applySurface(fill: Design.Chat.bubbleFill, radius: .panel)

        #if os(Linux)
        let label = NSTextField(wrappingLabelWithString: text)
        label.applyFont(.body, in: .conversation)
        label.textColor = Design.Text.label
        label.isSelectable = true
        label.translatesAutoresizingMaskIntoConstraints = false
        #else
        let label = ProseLabel(text: text)
        #endif
        bubble.addSubview(label)

        // A bubble is padded tighter than a card — `medium`, measured against the conversation's
        // rhythm — and its corner is the panel's, which under a broad theme is 40pt. At that
        // radius the arc has crossed x=13 by the height of the first line, so a 10pt padding put
        // the opening word *outside* the shape. The corner pushes it in; nothing pulls it back.
        let pad = Design.Spacing.medium
        let padding = [
            label.topAnchor.constraint(equalTo: bubble.topAnchor, constant: pad),
            label.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -pad),
            label.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: pad),
            label.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -pad)
        ]
        NSLayoutConstraint.activate(padding)
        bubble.holdAtContentInset(padding, from: pad)

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
}

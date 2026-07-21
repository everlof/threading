import AppKit

// MARK: - Rendering

/// Drawing the conversation, split from the controller that drives it. Same file, so the
/// private state these read stays private.
///
/// The user's turns are bubbles on the right; the agent's replies are markdown down the left,
/// the way a modern chat client reads. A bubble suits a short instruction; flowing text suits
/// a long answer, and forcing either into the other's shape is what makes agent UIs feel like
/// log viewers.
///
/// A separate file, so these are `internal` rather than `private`; the controller and this
/// extension are one type split for length, not two.
extension ConversationViewController {

    /// The user's turn: a right-aligned bubble, capped so a short reply is not a full-width
    /// banner.
    func appendUserBubble(_ text: String) {
        let bubble = NSView()
        bubble.translatesAutoresizingMaskIntoConstraints = false
        bubble.applySurface(fill: Design.Chat.bubbleFill, radius: Design.Radius.panel)

        let label = NSTextField(wrappingLabelWithString: text)
        label.font = Design.Typography.body()
        label.textColor = .labelColor
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

        addRow(row, newTurn: true)
    }

    /// The agent's reply, rendered as markdown so headings, lists and code read as written.
    func appendAssistant(markdown: String) {
        addRow(MarkdownView(markdown: markdown))
    }

    /// Reasoning, shown quieter than the reply it precedes — an aside, not the answer.
    func appendThinking(_ text: String) {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = Design.Typography.body()
        label.textColor = .tertiaryLabelColor
        label.isSelectable = true
        label.translatesAutoresizingMaskIntoConstraints = false
        addRow(label)
    }

    /// A standalone line that is neither said nor tool output — a truncation note, an error.
    func appendNotice(_ text: String, color: NSColor) {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = Design.Typography.subheading()
        label.textColor = color
        label.isSelectable = true
        label.translatesAutoresizingMaskIntoConstraints = false
        addRow(label)
    }

    /// The reply as it streams, plain text replaced by the rendered markdown once the message
    /// finishes. Rendering markdown per token would reflow the whole block on every keystroke;
    /// the raw text costs nothing and the finished copy is authoritative anyway.
    func appendStreaming(_ text: String) {
        streamingText += text

        guard let streamingLabel else {
            let label = NSTextField(wrappingLabelWithString: streamingText)
            label.font = Design.Typography.body()
            label.textColor = .labelColor
            label.isSelectable = true
            label.translatesAutoresizingMaskIntoConstraints = false
            addRow(label)
            self.streamingLabel = label
            return
        }

        streamingLabel.stringValue = streamingText
        scrollToBottom()
    }

    /// Drops the streaming placeholder, whose content the finished message repeats.
    func clearStreaming() {
        streamingLabel?.removeFromSuperview()
        streamingLabel = nil
        streamingText = ""
    }

    // MARK: - Layout

    /// Adds one full-width row, insetting its content from the pane edges consistently.
    ///
    /// `newTurn` opens extra space above the row, used before a user bubble so each exchange
    /// reads as its own block rather than one unbroken column.
    func addRow(_ view: NSView, newTurn: Bool = false) {
        let previous = stack.arrangedSubviews.last

        stack.addArrangedSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: Design.Spacing.inset),
            view.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -Design.Spacing.inset)
        ])

        if newTurn, let previous {
            stack.setCustomSpacing(Design.Chat.turnSpacing, after: previous)
        }

        scrollToBottom()
    }

    func setStatus(_ text: String) {
        statusLabel.stringValue = text
    }

    func scrollToBottom() {
        guard !isReplaying else { return }

        // After layout, or the scroll targets the height the stack had before this message.
        DispatchQueue.main.async { [weak self] in
            guard let self, let documentView = self.scrollView.documentView else { return }

            let overflow = documentView.bounds.height - self.scrollView.contentSize.height
            documentView.scroll(NSPoint(x: 0, y: max(0, overflow)))
        }
    }
}

// MARK: - Permissions

/// Approval requests, split into an extension so the controller body stays within length.
/// Same file, so the private queue and card state stay private.
extension ConversationViewController {

    /// Queues a tool-approval request, showing it as a card once any earlier one is answered.
    ///
    /// The card stays in the transcript after the decision as a record of what was allowed, and
    /// while anything waits it drives the sidebar's attention dot through `activity`.
    func presentPermission(_ request: PermissionRequest, decide: @escaping (PermissionDecision) -> Void) {
        // Force the view to load if the session has never been shown: touching `view` is the
        // 13-compatible `loadViewIfNeeded()`, and the card must exist to be resolved.
        _ = view

        permissionQueue.append((request, decide))
        delegate?.conversationDidChangeActivity(self)

        // A request raised in a session the user is not looking at bounces the dock, since the
        // agent is blocked until it is answered.
        if !isVisible {
            NSApp.requestUserAttention(.informationalRequest)
        }

        showNextPermissionIfIdle()
    }

    /// Shows the next queued request, unless one is already on screen awaiting an answer.
    private func showNextPermissionIfIdle() {
        guard activePermissionCard == nil, !permissionQueue.isEmpty else { return }

        let pending = permissionQueue.removeFirst()

        var card: PermissionRequestView?
        card = PermissionRequestView(request: pending.request) { [weak self] decision in
            pending.decide(decision)
            guard let self else { return }
            if self.activePermissionCard === card { self.activePermissionCard = nil }
            self.delegate?.conversationDidChangeActivity(self)
            self.showNextPermissionIfIdle()
        }

        guard let card else { return }
        activePermissionCard = card
        addRow(card, newTurn: true)
    }
}

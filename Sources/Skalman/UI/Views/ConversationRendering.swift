import AppKit

// MARK: - Rendering

/// Applying timeline changes to the view tree, split from the controller that drives it. Same
/// type, separate file for length, so the private state these read stays private.
///
/// What a row *is* now lives in `ConversationTimeline`, and what one *looks like* in
/// `ConversationRowView`. What is left here is placement: which view goes where, what gets
/// space above it, and which existing view a late-arriving tool result belongs to.
extension ConversationViewController {

    // MARK: - Changes

    /// Brings the view tree in line with one change the timeline reported.
    func apply(_ change: ConversationTimeline.Change) {
        switch change {
        case .appended(let index):
            let row = timeline.rows[index]
            let (view, startsTurn) = ConversationRowView.make(for: row)

            // Not before the first turn: a rule at the very top of the pane separates the
            // conversation from nothing.
            if startsTurn, !stack.arrangedSubviews.isEmpty {
                addRow(ConversationRowView.turnDivider(), newTurn: true)
            }

            // Kept for the rows something later needs to find: a tool call, so its result can
            // be attached, and a user message, because the turn rail scrolls to it. Everything
            // else is drawn once and never addressed again.
            switch row {
            case .toolCall, .userMessage: rowViews[index] = view
            default: break
            }

            addRow(view, newTurn: startsTurn)

            // The rail indexes user turns, so it only ever changes when one is added.
            if case .userMessage = row { refreshMinimap() }

        case .resultAttached(let index):
            guard case .toolCall(let call) = timeline.rows[index],
                  let toolView = rowViews[index] as? ToolCallView,
                  let result = call.result else { return }

            toolView.setResult(result.text, isError: result.isError)
            rowViews[index] = nil
            scrollToBottom()

        case .streaming(let text):
            guard let text else { return clearStreaming() }
            showStreaming(text)

        case .status(let status):
            // The orb runs only while a turn is in flight; hidden, it detaches
            // from the status row and its display link idles.
            if case .working(let word) = status {
                if orbView.isHidden {
                    orbView.prepareForWorking(style: AppSettings.shared.workingOrbStyle)
                }
                orbView.isHidden = false
                beginWorkingStatus(word: word)
            } else {
                orbView.isHidden = true
                endWorkingStatus()
                setStatus(describe(status))
            }

        case .adoptedSessionID(let agentSessionID):
            // The CLI's own identifier wins: a resume can settle on one other than the
            // identifier we asked for, and resuming again must use what it actually used.
            ProjectStore.shared.update(sessionID: agentSession.id) {
                $0.resumeState = .resumable(agentSessionID)
            }
        }
    }

    /// Appends a note the view raises itself — the replay banner, an unexpected exit — through
    /// the timeline, so it takes its place in the row list rather than being a loose view the
    /// model does not know about.
    func appendNotice(_ text: String, kind: ConversationTimeline.NoticeKind) {
        apply(timeline.appendNotice(text, kind: kind))
    }

    private func describe(_ status: ConversationTimeline.Status) -> String {
        switch status {
        case .loading:
            return "Loading conversation…"
        case .ready(let model, let lastTurn):
            // A reported model names the status; otherwise the session may still be starting,
            // in which case saying Ready would invite a message the CLI cannot yet receive.
            if model == nil, lastTurn == nil, !stream.canSend { return "Starting…" }
            return TurnStatusText.ready(model: model, lastTurn: lastTurn)
        case .working(let word):
            return word
        case .ended(let code):
            return code == 0 ? "Session ended" : "Session ended (\(code))"
        }
    }

    private func beginWorkingStatus(word: String) {
        workingStatusTimer?.invalidate()
        workingStartedAt = ProcessInfo.processInfo.systemUptime

        updateWorkingStatus(word: word)
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.updateWorkingStatus(word: word)
        }
        workingStatusTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func updateWorkingStatus(word: String) {
        let elapsed = workingStartedAt.map {
            max(0, ProcessInfo.processInfo.systemUptime - $0)
        } ?? 0
        setStatus(TurnStatusText.working(
            word: word,
            elapsed: elapsed,
            effort: configuredEffort
        ))
    }

    private func endWorkingStatus() {
        workingStatusTimer?.invalidate()
        workingStatusTimer = nil
        workingStartedAt = nil
    }

    // MARK: - Streaming

    private func showStreaming(_ text: String) {
        guard let streamingLabel else {
            let label = ConversationRowView.streaming(text)
            addRow(label)
            self.streamingLabel = label
            return
        }

        streamingLabel.stringValue = text
        scrollToBottom()
    }

    /// Drops the streaming placeholder, whose content the finished message repeats.
    func clearStreaming() {
        streamingLabel?.removeFromSuperview()
        streamingLabel = nil
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

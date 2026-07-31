import AppKit
import ThreadingExtensionKit

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
            let startsTurn: Bool
            if case .userMessage = row { startsTurn = true } else { startsTurn = false }

            // A turn that stayed expanded because it was interrupted folds the moment the next
            // one begins — the user has moved on, and t3code's rule is exactly this handoff.
            if startsTurn, isReplaying { attachDeferredReplayRows() }
            if startsTurn, let pending = pendingFold {
                pendingFold = nil
                foldTurn(startingAt: pending.startIndex, stopped: pending.interrupted)
            }

            // Not before the first turn: a rule at the very top of the pane separates the
            // conversation from nothing.
            if startsTurn, timeline.rows.count > 1 {
                addRow(ConversationRowView.turnDivider(), newTurn: true)
            }

            if isReplaying, !startsTurn {
                deferredReplayRowIndices.insert(index)
            } else {
                let view = materializeRow(at: index)
                addRow(view, newTurn: startsTurn)
            }

            // The rail indexes user turns, so it only ever changes when one is added.
            if case .userMessage = row, !isReplaying { refreshMinimap() }

        case .resultAttached(let index):
            guard case .toolCall(let call) = timeline.rows[index],
                  let toolView = pendingToolViews[index],
                  let result = call.result else { return }

            toolView.setResult(result.text, outcome: result.outcome)
            // An interrupted row keeps its view reference: the real result can still arrive
            // after the turn ends, and it should land on the row rather than be lost.
            if result.outcome != .interrupted { pendingToolViews[index] = nil }
            scrollToBottom()

        case .streaming(let text):
            guard let text else { return clearStreaming() }
            showStreaming(text)

        case .status(let status):
            let wasInFlight = isTurnInFlight
            isTurnInFlight = {
                if case .working = status { return true }
                return false
            }()
            if !isTurnInFlight { runProgress = nil }

            // The meter follows metrics, not the status: a Ready that carries none — the
            // post-replay reset, a model change — must not blank a reading that still holds.
            if case .ready(_, let lastTurn) = status,
               let tokens = lastTurn?.contextTokens {
                lastContextReading = (tokens, lastTurn?.contextWindow)
                updateContextMeter()
            }

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
            if isTurnInFlight != wasInFlight {
                // The edge is the turn boundary, and the only place the agent's own running
                // work is weighed. A status restated without an edge — a re-init, a model
                // change — is not a boundary and must not spend it.
                noteTurnBoundary()
                delegate?.conversationDidChangeActivity(self)
            }

        case .runProgress(let progress):
            guard runProgress != progress else { return }
            runProgress = progress
            if isTurnInFlight {
                delegate?.conversationDidChangeActivity(self)
            }

        case .turnSettled(let startIndex, let interrupted):
            // A settled turn folds at once. An interrupted one stays expanded so the user
            // keeps their place, and the *next* turn folds it — but it reads "Stopped after"
            // rather than claiming to have worked.
            if interrupted {
                pendingFold = (startIndex, true)
                if isReplaying { attachDeferredReplayRows() }
            } else {
                foldTurn(startingAt: startIndex, stopped: false)
            }
            appendChangedFilesCard(forTurnStartingAt: startIndex)

        case .adoptedSessionID(let agentSessionID):
            // The CLI's own identifier wins: a resume can settle on one other than the
            // identifier we asked for, and resuming again must use what it actually used.
            ProjectStore.shared.update(sessionID: agentSession.id) {
                $0.resumeState = .resumable(agentSessionID)
            }
        }
    }

    // MARK: - Turn Folding

    /// Collapses a settled turn's work — everything between its user message and its final
    /// assistant reply — behind a one-line `TurnFoldView`.
    ///
    /// Live work views stay retained but leave the stack and its layout engine. Replayed work
    /// may remain as timeline rows until the first expansion, then its exact views are reused.
    /// Permission cards deliberately stay visible — a decided card is the record of what was
    /// allowed, which is worth more than the symmetry.
    func foldTurn(startingAt startIndex: Int, stopped: Bool) {
        guard !foldedTurnStarts.contains(startIndex),
              let turn = timeline.turns.first(where: { $0.rowIndex == startIndex }),
              turn.endIndex > turn.rowIndex,
              let userView = rowViews[turn.rowIndex],
              let userPosition = stack.arrangedSubviews.firstIndex(of: userView) else { return }

        let turnIndices = turn.rowIndex + 1 ... turn.endIndex
        let hiddenIndices = turnIndices.filter { $0 != turn.finalAssistantIndex }
        guard !hiddenIndices.isEmpty else {
            attachDeferredReplayRows(in: turnIndices)
            return
        }
        let hiddenViews = hiddenIndices.compactMap { rowViews[$0] }

        foldedTurnStarts.insert(startIndex)

        let fold = TurnFoldView(
            duration: turn.duration,
            stopped: stopped,
            folding: hiddenViews
        ) { [weak self] fold, isExpanded in
            self?.setTurnWork(hiddenIndices, expanded: isExpanded, after: fold)
        }
        stack.insertArrangedSubview(fold, at: userPosition + 1)
        pinRow(fold)

        // Live rows are already attached and must leave the layout engine. Replayed rows were
        // deferred, so only the final answer is materialized and enters the stack at all.
        hiddenViews.filter { $0.superview != nil }.forEach { detachRow($0) }
        if let finalAssistantIndex = turn.finalAssistantIndex {
            let finalAssistant = materializeRow(at: finalAssistantIndex)
            if finalAssistant.superview == nil {
                stack.insertArrangedSubview(finalAssistant, at: userPosition + 2)
                pinRow(finalAssistant)
            }
        }
        for index in turnIndices { deferredReplayRowIndices.remove(index) }
    }

    /// Makes an interrupted or truncated replay tail visible. Successful turns consume their
    /// deferred indices in `foldTurn`, materializing only the final answer.
    func finishReplayRendering() {
        attachDeferredReplayRows()
    }

    private func attachDeferredReplayRows(in indices: ClosedRange<Int>? = nil) {
        let selected = deferredReplayRowIndices
            .filter { indices?.contains($0) ?? true }
            .sorted()
        for index in selected {
            let view = materializeRow(at: index)
            if view.superview == nil { addRow(view) }
            deferredReplayRowIndices.remove(index)
        }
    }

    /// Creates a native row at most once. Replayed folded work reaches this only on expansion;
    /// because the timeline already owns attached tool results, its first view starts in the
    /// same final state an eagerly-created row would have reached incrementally.
    private func materializeRow(at index: Int) -> NSView {
        if let existing = rowViews[index] { return existing }

        let row = timeline.rows[index]
        let (nativeView, _) = ConversationRowView.make(for: row)
        let view: NSView
        if let target = componentTarget(for: row) {
            view = customizeConversationRow(nativeView, target: target)
        } else {
            view = nativeView
        }
        rowViews[index] = view

        // A missing or interrupted result may still arrive after this lazy materialization.
        // Completed replay results are already represented by `ConversationRowView.make` and
        // need no pending view entry.
        if case .toolCall(let call) = row,
           call.result == nil || call.result?.outcome == .interrupted {
            pendingToolViews[index] = nativeView as? ToolCallView
        }
        return view
    }

    /// Materialized collapsed work is retained for exact restoration, but kept out of the tree.
    /// Replay delays its first construction until expansion whenever possible.
    /// `isHidden` alone leaves every nested tool and Markdown constraint in the window's layout
    /// engine, making an ordinary scroll relayout the full history. Reattaching here preserves
    /// the disclosure while keeping collapsed turns as cheap as they look.
    private func setTurnWork(_ indices: [Int], expanded: Bool, after fold: TurnFoldView) {
        if expanded {
            guard let foldPosition = stack.arrangedSubviews.firstIndex(of: fold) else { return }
            for (offset, index) in indices.enumerated() {
                let view = materializeRow(at: index)
                stack.insertArrangedSubview(view, at: foldPosition + offset + 1)
                pinRow(view)
                AppThemeRefresh.repaint(view)
            }
        } else {
            indices.compactMap { rowViews[$0] }.forEach { detachRow($0) }
        }
        stack.needsLayout = true
        scrollView.documentView?.needsLayout = true
    }

    private func detachRow(_ view: NSView, retainingConstraints: Bool = true) {
        stack.removeArrangedSubview(view)
        let key = ObjectIdentifier(view)
        if let constraints = rowEdgeConstraints[key] {
            NSLayoutConstraint.deactivate(constraints)
        }
        if !retainingConstraints { rowEdgeConstraints[key] = nil }
        view.removeFromSuperview()
    }

    private func pinRow(_ view: NSView) {
        let key = ObjectIdentifier(view)
        if let constraints = rowEdgeConstraints[key] {
            NSLayoutConstraint.activate(constraints)
            return
        }
        let constraints = [
            view.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: Design.Spacing.inset),
            view.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -Design.Spacing.inset)
        ]
        rowEdgeConstraints[key] = constraints
        NSLayoutConstraint.activate(constraints)
    }

    // MARK: - Changed Files Card

    /// Asks git what the settled turn changed and, when the answer is non-empty, leaves the
    /// summary card at the end of the turn.
    ///
    /// Live turns only: a replayed turn's baseline is long gone, and diffing today's checkout
    /// against it would attribute later work to an old exchange. The diff reuses the Last Turn
    /// machinery — the same `stash create` baseline, the same reader — so the card and the
    /// review pane cannot disagree about what a turn touched.
    func appendChangedFilesCard(forTurnStartingAt startIndex: Int) {
        guard !isReplaying,
              !changedFilesCardTurns.contains(startIndex),
              let project = ProjectStore.shared.project(forSessionID: agentSession.id),
              let root = GitInfo.repositoryRoot(for: project.folderPath),
              let baseline = GitTurnBaselineStore.shared.baseline(forSessionID: agentSession.id)
        else { return }

        changedFilesCardTurns.insert(startIndex)

        // The insert position is remembered as a view, not an index: by the time the diff
        // returns, the user may already have sent the next message, and the card belongs to
        // the turn that earned it, not to the bottom of the conversation.
        let anchor = stack.arrangedSubviews.last

        GitReviewReader.diff(.lastTurn(baseline), in: root) { [weak self] result in
            guard let self, case .success(let files) = result, !files.isEmpty else { return }

            let tree = ChangedFilesTree.build(from: files.map {
                ChangedFilesTree.File(path: $0.path, added: $0.added, removed: $0.removed)
            })
            self.insertChangedFilesCard(tree, after: anchor)
        }
    }

    private func insertChangedFilesCard(_ tree: ChangedFilesTree, after anchor: NSView?) {
        let card = ChangedFilesCardView(tree: tree) { [weak self] in
            guard let self else { return }
            self.delegate?.conversationDidRequestTurnDiff(self)
        }

        // Only the newest card's View diff still describes what the Last Turn scope shows.
        latestChangedFilesCard?.hideViewDiff()
        latestChangedFilesCard = card

        let position = anchor
            .flatMap { stack.arrangedSubviews.firstIndex(of: $0) }
            .map { $0 + 1 }
            ?? stack.arrangedSubviews.count
        stack.insertArrangedSubview(card, at: position)
        pinRow(card)
        scrollToBottom()
    }

    /// Conversation contracts are scoped to the session, not to message text or row indexes.
    /// Extensions may annotate a kind of row in a known session without receiving transcript
    /// content as an accidental data API.
    private func componentTarget(
        for row: ConversationTimeline.Row
    ) -> ExtensionComponentTarget? {
        let sessionID = agentSession.id.uuidString.lowercased()
        switch row {
        case .userMessage:
            return .conversationUserMessage(sessionID: sessionID)
        case .assistant:
            return .conversationAssistantMessage(sessionID: sessionID)
        case .toolCall:
            return .conversationToolCall(sessionID: sessionID)
        case .thinking, .notice:
            return nil
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
            MainActor.assumeIsolated {
                self?.updateWorkingStatus(word: word)
            }
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
            effort: effectiveEffort
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
        if let streamingLabel {
            detachRow(streamingLabel, retainingConstraints: false)
        }
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
        pinRow(view)

        if newTurn, let previous {
            stack.setCustomSpacing(Design.Chat.turnSpacing, after: previous)
        }

        scrollToBottom()
    }

    func setStatus(_ text: String) {
        statusLabel.stringValue = text
    }

    /// Draws the context meter from the retained reading: a percentage where the provider
    /// states the window, absolute tokens where it does not, and the warning role past 90% —
    /// full context is the one condition here worth ink before the user asks.
    func updateContextMeter() {
        guard let reading = lastContextReading else {
            contextLabel.isHidden = true
            return
        }
        contextLabel.stringValue = TurnStatusText.context(
            tokens: reading.tokens,
            window: reading.window
        )
        contextLabel.textColor = TurnStatusText.contextIsNearlyFull(
            tokens: reading.tokens,
            window: reading.window
        ) ? Design.Status.warning : Design.Text.tertiary
        contextLabel.isHidden = false
    }

    func scrollToBottom() {
        // Following is a mode, not a reflex: while the user reads elsewhere (`free`) or their
        // sent message holds the top (`anchored`), new content must not move the view.
        guard !isReplaying, autoScroll.followsNewContent else { return }

        // After layout, or the scroll targets the height the stack had before this message.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.autoScroll.followsNewContent,
                  let documentView = self.scrollView.documentView else { return }

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
    func presentPermission(
        _ request: PermissionRequest,
        decide: @escaping @MainActor @Sendable (PermissionDecision) -> Void
    ) {
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

        let card = PermissionRequestView(request: pending.request) { [weak self] decision in
            pending.decide(decision)
            guard let self else { return }
            self.activePermissionCard = nil
            self.delegate?.conversationDidChangeActivity(self)
            self.showNextPermissionIfIdle()
            RemoteSessionMirrorRegistry.shared.sessionConversationChanged(self.sessionID)
        }

        activePermissionCard = card
        RemoteNotificationService.shared.permissionRequested(
            sessionID: sessionID,
            toolName: pending.request.toolName,
            summary: pending.request.summary
        )
        let target = ExtensionComponentTarget.conversationPermissionCard(
            sessionID: agentSession.id.uuidString.lowercased()
        )
        addRow(
            customizeConversationRow(card, target: target),
            newTurn: true
        )
        RemoteSessionMirrorRegistry.shared.sessionConversationChanged(sessionID)
    }
}

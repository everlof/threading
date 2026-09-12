import AppKit
import ThreadingExtensionKit

// MARK: - Rendering

/// Applying timeline changes to the view tree, split from the controller that drives it. Same
/// type, separate file for length, so the private state these read stays private.
///
/// What a row *is* lives in `ConversationTimeline`, what one *looks like* in
/// `ConversationRowView`, and the placement every transcript shares — the cheap ordering, the
/// tool-run disclosures, the recycled row hosts — in `ConversationTranscriptTable`. What is left
/// here is the main conversation's own: turn folds, the changed-files and permission cards, the
/// streaming placeholder, and the wrappers a row wears in this pane.
extension ConversationViewController {

    // MARK: - Changes

    /// Brings the view tree in line with one change the timeline reported.
    func apply(_ change: ConversationTimeline.Change) {
        remoteRowProjection.apply(change, timelineRows: timeline.rows)
        switch change {
        case .appended(let index):
            let row = timeline.rows[index]
            let startsTurn: Bool
            if case .userMessage = row { startsTurn = true } else { startsTurn = false }

            // A turn that stayed expanded because it ended early folds the moment the next one
            // begins — the user has moved on, and t3code's rule is exactly this handoff.
            if startsTurn, let pending = pendingFold {
                pendingFold = nil
                foldTurn(startingAt: pending.startIndex, outcome: pending.outcome)
            }

            transcript.appendTimelineRow(at: index)

            // A live user row advances the rail by one; settlement later fills that mark's
            // answer and duration without rebuilding its historical prefix.
            if case .userMessage = row, !isReplaying {
                noteMinimapTurnStarted(at: index)
            }

        case .resultAttached(let index):
            guard case .toolCall(let call) = timeline.rows[index],
                  let result = call.result else { return }

            transcript.applyToolResult(at: index)
            // A chart row draws the chart, not a `ToolCallView`, so there is no pending view to
            // hand the result to. It only matters when the call failed: the row has to stop
            // showing a picture the panel refused and say what happened instead, which means
            // rebuilding it rather than updating it in place.
            if call.chart != nil, result.outcome == .failed {
                transcript.reload()
            }
            scrollToBottom()

        case .streaming(let text):
            guard let text else { return clearStreaming() }
            showStreaming(text)

        case .status(let status):
            presentedStatus = status
            let wasInFlight = isTurnInFlight
            isTurnInFlight = {
                if case .working = status { return true }
                return false
            }()
            if !isTurnInFlight { runProgress = nil }
            runPlanDisclosure.update(isTurnInFlight ? runProgress : nil)

            // The meter follows metrics, not the status: a Ready that carries none — the
            // post-replay reset, a model change — must not blank a reading that still holds.
            if case .ready(_, let lastTurn) = status,
               let tokens = lastTurn?.contextTokens {
                lastContextReading = (tokens, lastTurn?.contextWindow)
                updateContextMeter()
            }

            // The orb runs only while a turn is in flight; hidden, it detaches
            // from the status row and its display link idles.
            refreshDecisionStatus()
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

        case .turnSettled(let startIndex, let outcome):
            // A completed turn folds at once. One that ended early stays expanded so the user
            // keeps their place, and the *next* turn folds it — reading "Stopped after" or
            // "Failed after" rather than claiming to have worked.
            if outcome.isIncomplete {
                pendingFold = (startIndex, outcome)
            } else {
                foldTurn(startingAt: startIndex, outcome: .completed)
            }
            if !isReplaying { noteMinimapTurnSettled(at: startIndex) }
            appendChangedFilesCard(
                forTurnStartingAt: startIndex,
                checkpointID: settlingGitCheckpointID
            )

        case .adoptedSessionID(let agentSessionID):
            // The CLI's own identifier wins: a resume can settle on one other than the
            // identifier we asked for, and resuming again must use what it actually used.
            ProjectStore.shared.update(sessionID: sessionID) {
                $0.resumeState = .resumable(agentSessionID)
            }
        }
    }

    // MARK: - Turn Folding

    /// Collapses a settled turn's work — everything between its user message and its final
    /// assistant reply — behind a one-line `TurnFoldView`.
    ///
    /// The canonical rows stay in `timeline`; only their presentation entries leave the table.
    func foldTurn(startingAt startIndex: Int, outcome: TurnOutcome) {
        guard !foldedTurnStarts.contains(startIndex),
              let turn = timeline.turn(startingAt: startIndex),
              turn.endIndex > turn.rowIndex,
              let userPosition = transcript.index(of: .timeline(turn.rowIndex)) else { return }

        let turnIndices = turn.rowIndex + 1 ... turn.endIndex
        // A chart is not merely the record of work done on the way to the answer; it is part of
        // the answer. Folding the picture and keeping the sentence about it leaves a claim with
        // nothing behind it.
        let hiddenIndices = turnIndices.filter { index in
            guard index != turn.finalAssistantIndex else { return false }
            if case .toolCall(let call) = timeline.rows[index], call.chart != nil { return false }
            return true
        }
        guard !hiddenIndices.isEmpty else { return }

        foldedTurnStarts.insert(startIndex)

        // Only the entries after the turn's opening row are candidates, and a settling turn
        // sits at the tail, so this walks the turn rather than the transcript. Rebuilding the
        // whole ordering here made a 1,000-turn replay quadratic.
        let hiddenSet = Set(hiddenIndices)
        let items = transcript.items
        var removed = IndexSet()
        for position in (userPosition + 1)..<items.count {
            switch items[position].content {
            case .timeline, .markdown:
                if let index = items[position].content.timelineIndex,
                   hiddenSet.contains(index) {
                    removed.insert(position)
                }
            case .toolFold(let indices):
                if !hiddenSet.isDisjoint(with: indices) {
                    if let first = indices.first { transcript.expandedToolGroups.remove(first) }
                    removed.insert(position)
                }
            case .divider, .surface:
                break
            }
        }
        transcript.remove(at: removed)
        transcript.endToolRun()
        transcript.insert(
            [PresentationItem(
                id: .surface(.fold(turnStart: startIndex)),
                content: .surface(.fold(
                    turnStart: startIndex,
                    hiddenIndices: hiddenIndices,
                    duration: turn.duration,
                    outcome: outcome
                ))
            )],
            at: userPosition + 1
        )
    }

    /// Replay mutates only the presentation model. One reload at the end lets AppKit request the
    /// handful of rows that are actually visible instead of constructing every intermediate
    /// prefix while the transcript is being reduced.
    func finishReplayRendering() {
        transcript.reload(force: true)
    }

    private func setTurnWork(
        _ indices: [Int],
        expanded: Bool,
        turnStart: Int
    ) {
        let foldID = PresentationID.surface(.fold(turnStart: turnStart))
        guard transcript.index(of: foldID) != nil else { return }

        if expanded {
            expandedTurnStarts.insert(turnStart)
        } else {
            expandedTurnStarts.remove(turnStart)
        }
        transcript.setRows(indices, expanded: expanded, after: foldID)
    }

    // MARK: - Changed Files Card

    /// Leaves a summary of what a settled turn changed at the end of that turn.
    ///
    /// Live turns bind the card to the exact durable checkpoint handed through their completion
    /// boundary, so an older card still describes its own turn instead of going stale the moment
    /// the next one lands. A replayed transcript has no checkpoint to bind to: it reconstructs
    /// the same bounded card from the edit calls the provider recorded, and that historical card
    /// keeps its previews but offers no diff, because only Git Review can scope a turn whose
    /// baseline predates the relaunch.
    func appendChangedFilesCard(
        forTurnStartingAt startIndex: Int,
        checkpointID: GitTurnCheckpointID?
    ) {
        guard !changedFilesCardTurns.contains(startIndex) else { return }

        if isReplaying {
            let files = Self.recordedChangedFiles(
                from: timeline.fileChanges(inTurnStartingAt: startIndex)
            )
            guard !files.isEmpty else { return }

            changedFilesCardTurns.insert(startIndex)
            let tree = ChangedFilesTree.build(from: files.map {
                ChangedFilesTree.File(path: $0.path, added: $0.added, removed: $0.removed)
            })
            insertChangedFilesCard(
                tree,
                previews: ChangedFileDiffPreview.previews(from: files),
                checkpointID: nil,
                after: transcript.items.last?.id,
                offersViewDiff: false
            )
            return
        }

        guard let checkpointID,
              let checkpoint = GitTurnBaselineStore.shared.checkpoint(id: checkpointID),
              checkpoint.isComplete,
              let root = GitTurnBaselineStore.shared.repositoryRoot(for: checkpoint)
        else { return }

        changedFilesCardTurns.insert(startIndex)

        // The insert position is remembered as a stable presentation id, not an index: by the
        // time the diff returns, the user may already have sent the next message, and the card
        // belongs to the turn that earned it, not to the bottom of the conversation.
        let anchor = transcript.items.last?.id

        GitReviewReader.diff(.turnCheckpoint(checkpoint), in: root) { [weak self] result in
            guard let self, case .success(let files) = result, !files.isEmpty else { return }

            let tree = ChangedFilesTree.build(from: files.map {
                ChangedFilesTree.File(path: $0.path, added: $0.added, removed: $0.removed)
            })
            // The same read answers both questions the card asks: what changed, and — for the
            // row under the pointer — what the change *was*. Bounded per file, because the
            // card outlives the turn that made it.
            self.insertChangedFilesCard(
                tree,
                previews: ChangedFileDiffPreview.previews(from: files),
                checkpointID: checkpointID,
                after: anchor
            )
        }
    }

    private func insertChangedFilesCard(
        _ tree: ChangedFilesTree,
        previews: [String: ChangedFileDiffPreview],
        checkpointID: GitTurnCheckpointID?,
        after anchor: PresentationID?,
        offersViewDiff: Bool = true
    ) {
        let cardID = PresentationID.surface(.retained(UUID()))
        let card = ChangedFilesCardView(
            tree: tree,
            previews: previews,
            onViewDiff: { [weak self] in
                // A replayed card has no checkpoint and its button is hidden below, so the
                // absence is the same fact twice rather than a case to invent behaviour for.
                guard let self, let checkpointID else { return }
                self.delegate?.conversation(
                    self,
                    didRequestTurnDiff: checkpointID
                )
            },
            onHeightChange: { [weak self] in
                self?.transcript.noteHeightChanged(of: cardID)
            }
        )

        // Each card names its own checkpoint, so an older one still describes the turn it
        // belongs to and keeps its diff — that is what durable checkpoints bought. Only a
        // replayed card, which has no checkpoint to name, goes without.
        if !offersViewDiff || checkpointID == nil { card.hideViewDiff() }
        latestChangedFilesCard = card

        transcript.insert(
            [PresentationItem(id: cardID, content: .surface(.retained(card)))],
            after: anchor
        )
        scrollToBottom()
    }

    /// Coalesces repeated edits to one path while preserving their provider order. The result
    /// deliberately makes no claims about historical line numbers or file kind: an edit call
    /// records the changed lines, which is enough for an honest tree, counts and hover preview.
    private static func recordedChangedFiles(
        from changes: [EditDiff.FileChange]
    ) -> [GitFileDiff] {
        var paths: [String] = []
        var linesByPath: [String: [DiffLine]] = [:]

        for change in changes where !change.path.isEmpty && !change.lines.isEmpty {
            if linesByPath[change.path] == nil { paths.append(change.path) }
            linesByPath[change.path, default: []].append(contentsOf: change.lines)
        }

        return paths.compactMap { path in
            guard let lines = linesByPath[path], !lines.isEmpty else { return nil }
            let counts = EditDiff.counts(lines)
            return GitFileDiff(
                path: path,
                change: .modified,
                hunks: [GitHunk(header: "", lines: lines)],
                added: counts.added,
                removed: counts.removed
            )
        }
    }

    /// Conversation contracts are scoped to the session, not to message text or row indexes.
    /// Extensions may annotate a kind of row in a known session without receiving transcript
    /// content as an accidental data API.
    func componentTarget(
        for row: ConversationTimeline.Row
    ) -> ExtensionComponentTarget? {
        let sessionID = self.sessionID.uuidString.lowercased()
        switch row {
        case .userMessage:
            return .conversationUserMessage(sessionID: sessionID)
        case .assistant:
            return .conversationAssistantMessage(sessionID: sessionID)
        case .toolCall:
            return .conversationToolCall(sessionID: sessionID)
        case .thinking, .turnOutcome, .notice:
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

    /// The status tells the same truth as the inline card and sidebar. Waiting stops the orb
    /// and its clock callback without resetting the elapsed turn when an answer resumes it.
    func refreshDecisionStatus() {
        if hasPendingUserDecision {
            workingStatusTimer?.invalidate()
            workingStatusTimer = nil
            orbView.isHidden = true
            setStatus(hasPendingPermission ? L10n.string("Waiting for permission") : L10n.string("Waiting for your answer"))
        } else if case .working(let word) = presentedStatus {
            if orbView.isHidden { orbView.prepareForWorking(style: AppSettings.shared.workingOrbStyle) }
            orbView.isHidden = false
            beginWorkingStatus(word: word)
        } else {
            orbView.isHidden = true
            endWorkingStatus()
            setStatus(describe(presentedStatus))
        }
    }

    private func beginWorkingStatus(word: String) {
        workingStatusTimer?.invalidate()
        if workingStartedAt == nil { workingStartedAt = ProcessInfo.processInfo.systemUptime }

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
            transcript.append(PresentationItem(
                id: .surface(.streaming),
                content: .surface(.streaming(label))
            ))
            self.streamingLabel = label
            return
        }

        streamingLabel.stringValue = text
        transcript.noteHeightChanged(of: .surface(.streaming))
        scrollToBottom()
    }

    /// Drops the streaming placeholder, whose content the finished message repeats.
    func clearStreaming() {
        transcript.remove(.surface(.streaming))
        streamingLabel = nil
    }

    // MARK: - Layout

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
        guard !isReplaying else { return }

        // The sent-row anchor already owns the next main-queue landing. Scheduling a visibility
        // pass ahead of it adds a competing layout turn exactly when the virtual table is still
        // measuring the new row. Reply growth will drive `viewDidLayout`, which refreshes the
        // arrow without putting another task in front of the anchor.
        guard autoScroll.mode != .anchored, !pendingScrollToBottom else { return }

        // AppKit owns the position for the whole gesture, its momentum, and the elastic return.
        // Preserve the following mode and remember one catch-up, but do not replace the native
        // rubber-band offset with an exact-bottom write while the user's hand still owns it.
        if autoScroll.isUserScrolling {
            _ = autoScroll.claimFollowRequest()
            return
        }
        pendingScrollToBottom = true

        // After layout, or the scroll targets the table height from before this message. The
        // work still runs while not following so a growing reply can reveal the return arrow,
        // but the mode is checked at landing time so it never moves a reader who scrolled away.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingScrollToBottom = false

            if self.autoScroll.claimFollowRequest(),
               let documentView = self.scrollView.documentView {
                let overflow = documentView.bounds.height - self.scrollView.contentSize.height
                documentView.scroll(NSPoint(x: 0, y: max(0, overflow)))
            }
            self.updateScrollToEndControl()
        }
    }
}

// MARK: - Transcript Surface

/// What the main conversation adds to the shared transcript: its own folds, cards and streaming
/// placeholder, and the wrappers — extension host, speaker context, contextual actions — a row
/// wears only in this pane.
extension ConversationViewController: ConversationTranscriptSurface {

    var transcriptRows: [ConversationTimeline.Row] { timeline.rows }

    func transcriptView(for content: SurfaceItemContent, id: SurfaceItemID) -> NSView {
        switch content {
        case .fold(let turnStart, let hiddenIndices, let duration, let outcome):
            return TurnFoldView(
                duration: duration,
                outcome: outcome,
                folding: [],
                expanded: expandedTurnStarts.contains(turnStart)
            ) { [weak self] _, expanded in
                self?.setTurnWork(
                    hiddenIndices,
                    expanded: expanded,
                    turnStart: turnStart
                )
            }

        case .retained(let view):
            AppThemeRefresh.repaintIfNeeded(view)
            return view

        case .streaming(let label):
            return label
        }
    }

    func transcriptRhythm(for content: SurfaceItemContent, id: SurfaceItemID) -> Design.Chat.Rhythm {
        switch content {
        case .fold:
            return .work
        case .retained:
            // The handoff banner is the seam the conversation starts under; a card is chrome.
            if case .handoff = id { return .seam }
            return .chrome
        case .streaming:
            return .answer
        }
    }

    func transcriptRowView(
        _ view: NSView,
        decorating row: ConversationTimeline.Row,
        at index: Int
    ) -> NSView {
        let customizedView: NSView
        if let target = componentTarget(for: row) {
            customizedView = customizeConversationRow(view, target: target)
        } else {
            customizedView = view
        }
        let wrapped: NSView
        switch row {
        case .userMessage(let message):
            wrapped = ConversationMessageContextView(
                content: customizedView,
                speaker: .user,
                context: message.context
            )
        case .assistant:
            wrapped = ConversationMessageContextView(
                content: customizedView,
                speaker: .agent
            )
        case .thinking, .turnOutcome, .notice, .toolCall:
            wrapped = customizedView
        }
        configureContextActions(in: wrapped, row: row, rowIndex: index)
        return wrapped
    }
}

// MARK: - Permissions

/// Approval requests, split into an extension so the controller body stays within length.
/// Same file, so the private queue and card state stay private.
extension ConversationViewController {

    /// Queues a tool-approval request, showing it as a card once any earlier one is answered.
    /// While anything waits it drives the sidebar's attention dot through `activity`.
    func presentPermission(
        _ request: PermissionRequest,
        decide: @escaping @MainActor @Sendable (PermissionDecision) -> Void
    ) {
        // Force the view to load if the session has never been shown: touching `view` is the
        // 13-compatible `loadViewIfNeeded()`, and the card must exist to be resolved.
        _ = view

        permissionQueue.append((request, decide))
        refreshDecisionStatus()
        SessionSnoozeCenter.shared.record(.approvalRequested, for: sessionID)
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
        defer { refreshDecisionStatus() }
        guard activePermissionCard == nil, !permissionQueue.isEmpty else { return }

        let pending = permissionQueue.removeFirst()

        // Parallel tool calls can all reach this queue before the user chooses Allow for
        // Session on the first one. Re-evaluate when each request reaches the front so a stale
        // queued decision cannot raise a prompt the current policy already answers.
        if let decision = PermissionBroker.automaticDecision(for: pending.request) {
            pending.decide(decision)
            delegate?.conversationDidChangeActivity(self)
            showNextPermissionIfIdle()
            RemoteSessionMirrorRegistry.shared.sessionConversationChanged(sessionID)
            return
        }

        let cardID = PresentationID.surface(.retained(UUID()))

        let card = PermissionRequestView(request: pending.request) { [weak self] decision in
            pending.decide(decision)
            guard let self else { return }
            RemoteNotificationService.shared.permissionResolved(sessionID: self.sessionID)
            self.activePermissionCard = nil
            self.transcript.remove(cardID)
            self.delegate?.conversationDidChangeActivity(self)
            self.showNextPermissionIfIdle()
            self.refreshDecisionStatus()
            RemoteSessionMirrorRegistry.shared.sessionConversationChanged(self.sessionID)
        }

        activePermissionCard = card
        refreshDecisionStatus()
        RemoteNotificationService.shared.permissionRequested(
            sessionID: sessionID,
            toolName: pending.request.toolName,
            summary: pending.request.summary
        )
        let target = ExtensionComponentTarget.conversationPermissionCard(
            sessionID: sessionID.uuidString.lowercased()
        )
        transcript.append(PresentationItem(
            id: cardID,
            content: .surface(.retained(customizeConversationRow(card, target: target)))
        ))
        scrollToBottom()
        RemoteSessionMirrorRegistry.shared.sessionConversationChanged(sessionID)
    }
}

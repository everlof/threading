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

            // Not before the first turn: a rule at the very top of the pane separates the
            // conversation from nothing.
            if startsTurn, timeline.rows.count > 1 {
                appendPresentationItem(PresentationItem(
                    id: .divider(turnStart: index),
                    content: .divider,
                    opensTurn: true
                ))
            }

            if case .toolCall(let call) = row, call.chart == nil {
                appendToolPresentation(index)
            } else {
                activeToolGroupIndices.removeAll(keepingCapacity: true)
                appendPresentationItem(PresentationItem(
                    id: .timeline(index),
                    content: .timeline(index),
                    opensTurn: startsTurn && timeline.rows.count == 1
                ))
            }

            // A live user row advances the rail by one; settlement later fills that mark's
            // answer and duration without rebuilding its historical prefix.
            if case .userMessage = row, !isReplaying {
                noteMinimapTurnStarted(at: index)
            }

        case .resultAttached(let index):
            guard case .toolCall(let call) = timeline.rows[index],
                  let result = call.result else { return }

            pendingToolViews[index]?.setResult(result.text, outcome: result.outcome)
            // An interrupted row keeps its view reference: the real result can still arrive
            // after the turn ends, and it should land on the row rather than be lost.
            if result.outcome != .interrupted { pendingToolViews[index] = nil }
            noteTimelineRowHeightChanged(index)
            // A chart row draws the chart, not a `ToolCallView`, so there is no pending view to
            // hand the result to. It only matters when the call failed: the row has to stop
            // showing a picture the panel refused and say what happened instead, which means
            // rebuilding it rather than updating it in place.
            if case .toolCall(let failed) = timeline.rows[index],
               failed.chart != nil,
               result.outcome == .failed {
                reloadConversationRows()
            }
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
              let userPosition = presentationItems.lastIndex(where: {
                  $0.id == .timeline(turn.rowIndex)
              }) else { return }

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

        let hiddenSet = Set(hiddenIndices)
        let removalPositions = presentationItems.indices
            .dropFirst(userPosition + 1)
            .filter { position in
                switch presentationItems[position].content {
                case .timeline(let index):
                    return hiddenSet.contains(index)
                case .toolFold(let indices):
                    return !hiddenSet.isDisjoint(with: indices)
                case .divider, .fold, .retained, .streaming:
                    return false
                }
            }
        for position in removalPositions.reversed() {
            if case .toolFold(let indices) = presentationItems[position].content,
               let first = indices.first {
                expandedToolGroups.remove(first)
                rowHeightCache[.toolFold(firstIndex: first)] = nil
            }
            presentationItems.remove(at: position)
        }
        activeToolGroupIndices.removeAll(keepingCapacity: true)
        let insertion = min(userPosition + 1, presentationItems.count)
        presentationItems.insert(PresentationItem(
            id: .fold(turnStart: startIndex),
            content: .fold(
                turnStart: startIndex,
                hiddenIndices: hiddenIndices,
                duration: turn.duration,
                outcome: outcome
            ),
            opensTurn: false
        ), at: insertion)
        reloadConversationRows()
    }

    /// Replay mutates only the presentation model. One reload at the end lets AppKit request the
    /// handful of rows that are actually visible instead of constructing every intermediate
    /// prefix while the transcript is being reduced.
    func finishReplayRendering() {
        reloadConversationRows(force: true)
    }

    /// Creates one viewport instance. The timeline owns result data and the controller owns
    /// disclosure state, so recycling and later reconstruction produce the same row without
    /// retaining its constraint tree.
    private func materializeRow(at index: Int) -> NSView {
        let row = timeline.rows[index]
        let (nativeView, _) = ConversationRowView.make(for: row)
        configureDisclosureState(in: nativeView, rowIndex: index)
        let customizedView: NSView
        if let target = componentTarget(for: row) {
            customizedView = customizeConversationRow(nativeView, target: target)
        } else {
            customizedView = nativeView
        }
        let view: NSView
        switch row {
        case .userMessage(let message):
            view = ConversationMessageContextView(
                content: customizedView,
                speaker: .user,
                context: message.context
            )
        case .assistant:
            view = ConversationMessageContextView(
                content: customizedView,
                speaker: .agent
            )
        case .thinking, .turnOutcome, .notice, .toolCall:
            view = customizedView
        }
        configureContextActions(in: view, row: row, rowIndex: index)
        rowViews[index] = view

        // A missing or interrupted result may still arrive while this instance is visible.
        if case .toolCall(let call) = row,
           call.result == nil || call.result?.outcome == .interrupted {
            pendingToolViews[index] = nativeView as? ToolCallView
        }
        return view
    }

    private func setTurnWork(
        _ indices: [Int],
        expanded: Bool,
        turnStart: Int
    ) {
        guard let foldPosition = presentationItems.firstIndex(where: {
            $0.id == .fold(turnStart: turnStart)
        }) else { return }

        if expanded {
            expandedTurnStarts.insert(turnStart)
            let rows = indices.map {
                PresentationItem(
                    id: .timeline($0),
                    content: .timeline($0),
                    opensTurn: false
                )
            }
            presentationItems.insert(contentsOf: rows, at: foldPosition + 1)
        } else {
            expandedTurnStarts.remove(turnStart)
            let hiddenSet = Set(indices)
            presentationItems.removeAll { item in
                guard case .timeline(let index) = item.content else { return false }
                return hiddenSet.contains(index)
            }
        }
        rowHeightCache[.fold(turnStart: turnStart)] = nil
        reloadConversationRows()
    }

    /// Reduces a consecutive live tool run to one disclosure as it arrives. The canonical rows
    /// remain in `timeline`; only the viewport-sized presentation changes. A lone call stays
    /// visible, while the second turns the pair into a group and later calls extend it in O(1).
    private func appendToolPresentation(_ index: Int) {
        if activeToolGroupIndices.isEmpty {
            guard index > 0,
                  case .toolCall(let previousCall) = timeline.rows[index - 1],
                  previousCall.chart == nil,
                  presentationItems.last?.id == .timeline(index - 1)
            else {
                appendPresentationItem(PresentationItem(
                    id: .timeline(index),
                    content: .timeline(index),
                    opensTurn: false
                ))
                return
            }

            let indices = [index - 1, index]
            activeToolGroupIndices = indices
            let position = presentationItems.count - 1
            presentationItems[position] = PresentationItem(
                id: .toolFold(firstIndex: index - 1),
                content: .toolFold(indices: indices),
                opensTurn: false
            )
            presentationRowsByTimelineIndex[index - 1] = nil
            pendingToolViews[index - 1] = nil
            rowHeightCache[.timeline(index - 1)] = nil
            reloadPresentationRow(at: position)
            return
        }

        let previousCount = activeToolGroupIndices.count
        guard activeToolGroupIndices.last == index - 1,
              let first = activeToolGroupIndices.first else {
            activeToolGroupIndices.removeAll(keepingCapacity: true)
            appendPresentationItem(PresentationItem(
                id: .timeline(index),
                content: .timeline(index),
                opensTurn: false
            ))
            return
        }

        let foldPosition = expandedToolGroups.contains(first)
            ? presentationItems.count - previousCount - 1
            : presentationItems.count - 1
        guard presentationItems.indices.contains(foldPosition),
              presentationItems[foldPosition].id == .toolFold(firstIndex: first) else {
            activeToolGroupIndices.removeAll(keepingCapacity: true)
            appendPresentationItem(PresentationItem(
                id: .timeline(index),
                content: .timeline(index),
                opensTurn: false
            ))
            return
        }

        activeToolGroupIndices.append(index)
        presentationItems[foldPosition] = PresentationItem(
            id: .toolFold(firstIndex: first),
            content: .toolFold(indices: activeToolGroupIndices),
            opensTurn: false
        )
        reloadPresentationRow(at: foldPosition)

        if expandedToolGroups.contains(first) {
            appendPresentationItem(PresentationItem(
                id: .timeline(index),
                content: .timeline(index),
                opensTurn: false
            ))
        }
    }

    private func setToolGroup(_ indices: [Int], expanded: Bool) {
        guard let first = indices.first,
              let foldPosition = presentationItems.firstIndex(where: {
                  $0.id == .toolFold(firstIndex: first)
              }) else { return }

        if expanded {
            guard expandedToolGroups.insert(first).inserted else { return }
            presentationItems.insert(contentsOf: indices.map {
                PresentationItem(id: .timeline($0), content: .timeline($0), opensTurn: false)
            }, at: foldPosition + 1)
        } else {
            guard expandedToolGroups.remove(first) != nil else { return }
            let hidden = Set(indices)
            presentationItems.removeAll { item in
                guard case .timeline(let index) = item.content else { return false }
                return hidden.contains(index)
            }
        }
        rowHeightCache[.toolFold(firstIndex: first)] = nil
        reloadConversationRows()
    }

    /// Makes an exact tool target addressable without giving up compact groups by default.
    /// Keyboard navigation, minimap jumps and deep links all pass through the same reveal path.
    func revealToolGroup(containing timelineIndex: Int) {
        guard let item = presentationItems.first(where: {
                  guard case .toolFold(let indices) = $0.content else { return false }
                  return indices.contains(timelineIndex)
              }),
              case .toolFold(let indices) = item.content else { return }
        setToolGroup(indices, expanded: true)
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
                after: presentationItems.last?.id,
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
        let anchor = presentationItems.last?.id

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
        let cardID = PresentationID.retained(UUID())
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
                self?.notePresentationHeightChanged(cardID)
            }
        )

        // Each card names its own checkpoint, so an older one still describes the turn it
        // belongs to and keeps its diff — that is what durable checkpoints bought. Only a
        // replayed card, which has no checkpoint to name, goes without.
        if !offersViewDiff || checkpointID == nil { card.hideViewDiff() }
        latestChangedFilesCard = card

        let position = anchor
            .flatMap { anchor in presentationItems.firstIndex { $0.id == anchor } }
            .map { $0 + 1 }
            ?? presentationItems.count
        presentationItems.insert(PresentationItem(
            id: cardID,
            content: .retained(card),
            opensTurn: false
        ), at: position)
        reloadConversationRows()
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
        activeToolGroupIndices.removeAll(keepingCapacity: true)
        guard let streamingLabel else {
            let label = ConversationRowView.streaming(text)
            presentationItems.append(PresentationItem(
                id: .streaming,
                content: .streaming(label),
                opensTurn: false
            ))
            notifyPresentationRowsInserted(at: IndexSet(integer: presentationItems.count - 1))
            self.streamingLabel = label
            return
        }

        streamingLabel.stringValue = text
        rowHeightCache[.streaming] = nil
        notePresentationHeightChanged(.streaming)
        scrollToBottom()
    }

    /// Drops the streaming placeholder, whose content the finished message repeats.
    func clearStreaming() {
        if let position = presentationItems.firstIndex(where: { $0.id == .streaming }) {
            presentationItems.remove(at: position)
            rowHeightCache[.streaming] = nil
            notifyPresentationRowsRemoved(at: IndexSet(integer: position))
        }
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

// MARK: - Virtualized Transcript

extension ConversationViewController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int {
        presentationItems.count
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        false
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row tableRow: Int
    ) -> NSView? {
        guard presentationItems.indices.contains(tableRow) else { return nil }
        let item = presentationItems[tableRow]
        let identifier = NSUserInterfaceItemIdentifier("ConversationVirtualRow")
        let host = tableView.makeView(
            withIdentifier: identifier,
            owner: self
        ) as? ConversationVirtualRowHost ?? ConversationVirtualRowHost()
        host.identifier = identifier
        host.setColumnWidth(conversationColumnWidth)

        let content = makePresentationView(for: item)
        let topInset = presentationTopInset(at: tableRow)
        let bottomInset = tableRow == presentationItems.count - 1
            ? Design.Spacing.inset
            : 0

        host.install(
            content,
            topInset: topInset,
            bottomInset: bottomInset,
            onRelease: releaseHandler(for: item, content: content),
            onMeasuredHeight: { [weak self] height in
                guard let self,
                      self.presentationItems.indices.contains(tableRow),
                      self.presentationItems[tableRow].id == item.id,
                      height > 0 else { return }
                self.rowHeightCache[item.id] = height
            }
        )
        return host
    }

    func presentationRow(forTimelineIndex index: Int) -> Int? {
        if let row = presentationRowsByTimelineIndex[index],
           presentationItems.indices.contains(row),
           presentationItems[row].id == .timeline(index) {
            return row
        }
        return presentationItems.firstIndex { $0.id == .timeline(index) }
    }

    var conversationColumnWidth: CGFloat {
        ConversationVirtualRowHost.columnWidth(of: tableView)
    }

    func invalidateConversationHeightCacheIfNeeded() {
        let column = ConversationVirtualRowHost.stateColumnWidth(in: tableView)

        let width = min(
            Design.Size.readableWidth,
            max(0, column - Design.Spacing.inset * 2)
        )
        guard width > 0 else { return }
        if rowHeightCacheWidth == 0 {
            rowHeightCacheWidth = width
            return
        }
        guard abs(width - rowHeightCacheWidth) > 0.5 else { return }
        rowHeightCacheWidth = width
        let hadCachedHeights = !rowHeightCache.isEmpty
        rowHeightCache.removeAll(keepingCapacity: true)
        if hadCachedHeights, tableView.numberOfRows > 0 {
            tableView.noteHeightOfRows(
                withIndexesChanged: IndexSet(integersIn: 0..<tableView.numberOfRows)
            )
        }
    }

    func appendPresentationItem(_ item: PresentationItem) {
        let index = presentationItems.count
        presentationItems.append(item)
        if !isReplaying, case .timeline(let timelineIndex) = item.content {
            presentationRowsByTimelineIndex[timelineIndex] = index
        }
        notifyPresentationRowsInserted(at: IndexSet(integer: index))
    }

    private func reloadPresentationRow(at row: Int) {
        guard presentationItems.indices.contains(row) else { return }
        rowHeightCache[presentationItems[row].id] = nil
        guard isViewLoaded, !isReplaying, row < tableView.numberOfRows else { return }
        tableView.reloadData(
            forRowIndexes: IndexSet(integer: row),
            columnIndexes: IndexSet(integer: 0)
        )
        tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
    }

    func notifyPresentationRowsInserted(at indexes: IndexSet) {
        guard isViewLoaded, !isReplaying, !indexes.isEmpty else { return }
        tableView.insertRows(at: indexes, withAnimation: [])
    }

    func notifyPresentationRowsRemoved(at indexes: IndexSet) {
        guard isViewLoaded, !isReplaying, !indexes.isEmpty else { return }
        tableView.removeRows(at: indexes, withAnimation: [])
    }

    func reloadConversationRows(force: Bool = false) {
        guard isViewLoaded, force || !isReplaying else { return }
        rebuildPresentationRowIndex()
        rowViews.removeAll(keepingCapacity: true)
        pendingToolViews.removeAll(keepingCapacity: true)
        tableView.reloadData()
    }

    private func rebuildPresentationRowIndex() {
        presentationRowsByTimelineIndex.removeAll(keepingCapacity: true)
        presentationRowsByTimelineIndex.reserveCapacity(presentationItems.count)
        for (row, item) in presentationItems.enumerated() {
            if case .timeline(let timelineIndex) = item.content {
                presentationRowsByTimelineIndex[timelineIndex] = row
            }
        }
    }

    func noteTimelineRowHeightChanged(_ index: Int) {
        notePresentationHeightChanged(.timeline(index))
    }

    func notePresentationHeightChanged(_ id: PresentationID) {
        rowHeightCache[id] = nil
        // Replay has no materialized table row to invalidate and finishes with one full reload.
        // Searching the growing presentation for every replayed tool result made transcript
        // construction quadratic even though the virtualized AppKit working set stayed bounded.
        guard !isReplaying else { return }

        let row: Int?
        switch id {
        case .timeline(let index):
            row = presentationRow(forTimelineIndex: index)
        case .streaming where presentationItems.last?.id == .streaming:
            // The streaming placeholder is appended at the tail and remains there until the
            // authoritative completed message replaces it. Avoid walking the whole transcript
            // for every token-sized update in a long conversation.
            row = presentationItems.indices.last
        default:
            row = presentationItems.firstIndex(where: { $0.id == id })
        }

        guard let row,
              row < tableView.numberOfRows else { return }
        tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
    }

    private func makePresentationView(for item: PresentationItem) -> NSView {
        switch item.content {
        case .timeline(let index):
            return materializeRow(at: index)

        case .divider:
            return ConversationRowView.turnDivider()

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

        case .toolFold(let indices):
            let count = indices.count
            let label = count == 1
                ? L10n.string("1 tool call")
                : L10n.format("%lld tool calls", Int64(count))
            let first = indices[0]
            return TurnFoldView(
                label: label,
                folding: [],
                expanded: expandedToolGroups.contains(first)
            ) { [weak self] _, expanded in
                self?.setToolGroup(indices, expanded: expanded)
            }

        case .retained(let view):
            AppThemeRefresh.repaintIfNeeded(view)
            return view

        case .streaming(let label):
            return label
        }
    }

    private func presentationTopInset(at row: Int) -> CGFloat {
        guard row > 0 else { return Design.Spacing.inset }
        let item = presentationItems[row]
        if item.opensTurn { return Design.Chat.turnSpacing }

        let previous = presentationItems[row - 1]
        if isWorkPresentation(item) || isWorkPresentation(previous) {
            return Design.Spacing.tight
        }
        return Design.Spacing.small
    }

    private func isWorkPresentation(_ item: PresentationItem) -> Bool {
        switch item.content {
        case .toolFold:
            return true
        case .timeline(let index):
            switch timeline.rows[index] {
            case .toolCall, .thinking:
                return true
            case .userMessage, .assistant, .turnOutcome, .notice:
                return false
            }
        case .divider, .fold, .retained, .streaming:
            return false
        }
    }

    private func releaseHandler(
        for item: PresentationItem,
        content: NSView
    ) -> (() -> Void)? {
        guard case .timeline(let index) = item.content else { return nil }
        return { [weak self, weak content] in
            guard let self, let content else { return }
            if self.rowViews[index] === content {
                self.rowViews[index] = nil
            }
            if let tool = Self.firstDescendant(ToolCallView.self, in: content),
               self.pendingToolViews[index] === tool {
                self.pendingToolViews[index] = nil
            }
        }
    }

    private func configureDisclosureState(in view: NSView, rowIndex: Int) {
        if let tool = Self.firstDescendant(ToolCallView.self, in: view) {
            tool.onExpansionChanged = { [weak self] expanded in
                guard let self else { return }
                if expanded {
                    self.expandedToolRows.insert(rowIndex)
                } else {
                    self.expandedToolRows.remove(rowIndex)
                }
                self.noteTimelineRowHeightChanged(rowIndex)
            }
            tool.setExpanded(expandedToolRows.contains(rowIndex), notifying: false)
        }

        if let bubble = Self.firstDescendant(UserMessageBubbleView.self, in: view) {
            bubble.onExpansionChanged = { [weak self] expanded in
                guard let self else { return }
                if expanded {
                    self.expandedUserRows.insert(rowIndex)
                } else {
                    self.expandedUserRows.remove(rowIndex)
                }
                self.noteTimelineRowHeightChanged(rowIndex)
            }
            bubble.setExpanded(expandedUserRows.contains(rowIndex), notifying: false)
        }
    }

    private static func firstDescendant<T: NSView>(_ type: T.Type, in root: NSView) -> T? {
        if let match = root as? T { return match }
        for child in root.subviews {
            if let match = firstDescendant(type, in: child) { return match }
        }
        return nil
    }
}

/// Reusable shell around a conversation row. The host, not the content, is what AppKit recycles;
/// replacing its child releases offscreen Markdown and tool constraint trees while preserving a
/// stable measured height for the presentation identity.
final class ConversationVirtualRowHost: NSTableCellView {
    private var releaseContent: (() -> Void)?
    private var onMeasuredHeight: ((CGFloat) -> Void)?

    /// The width of the column this cell sits in, which has to be *stated* — see
    /// `setColumnWidth`. Held on the cell rather than the content so it survives recycling.
    private lazy var columnWidth: NSLayoutConstraint = {
        // Above the content's own compression resistance and below required: a row too narrow
        // for what is in it gives way in the words, never by growing past the pane. Required
        // would make the same choice by breaking someone else's required constraint and
        // logging it as a failure.
        let constraint = widthAnchor.constraint(equalToConstant: 0)
        constraint.priority = ConversationDefaults.columnWidthPriority
        return constraint
    }()

    /// States how wide the cell's column is, because AppKit does not.
    ///
    /// **A cell is not given its column's width.** Under `usesAutomaticRowHeights` the table
    /// solves the cell from the constraints inside it, and a width nothing determines settles on
    /// the smallest that satisfies them. So a row capped at the readable measure came out
    /// `readableWidth` plus its insets — 644pt — sitting at the column's leading edge, and the
    /// `centerXAnchor` below centred the content inside *that* rather than in the pane. The
    /// column the whole pane is designed around was therefore flush left in every window wider
    /// than 644, which is most of them: prose and bubbles hugged the sidebar with several
    /// hundred points of empty pane beside them, and the turn rail — placed for a column that
    /// is *centred* — landed on the first character of every paragraph.
    ///
    /// Stating the width is what makes `centerXAnchor` mean the pane's centre. It also closes
    /// the older fault the other way round: with the cell pinned to its column it can no longer
    /// grow past the clip in a pane narrower than the column.
    func setColumnWidth(_ width: CGFloat) {
        guard width > 0 else {
            columnWidth.isActive = false
            return
        }
        guard !columnWidth.isActive || abs(columnWidth.constant - width) > 0.5 else { return }
        columnWidth.constant = width
        columnWidth.isActive = true
    }

    /// The column a table's cells stand in — the table's own, not its pane's, because the table
    /// insets the column and a cell centred on the pane's width would sit off that centre by
    /// half the inset.
    static func columnWidth(of tableView: NSTableView) -> CGFloat {
        tableView.tableColumns.first?.width ?? tableView.bounds.width
    }

    /// Tells every cell currently on screen how wide its column is, and answers with it.
    ///
    /// Called from the host's `viewDidLayout`, because a cell AppKit does not rebuild would
    /// otherwise go on centring itself in a column that no longer exists — the pane can be
    /// dragged wider without a single row being recycled.
    @discardableResult
    static func stateColumnWidth(in tableView: NSTableView) -> CGFloat {
        let width = columnWidth(of: tableView)
        guard width > 0 else { return width }
        tableView.enumerateAvailableRowViews { rowView, _ in
            for cell in rowView.subviews {
                (cell as? ConversationVirtualRowHost)?.setColumnWidth(width)
            }
        }
        return width
    }

    func install(
        _ content: NSView,
        topInset: CGFloat,
        bottomInset: CGFloat,
        onRelease: (() -> Void)?,
        onMeasuredHeight: @escaping (CGFloat) -> Void
    ) {
        releaseInstalledContent()
        releaseContent = onRelease
        self.onMeasuredHeight = onMeasuredHeight

        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        let sideInset = Design.Spacing.inset

        // The pane's width leads and the readable column is a cap, never the other way round.
        //
        // A cell is not pinned to its column: under automatic row heights the table solves the
        // cell's own width from the constraints inside it, so a row that *asks* for the readable
        // measure gets it even where there is no room — the cell grows past the clip, taking the
        // words with it. Nothing announces that; the pane has no horizontal scroller, so the
        // sentences are simply cut mid-word at its edge. This shipped as a child transcript in
        // the display pane, which is routinely narrower than the column, rendering as clipped
        // paragraphs with an untouched gutter of pane behind them. Ordering the two the other
        // way had the same intent and only worked while the pane was wide enough to hide it.
        //
        // The cell's own width is stated by `setColumnWidth`; without it neither this nor the
        // centring below has a column to be a fraction of.
        let paneWidth = content.widthAnchor.constraint(
            equalTo: widthAnchor,
            constant: -sideInset * 2
        )
        paneWidth.priority = .defaultHigh

        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: topInset),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -bottomInset),
            content.centerXAnchor.constraint(equalTo: centerXAnchor),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: sideInset),
            content.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -sideInset),
            content.widthAnchor.constraint(lessThanOrEqualToConstant: Design.Size.readableWidth),
            paneWidth
        ])
    }

    override func layout() {
        super.layout()
        if bounds.height > 0 { onMeasuredHeight?(bounds.height) }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        releaseInstalledContent()
    }

    private func releaseInstalledContent() {
        releaseContent?()
        releaseContent = nil
        onMeasuredHeight = nil
        subviews.forEach { $0.removeFromSuperview() }
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

        let cardID = PresentationID.retained(UUID())

        let card = PermissionRequestView(request: pending.request) { [weak self] decision in
            pending.decide(decision)
            guard let self else { return }
            self.activePermissionCard = nil
            self.removePresentationItem(cardID)
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
            sessionID: sessionID.uuidString.lowercased()
        )
        activeToolGroupIndices.removeAll(keepingCapacity: true)
        appendPresentationItem(PresentationItem(
            id: cardID,
            content: .retained(customizeConversationRow(card, target: target)),
            opensTurn: false
        ))
        scrollToBottom()
        RemoteSessionMirrorRegistry.shared.sessionConversationChanged(sessionID)
    }

    private func removePresentationItem(_ id: PresentationID) {
        guard let position = presentationItems.firstIndex(where: { $0.id == id }) else { return }
        presentationItems.remove(at: position)
        rowHeightCache[id] = nil
        // A permission may have later timeline rows below it. Rebuild their index map once at
        // this user-driven boundary instead of leaving navigation pointed one row too low.
        reloadConversationRows()
    }
}

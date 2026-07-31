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
            if startsTurn, let pending = pendingFold {
                pendingFold = nil
                foldTurn(startingAt: pending.startIndex, stopped: pending.interrupted)
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

            appendPresentationItem(PresentationItem(
                id: .timeline(index),
                content: .timeline(index),
                opensTurn: startsTurn && timeline.rows.count == 1
            ))

            // The rail indexes user turns, so it only ever changes when one is added.
            if case .userMessage = row, !isReplaying { refreshMinimap() }

        case .resultAttached(let index):
            guard case .toolCall(let call) = timeline.rows[index],
                  let result = call.result else { return }

            pendingToolViews[index]?.setResult(result.text, outcome: result.outcome)
            // An interrupted row keeps its view reference: the real result can still arrive
            // after the turn ends, and it should land on the row rather than be lost.
            if result.outcome != .interrupted { pendingToolViews[index] = nil }
            noteTimelineRowHeightChanged(index)
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
    /// The canonical rows stay in `timeline`; only their presentation entries leave the table.
    /// Permission cards deliberately stay visible — a decided card is the record of what was
    /// allowed, which is worth more than the symmetry.
    func foldTurn(startingAt startIndex: Int, stopped: Bool) {
        guard !foldedTurnStarts.contains(startIndex),
              let turn = timeline.turn(startingAt: startIndex),
              turn.endIndex > turn.rowIndex,
              let userPosition = presentationItems.lastIndex(where: {
                  $0.id == .timeline(turn.rowIndex)
              }) else { return }

        let turnIndices = turn.rowIndex + 1 ... turn.endIndex
        let hiddenIndices = turnIndices.filter { $0 != turn.finalAssistantIndex }
        guard !hiddenIndices.isEmpty else { return }

        foldedTurnStarts.insert(startIndex)

        let hiddenSet = Set(hiddenIndices)
        let removalPositions = presentationItems.indices
            .dropFirst(userPosition + 1)
            .filter { position in
                guard case .timeline(let index) = presentationItems[position].content else {
                    return false
                }
                return hiddenSet.contains(index)
            }
        for position in removalPositions.reversed() {
            presentationItems.remove(at: position)
        }
        let insertion = min(userPosition + 1, presentationItems.count)
        presentationItems.insert(PresentationItem(
            id: .fold(turnStart: startIndex),
            content: .fold(
                turnStart: startIndex,
                hiddenIndices: hiddenIndices,
                duration: turn.duration,
                stopped: stopped
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
        let view: NSView
        if let target = componentTarget(for: row) {
            view = customizeConversationRow(nativeView, target: target)
        } else {
            view = nativeView
        }
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

        // The insert position is remembered as a stable presentation id, not an index: by the
        // time the diff returns, the user may already have sent the next message, and the card
        // belongs to the turn that earned it, not to the bottom of the conversation.
        let anchor = presentationItems.last?.id

        GitReviewReader.diff(.lastTurn(baseline), in: root) { [weak self] result in
            guard let self, case .success(let files) = result, !files.isEmpty else { return }

            let tree = ChangedFilesTree.build(from: files.map {
                ChangedFilesTree.File(path: $0.path, added: $0.added, removed: $0.removed)
            })
            self.insertChangedFilesCard(tree, after: anchor)
        }
    }

    private func insertChangedFilesCard(_ tree: ChangedFilesTree, after anchor: PresentationID?) {
        let card = ChangedFilesCardView(tree: tree) { [weak self] in
            guard let self else { return }
            self.delegate?.conversationDidRequestTurnDiff(self)
        }

        // Only the newest card's View diff still describes what the Last Turn scope shows.
        latestChangedFilesCard?.hideViewDiff()
        latestChangedFilesCard = card

        let position = anchor
            .flatMap { anchor in presentationItems.firstIndex { $0.id == anchor } }
            .map { $0 + 1 }
            ?? presentationItems.count
        presentationItems.insert(PresentationItem(
            id: .retained(UUID()),
            content: .retained(card),
            opensTurn: false
        ), at: position)
        reloadConversationRows()
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

    /// Adds one full-width row, insetting its content from the pane edges consistently.
    ///
    /// `newTurn` opens extra space above the row, used before a user bubble so each exchange
    /// reads as its own block rather than one unbroken column.
    func addRow(_ view: NSView, newTurn: Bool = false) {
        appendPresentationItem(PresentationItem(
            id: .retained(UUID()),
            content: .retained(view),
            opensTurn: newTurn
        ))
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

        // After layout, or the scroll targets the table height from before this message.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.autoScroll.followsNewContent,
                  let documentView = self.scrollView.documentView else { return }

            let overflow = documentView.bounds.height - self.scrollView.contentSize.height
            documentView.scroll(NSPoint(x: 0, y: max(0, overflow)))
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

        let content = makePresentationView(for: item)
        let topInset: CGFloat
        if tableRow == 0 {
            topInset = Design.Spacing.inset
        } else if item.opensTurn {
            topInset = Design.Chat.turnSpacing
        } else {
            topInset = Design.Spacing.medium
        }
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
                      self.presentationItems.contains(where: { $0.id == item.id }),
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

    func invalidateConversationHeightCacheIfNeeded() {
        let width = min(
            Design.Size.readableWidth,
            max(0, tableView.bounds.width - Design.Spacing.inset * 2)
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
        guard let row = presentationItems.firstIndex(where: { $0.id == id }),
              row < tableView.numberOfRows else { return }
        tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
    }

    private func makePresentationView(for item: PresentationItem) -> NSView {
        switch item.content {
        case .timeline(let index):
            return materializeRow(at: index)

        case .divider:
            return ConversationRowView.turnDivider()

        case .fold(let turnStart, let hiddenIndices, let duration, let stopped):
            return TurnFoldView(
                duration: duration,
                stopped: stopped,
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
private final class ConversationVirtualRowHost: NSTableCellView {
    private var releaseContent: (() -> Void)?
    private var onMeasuredHeight: ((CGFloat) -> Void)?

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
        let readableWidth = content.widthAnchor.constraint(
            equalToConstant: Design.Size.readableWidth
        )
        readableWidth.priority = .defaultHigh
        let paneWidth = content.widthAnchor.constraint(
            equalTo: widthAnchor,
            constant: -sideInset * 2
        )
        paneWidth.priority = NSLayoutConstraint.Priority(rawValue: 749)

        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: topInset),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -bottomInset),
            content.centerXAnchor.constraint(equalTo: centerXAnchor),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: sideInset),
            content.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -sideInset),
            content.widthAnchor.constraint(lessThanOrEqualToConstant: Design.Size.readableWidth),
            readableWidth,
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

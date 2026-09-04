import AppKit

/// A session's child-agent navigator and the selected child rendered as a normal conversation.
///
/// The main conversation only carries a compact count in its corner status card. Navigation
/// belongs here in the display pane, above rows built through `ConversationRowView`, so user
/// messages, markdown, thinking, tool calls, results, and notices keep the parent's treatment.
/// The rows sit in the same `ConversationTranscriptTable` as the parent's, so folding, spacing
/// and recycling are one mechanism; this controller adds the navigator, the heading naming the
/// child whose rows follow, and the block-level Markdown split a narrow pane wants.
final class SubagentTranscriptViewController: NSViewController {

#if DEBUG
    struct RenderPhaseDurations {
        var summaryNanoseconds: UInt64 = 0
        /// Building the ordering and reloading the table, which the shared table does as one
        /// step so live and rebuilt rows take the same shape.
        var transcriptNanoseconds: UInt64 = 0
        var summaryRebuilds = 0
    }
#endif

    /// The items only this pane presents beside the shared timeline, divider and tool-fold
    /// identities: the navigator, the heading, and the notice standing in for a transcript that
    /// is not there.
    enum SurfaceItem: Hashable {
        case summary
        case transcriptHeading
        case missingTranscript
    }

    // MARK: - Properties

    private let summaryView = SubagentSummaryView()
    private let transcriptHeadingView = SubagentTranscriptHeadingView()
    let transcript = ConversationTranscriptTable<SubagentTranscriptViewController>()

    private var agents: [SubagentTimeline.Agent] = []
    private var workingCount = 0
    private var doneCount = 0
    private var agent: SubagentTimeline.Agent?
    private var hasRendered = false
    private let appEvents = AppEventObservations()
    private let sessionID: SessionID?
    private var usageSnapshot: SessionUsageSnapshot?

    private(set) var representedThreadID: String?
    private(set) var renderedRowCount = 0
    var renderedPresentationCount: Int { transcript.items.count }
    var materializedPresentationCount: Int { transcript.materializedItemIDs.count }
    var cachedMarkdownBlockCount: Int { transcript.cachedMarkdownBlockCount }
#if DEBUG
    private(set) var lastRenderPhaseDurations = RenderPhaseDurations()
    var rowMaterializationDurations: ConversationTranscriptMaterializationDurations {
        transcript.rowMaterializationDurations
    }
#endif
    var transcriptScrollView: ThemedScrollView { transcript.scrollView }
    var transcriptTableView: ThemedTableView { transcript.tableView }
    var onSelectAgent: ((String) -> Void)?

    init(sessionID: SessionID? = nil) {
        self.sessionID = sessionID
        super.init(nibName: nil, bundle: nil)
        transcript.surface = self
        // A child's answer is read in the display pane, which is routinely narrower than the
        // conversation column; block rows keep a large report from attaching all at once.
        transcript.splitsAssistantMarkdown = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.setAccessibilityRole(.group)
        view.setAccessibilityLabel(L10n.string("Subagent transcript"))
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        summaryView.selectionStyle = .navigation
        summaryView.onSelect = { [weak self] threadID in
            guard let self, let threadID else { return }
            self.select(threadID, notify: true)
        }
        appEvents.observe(AppThemeDidChange.self) { [weak self] _ in
            guard let self, let agent = self.agent else { return }
            self.transcript.invalidateStyleCaches()
            self.render(agent, shouldFollow: false)
        }
        appEvents.observe(SessionUsageDidChange.self) { [weak self] event in
            guard let self, event.sessionID == self.sessionID else { return }
            self.applyUsage(SessionUsageService.shared.snapshot(for: event.sessionID))
        }
        if let sessionID {
            SessionUsageService.shared.refresh(sessionID)
            applyUsage(SessionUsageService.shared.snapshot(for: sessionID))
        }

        let scrollView = transcript.scrollView
        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        transcript.activate()

        if let agent {
            render(agent, shouldFollow: true)
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Rows here are the conversation's own, and are centred on a column they have to be
        // told the width of — see `ConversationVirtualRowHost.setColumnWidth`.
        transcript.layoutColumn()
    }

    // MARK: - Content

    func update(_ agent: SubagentTimeline.Agent) {
        update(
            agents: [agent],
            workingCount: agent.status.isWorking ? 1 : 0,
            doneCount: agent.status.isDone ? 1 : 0,
            selectedThreadID: agent.descriptor.threadID
        )
    }

    func update(
        _ timeline: SubagentTimeline,
        selectedThreadID: String?
    ) {
        update(
            agents: timeline.agents,
            workingCount: timeline.workingCount,
            doneCount: timeline.doneCount,
            selectedThreadID: selectedThreadID
        )
    }

    private func update(
        agents: [SubagentTimeline.Agent],
        workingCount: Int,
        doneCount: Int,
        selectedThreadID: String?
    ) {
        self.agents = agents
        self.workingCount = workingCount
        self.doneCount = doneCount

        let selected = selectedThreadID.flatMap { id in
            agents.first { $0.descriptor.threadID == id }
        } ?? representedThreadID.flatMap { id in
            agents.first { $0.descriptor.threadID == id }
        } ?? agents.last(where: \.status.isWorking)
            ?? agents.last

        let changedSelection = representedThreadID != selected?.descriptor.threadID
        if changedSelection {
            transcript.forgetDisclosures()
        }
        agent = selected
        representedThreadID = selected?.descriptor.threadID
        renderedRowCount = selected?.conversation.rows.count ?? 0
        guard isViewLoaded else { return }
        guard let selected else {
            clear()
            return
        }
        render(selected, shouldFollow: !hasRendered || isNearBottom)
    }

    private func render(_ agent: SubagentTimeline.Agent, shouldFollow: Bool) {
        let performanceSpan = PerformanceRecorder.shared.begin(
            "subagent.transcript.render",
            category: "conversation",
            metadata: [
                "agents": "\(agents.count)",
                "rows": "\(agent.conversation.rows.count)"
            ]
        )
        defer {
            performanceSpan.end(metadata: [
                "presented": "\(transcript.items.count)"
            ])
        }

#if DEBUG
        let summaryStarted = DispatchTime.now().uptimeNanoseconds
        let summaryRebuildsBefore = summaryView.rowRebuildCount
#endif
        let summarySpan = PerformanceRecorder.shared.begin(
            "subagent.transcript.render-summary",
            category: "conversation"
        )
        summaryView.update(
            items: agents.map(summaryItem),
            workingCount: workingCount,
            doneCount: doneCount,
            selectedID: agent.descriptor.threadID,
            usageText: usageSnapshot.flatMap {
                $0.subagents.processedTokens > 0
                    ? SessionUsageFormat.tokenCount($0.subagents.processedTokens)
                    : nil
            }
        )
        summarySpan.end(metadata: ["agents": "\(agents.count)"])
        transcriptHeadingView.update(
            title: agent.descriptor.displayName,
            state: summaryState(agent.status)
        )
#if DEBUG
        let summaryEnded = DispatchTime.now().uptimeNanoseconds
#endif

        let transcriptSpan = PerformanceRecorder.shared.begin(
            "subagent.transcript.build-presentation",
            category: "conversation"
        )
        rebuildPresentation(for: agent)
        transcriptSpan.end(metadata: [
            "rows": "\(agent.conversation.rows.count)",
            "presented": "\(transcript.items.count)"
        ])
#if DEBUG
        let transcriptEnded = DispatchTime.now().uptimeNanoseconds
        lastRenderPhaseDurations = RenderPhaseDurations(
            summaryNanoseconds: summaryEnded &- summaryStarted,
            transcriptNanoseconds: transcriptEnded &- summaryEnded,
            summaryRebuilds: summaryView.rowRebuildCount - summaryRebuildsBefore
        )
#endif

        hasRendered = true
        if shouldFollow { scrollToBottom() }
    }

    private func rebuildPresentation(for agent: SubagentTimeline.Agent) {
        // The heading is the seam between the navigator and the rows: it names the child the
        // rows belong to, which a selected row a screen higher cannot do on its own.
        let prefix = [
            Item(id: .surface(.summary), content: .surface(.summary)),
            Item(id: .surface(.transcriptHeading), content: .surface(.transcriptHeading))
        ]
        if agent.conversation.rows.isEmpty {
            // "Not arrived yet" is only true while there is still something to arrive. A child
            // that has finished without leaving a transcript never will, and saying otherwise
            // leaves the pane waiting on a file the provider is not going to write.
            transcript.replaceItems(prefix + [
                Item(id: .surface(.missingTranscript), content: .surface(.missingTranscript))
            ])
            return
        }
        transcript.rebuild(prefix: prefix)
    }

    private func select(_ threadID: String, notify: Bool) {
        guard let selected = agents.first(where: {
            $0.descriptor.threadID == threadID
        }) else { return }
        let changed = representedThreadID != threadID
        agent = selected
        representedThreadID = threadID
        renderedRowCount = selected.conversation.rows.count
        if isViewLoaded, changed {
            render(selected, shouldFollow: true)
        }
        if notify { onSelectAgent?(threadID) }
    }

    private func clear() {
        transcript.forgetDisclosures()
        transcript.replaceItems([])
        hasRendered = false
    }

    private var isNearBottom: Bool {
        guard isViewLoaded else { return true }
        let tableView = transcript.tableView
        let scrollView = transcript.scrollView
        let overflow = tableView.bounds.height - scrollView.contentSize.height
        return overflow <= 0 || scrollView.contentView.bounds.origin.y >= overflow - 40
    }

    private func scrollToBottom() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.view.layoutSubtreeIfNeeded()
            let tableView = self.transcript.tableView
            let overflow = tableView.bounds.height - self.transcript.scrollView.contentSize.height
            tableView.scroll(NSPoint(x: 0, y: max(0, overflow)))
        }
    }

    private func summaryState(_ status: SubagentStatus) -> SubagentSummaryItem.State {
        switch status {
        case .pending: return .pending
        case .working: return .working
        case .completed: return .completed
        case .interrupted: return .interrupted
        case .failed: return .failed
        case .stopped: return .stopped
        }
    }

    /// What opening this child would reach.
    ///
    /// Three ways it can: rows already replayed or streamed, a provider transcript on disk, or a
    /// child still running — which is the one case where "has not arrived yet" is the truth
    /// rather than a permanent state. A finished child with none of the three has nothing behind
    /// it, and the navigator must not offer a way in.
    private func transcriptAvailability(
        for agent: SubagentTimeline.Agent
    ) -> SubagentSummaryItem.TranscriptAvailability {
        if let url = SubagentTranscriptLoader.transcriptURL(for: agent.descriptor) {
            return .onDisk(url)
        }
        if !agent.conversation.rows.isEmpty || agent.status.isWorking {
            return .openable
        }
        return .unavailable
    }

    private func summaryItem(_ agent: SubagentTimeline.Agent) -> SubagentSummaryItem {
        let detailLines = agent.activity.isEmpty
            ? agent.message.map { [$0] } ?? []
            : agent.activity
        let usage = usageSnapshot?.children[agent.descriptor.threadID]
        return SubagentSummaryItem(
            id: agent.descriptor.threadID,
            title: agent.descriptor.displayName,
            subtitle: agent.descriptor.promptDetail,
            role: agent.descriptor.roleLabel,
            configurationDetail: configurationDetail(for: agent.descriptor),
            state: summaryState(agent.status),
            statusDetail: agent.statusDetail,
            usageDetail: usage.flatMap {
                SessionUsageFormat.childDetail(
                    $0,
                    liveTokenAlreadyShown: agent.progress?.totalTokens != nil
                )
            },
            detailLines: Array(detailLines.suffix(SubagentDefaults.activityLimit)),
            transcriptAvailability: transcriptAvailability(for: agent)
        )
    }

    private func configurationDetail(for descriptor: SubagentDescriptor) -> String? {
        var parts: [String] = []
        if let model = descriptor.model?.trimmingCharacters(in: .whitespacesAndNewlines),
           !model.isEmpty {
            parts.append(model)
        }
        if let effort = descriptor.reasoningEffort?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !effort.isEmpty {
            parts.append(L10n.format("Reasoning: %@", effort))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func applyUsage(_ snapshot: SessionUsageSnapshot?) {
        guard snapshot != usageSnapshot else { return }
        usageSnapshot = snapshot
        guard isViewLoaded, let agent else { return }
        render(agent, shouldFollow: false)
    }
}

// MARK: - Transcript Surface

extension SubagentTranscriptViewController: ConversationTranscriptSurface {
    typealias SurfaceItemID = SurfaceItem
    typealias SurfaceItemContent = SurfaceItem
    typealias Item = ConversationTranscriptTable<SubagentTranscriptViewController>.Item

    var transcriptRows: [ConversationTimeline.Row] {
        agent?.conversation.rows ?? []
    }

    func transcriptView(for content: SurfaceItem, id: SurfaceItem) -> NSView {
        switch content {
        case .summary:
            return summaryView
        case .transcriptHeading:
            return transcriptHeadingView
        case .missingTranscript:
            let stillArriving = agent.map { transcriptAvailability(for: $0).isOpenable } ?? false
            return ConversationRowView.notice(
                stillArriving
                    ? L10n.string("The structured child transcript has not arrived yet.")
                    : L10n.string("No transcript was recorded for this child."),
                kind: .muted
            )
        }
    }

    func transcriptRhythm(for content: SurfaceItem, id: SurfaceItem) -> Design.Chat.Rhythm {
        switch content {
        case .summary, .missingTranscript:
            return .chrome
        case .transcriptHeading:
            // The seam between the navigator and the rows: the transcript opens under it.
            return .seam
        }
    }
}

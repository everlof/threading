import AppKit

/// A session's child-agent navigator and the selected child rendered as a normal conversation.
///
/// The main conversation only carries a compact count in its corner status card. Navigation
/// belongs here in the display pane, above rows built through `ConversationRowView`, so user
/// messages, markdown, thinking, tool calls, results, and notices keep the parent's treatment.
final class SubagentTranscriptViewController: NSViewController {

    // MARK: - Properties

    private let summaryView = SubagentSummaryView()
    private lazy var tableView: ThemedTableView = {
        let table = ThemedTableView()
        let column = NSTableColumn(
            identifier: NSUserInterfaceItemIdentifier("SubagentTranscriptContent")
        )
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.selectionHighlightStyle = .none
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.intercellSpacing = .zero
        table.rowHeight = ConversationDefaults.estimatedRowHeight
        table.usesAutomaticRowHeights = true
        table.autoresizingMask = [.width]
        table.delegate = self
        table.dataSource = self
        return table
    }()
    private lazy var scrollView: ThemedScrollView = {
        let clip = FlippedClipView()
        clip.drawsBackground = false
        let scroll = ThemedScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.contentView = clip
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = tableView
        return scroll
    }()

    private enum PresentationID: Hashable {
        case summary
        case timeline(Int)
        case markdown(row: Int, block: Int)
        case divider(Int)
        case toolFold(Int)
    }

    private struct PresentationItem {
        enum Content {
            case summary
            case timeline(Int)
            case markdown(MarkdownBlock)
            case divider
            case toolFold(indices: [Int])
        }

        let id: PresentationID
        let content: Content
    }

    private var agents: [SubagentTimeline.Agent] = []
    private var workingCount = 0
    private var doneCount = 0
    private var agent: SubagentTimeline.Agent?
    private var presentationItems: [PresentationItem] = []
    private var materializedPresentationIDs: Set<PresentationID> = []
    private var expandedToolGroups: Set<Int> = []
    private var expandedToolRows: Set<Int> = []
    private var expandedUserRows: Set<Int> = []
    private var isSynchronizingSelection = false
    private var hasRendered = false
    private let appEvents = AppEventObservations()

    private(set) var representedThreadID: String?
    private(set) var renderedRowCount = 0
    var renderedPresentationCount: Int { presentationItems.count }
    var materializedPresentationCount: Int { materializedPresentationIDs.count }
    var transcriptScrollView: ThemedScrollView { scrollView }
    var transcriptTableView: ThemedTableView { tableView }
    var onSelectAgent: ((String) -> Void)?

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
            guard let self, !self.isSynchronizingSelection, let threadID else { return }
            self.select(threadID, notify: true)
        }
        appEvents.observe(AppThemeDidChange.self) { [weak self] _ in
            guard let self, let agent = self.agent else { return }
            self.render(agent, shouldFollow: false)
        }

        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        if let agent {
            render(agent, shouldFollow: true)
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Rows here are the conversation's own, and are centred on a column they have to be
        // told the width of — see `ConversationVirtualRowHost.setColumnWidth`.
        ConversationVirtualRowHost.stateColumnWidth(in: tableView)
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
            expandedToolGroups.removeAll(keepingCapacity: true)
            expandedToolRows.removeAll(keepingCapacity: true)
            expandedUserRows.removeAll(keepingCapacity: true)
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
                "presented": "\(presentationItems.count)"
            ])
        }
        summaryView.update(
            items: agents.map(summaryItem),
            workingCount: workingCount,
            doneCount: doneCount
        )
        isSynchronizingSelection = true
        summaryView.setSelection(agent.descriptor.threadID)
        isSynchronizingSelection = false
        rebuildPresentation(for: agent)
        materializedPresentationIDs.removeAll(keepingCapacity: true)
        tableView.reloadData()

        hasRendered = true
        if shouldFollow { scrollToBottom() }
    }

    private func rebuildPresentation(for agent: SubagentTimeline.Agent) {
        presentationItems = [PresentationItem(id: .summary, content: .summary)]
        if agent.conversation.rows.isEmpty {
            // "Not arrived yet" is only true while there is still something to arrive. A child
            // that has finished without leaving a transcript never will, and saying otherwise
            // leaves the pane waiting on a file the provider is not going to write.
            presentationItems.append(PresentationItem(
                id: .timeline(0),
                content: .timeline(0)
            ))
            return
        }

        var pendingToolIndices: [Int] = []
        var hasTranscriptRow = false

        func appendRow(_ row: ConversationTimeline.Row, at index: Int) {
            guard case .assistant(let markdown) = row else {
                presentationItems.append(PresentationItem(
                    id: .timeline(index),
                    content: .timeline(index)
                ))
                return
            }

            let blocks = Markdown.parse(markdown, style: .assistant)
            if blocks.isEmpty {
                presentationItems.append(PresentationItem(
                    id: .timeline(index),
                    content: .timeline(index)
                ))
            } else {
                presentationItems.append(contentsOf: blocks.enumerated().map { blockIndex, block in
                    PresentationItem(
                        id: .markdown(row: index, block: blockIndex),
                        content: .markdown(block)
                    )
                })
            }
        }

        func flushTools() {
            guard let first = pendingToolIndices.first else { return }
            presentationItems.append(PresentationItem(
                id: .toolFold(first),
                content: .toolFold(indices: pendingToolIndices)
            ))
            if expandedToolGroups.contains(first) {
                presentationItems.append(contentsOf: pendingToolIndices.map {
                    PresentationItem(id: .timeline($0), content: .timeline($0))
                })
            }
            pendingToolIndices.removeAll(keepingCapacity: true)
            hasTranscriptRow = true
        }

        for (index, row) in agent.conversation.rows.enumerated() {
            if case .toolCall = row {
                pendingToolIndices.append(index)
                continue
            }
            flushTools()
            if case .userMessage = row, hasTranscriptRow {
                presentationItems.append(PresentationItem(
                    id: .divider(index),
                    content: .divider
                ))
            }
            appendRow(row, at: index)
            hasTranscriptRow = true
        }
        flushTools()
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
        presentationItems.removeAll(keepingCapacity: true)
        materializedPresentationIDs.removeAll(keepingCapacity: true)
        tableView.reloadData()
        hasRendered = false
    }

    private var isNearBottom: Bool {
        guard isViewLoaded else { return true }
        let overflow = tableView.bounds.height - scrollView.contentSize.height
        return overflow <= 0 || scrollView.contentView.bounds.origin.y >= overflow - 40
    }

    private func scrollToBottom() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.view.layoutSubtreeIfNeeded()
            let overflow = self.tableView.bounds.height - self.scrollView.contentSize.height
            self.tableView.scroll(NSPoint(x: 0, y: max(0, overflow)))
        }
    }

    private func rowView(at index: Int) -> NSView {
        guard let agent, agent.conversation.rows.indices.contains(index) else {
            return ConversationRowView.notice(
                agent.map(canOpenTranscript) ?? false
                    ? L10n.string("The structured child transcript has not arrived yet.")
                    : L10n.string("No transcript was recorded for this child."),
                kind: .muted
            )
        }
        let view = ConversationRowView.make(for: agent.conversation.rows[index]).view
        configureDisclosureState(in: view, rowIndex: index)
        return view
    }

    private func toolFold(indices: [Int]) -> TurnFoldView {
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
    }

    private func setToolGroup(_ indices: [Int], expanded: Bool) {
        guard let first = indices.first,
              let foldRow = presentationItems.firstIndex(where: { $0.id == .toolFold(first) })
        else { return }

        if expanded {
            guard expandedToolGroups.insert(first).inserted else { return }
            let items = indices.map {
                PresentationItem(id: .timeline($0), content: .timeline($0))
            }
            presentationItems.insert(contentsOf: items, at: foldRow + 1)
            tableView.insertRows(
                at: IndexSet(integersIn: foldRow + 1...foldRow + items.count),
                withAnimation: []
            )
        } else {
            guard expandedToolGroups.remove(first) != nil else { return }
            let ids = Set(indices.map(PresentationID.timeline))
            let rows = IndexSet(presentationItems.indices.filter { ids.contains(presentationItems[$0].id) })
            for row in rows.reversed() { presentationItems.remove(at: row) }
            tableView.removeRows(at: rows, withAnimation: [])
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
                self.noteHeightChanged(rowIndex)
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
                self.noteHeightChanged(rowIndex)
            }
            bubble.setExpanded(expandedUserRows.contains(rowIndex), notifying: false)
        }
    }

    private func noteHeightChanged(_ timelineIndex: Int) {
        guard let row = presentationItems.firstIndex(where: { $0.id == .timeline(timelineIndex) })
        else { return }
        tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
    }

    private static func firstDescendant<T: NSView>(_ type: T.Type, in root: NSView) -> T? {
        if let match = root as? T { return match }
        for child in root.subviews {
            if let match = firstDescendant(type, in: child) { return match }
        }
        return nil
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

    /// Whether opening this child would reach a transcript.
    ///
    /// Three ways it can: rows already replayed or streamed, a provider transcript on disk, or a
    /// child still running — which is the one case where "has not arrived yet" is the truth
    /// rather than a permanent state. A finished child with none of the three has nothing behind
    /// it, and the navigator must not offer a way in.
    private func canOpenTranscript(_ agent: SubagentTimeline.Agent) -> Bool {
        !agent.conversation.rows.isEmpty
            || SubagentTranscriptLoader.transcriptURL(for: agent.descriptor) != nil
            || agent.status.isWorking
    }

    private func summaryItem(_ agent: SubagentTimeline.Agent) -> SubagentSummaryItem {
        let detailLines = agent.activity.isEmpty
            ? agent.message.map { [$0] } ?? []
            : agent.activity
        return SubagentSummaryItem(
            id: agent.descriptor.threadID,
            title: agent.descriptor.displayName,
            subtitle: agent.descriptor.prompt,
            state: summaryState(agent.status),
            statusDetail: agent.statusDetail,
            detailLines: Array(detailLines.suffix(SubagentDefaults.activityLimit)),
            transcriptURL: SubagentTranscriptLoader.transcriptURL(for: agent.descriptor),
            canOpenTranscript: canOpenTranscript(agent)
        )
    }
}

extension SubagentTranscriptViewController: NSTableViewDataSource, NSTableViewDelegate {
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
        let identifier = NSUserInterfaceItemIdentifier("SubagentTranscriptVirtualRow")
        let host = tableView.makeView(
            withIdentifier: identifier,
            owner: self
        ) as? ConversationVirtualRowHost ?? ConversationVirtualRowHost()
        host.identifier = identifier
        host.setColumnWidth(ConversationVirtualRowHost.columnWidth(of: tableView))

        let content: NSView
        switch item.content {
        case .summary:
            content = summaryView
        case .timeline(let index):
            content = rowView(at: index)
        case .markdown(let block):
            content = MarkdownView.blockView(for: block, style: .assistant)
        case .divider:
            content = ConversationRowView.turnDivider()
        case .toolFold(let indices):
            content = toolFold(indices: indices)
        }

        materializedPresentationIDs.insert(item.id)
        let bottomInset = tableRow == presentationItems.count - 1
            ? Design.Spacing.inset
            : 0
        host.install(
            content,
            topInset: topInset(for: item, at: tableRow),
            bottomInset: bottomInset,
            onRelease: { [weak self] in
                self?.materializedPresentationIDs.remove(item.id)
            },
            onMeasuredHeight: { _ in }
        )
        return host
    }

    private func topInset(for item: PresentationItem, at row: Int) -> CGFloat {
        if row == 0 { return Design.Spacing.inset }
        if case .markdown(let timelineRow, let block) = item.id, block > 0,
           presentationItems.indices.contains(row - 1),
           case .markdown(let previousRow, _) = presentationItems[row - 1].id,
           previousRow == timelineRow {
            return MarkdownDefaults.blockSpacing
        }
        return Design.Spacing.medium
    }
}

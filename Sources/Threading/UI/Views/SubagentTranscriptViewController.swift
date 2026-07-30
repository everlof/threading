import AppKit

/// A session's child-agent navigator and the selected child rendered as a normal conversation.
///
/// The main conversation only carries a compact count in its corner status card. Navigation
/// belongs here in the display pane, above rows built through `ConversationRowView`, so user
/// messages, markdown, thinking, tool calls, results, and notices keep the parent's treatment.
final class SubagentTranscriptViewController: NSViewController {

    // MARK: - Properties

    private let summaryView = SubagentSummaryView()
    private var scrollView: ThemedScrollView!
    private var documentView: NSView!
    private var stack: NSStackView!
    private var agents: [SubagentTimeline.Agent] = []
    private var workingCount = 0
    private var doneCount = 0
    private var agent: SubagentTimeline.Agent?
    private var isSynchronizingSelection = false
    private var hasRendered = false
    private var isRendering = false
    private var renderedWidth: CGFloat = -1

    private(set) var representedThreadID: String?
    private(set) var renderedRowCount = 0
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

        stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.medium
        stack.edgeInsets = NSEdgeInsets(
            top: Design.Spacing.inset,
            left: Design.Spacing.inset,
            bottom: Design.Spacing.inset,
            right: Design.Spacing.inset
        )
        stack.translatesAutoresizingMaskIntoConstraints = false

        documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stack)

        let clip = FlippedClipView()
        clip.drawsBackground = false

        scrollView = ThemedScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.contentView = clip
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = documentView
        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            documentView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),

            stack.topAnchor.constraint(equalTo: documentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
            stack.centerXAnchor.constraint(equalTo: documentView.centerXAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: Design.Size.readableWidth),
            stack.widthAnchor.constraint(lessThanOrEqualTo: documentView.widthAnchor)
        ])

        // Fill a narrow pane, but let the required readable-width cap win in a wide one.
        // Without the matching-width preference the two `lessThanOrEqual` constraints leave
        // the stack's width underdetermined, so an intrinsic user bubble can push the document
        // wider than the clip view and be cut off instead of wrapping.
        let preferredWidth = stack.widthAnchor.constraint(equalTo: documentView.widthAnchor)
        preferredWidth.priority = .defaultHigh
        preferredWidth.isActive = true

        if let agent {
            render(agent, shouldFollow: true)
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard let agent, !isRendering, view.bounds.width > 0,
              abs(view.bounds.width - renderedWidth) > 0.5 else { return }

        // A background tab is populated before it has a pane width. Rebuilding once AppKit
        // installs it gives wrapping labels and user bubbles the geometry they will really use.
        render(agent, shouldFollow: false)
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
        isRendering = true
        defer { isRendering = false }
        renderedWidth = view.bounds.width

        for arranged in stack.arrangedSubviews {
            stack.removeArrangedSubview(arranged)
            arranged.removeFromSuperview()
        }

        summaryView.update(
            items: agents.map(summaryItem),
            workingCount: workingCount,
            doneCount: doneCount
        )
        isSynchronizingSelection = true
        summaryView.setSelection(agent.descriptor.threadID)
        isSynchronizingSelection = false
        add(summaryView)

        var hasTranscriptRow = false
        if agent.conversation.rows.isEmpty {
            add(ConversationRowView.notice(
                L10n.string("The structured child transcript has not arrived yet."),
                kind: .muted
            ))
        } else {
            for item in ConversationRowPresentation.compact(agent.conversation.rows) {
                switch item {
                case .row(let row):
                    let (rowView, startsTurn) = ConversationRowView.make(for: row)
                    if startsTurn, hasTranscriptRow {
                        add(ConversationRowView.turnDivider())
                    }
                    add(rowView)

                case .toolCalls(let calls):
                    let toolViews = calls.map {
                        ConversationRowView.make(for: .toolCall($0)).view
                    }
                    toolViews.forEach { $0.isHidden = true }
                    let label = calls.count == 1
                        ? L10n.string("1 tool call")
                        : L10n.format("%lld tool calls", Int64(calls.count))
                    add(TurnFoldView(label: label, folding: toolViews))
                    toolViews.forEach(add)
                }
                hasTranscriptRow = true
            }
        }

        hasRendered = true
        if shouldFollow { scrollToBottom() }
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
        for arranged in stack.arrangedSubviews {
            stack.removeArrangedSubview(arranged)
            arranged.removeFromSuperview()
        }
        hasRendered = false
    }

    private func add(_ row: NSView) {
        stack.addArrangedSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(
                equalTo: stack.leadingAnchor,
                constant: Design.Spacing.inset
            ),
            row.trailingAnchor.constraint(
                equalTo: stack.trailingAnchor,
                constant: -Design.Spacing.inset
            )
        ])
    }

    private var isNearBottom: Bool {
        guard isViewLoaded else { return true }
        let overflow = documentView.bounds.height - scrollView.contentSize.height
        return overflow <= 0 || scrollView.contentView.bounds.origin.y >= overflow - 40
    }

    private func scrollToBottom() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.view.layoutSubtreeIfNeeded()
            let overflow = self.documentView.bounds.height - self.scrollView.contentSize.height
            self.documentView.scroll(NSPoint(x: 0, y: max(0, overflow)))
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
            transcriptURL: SubagentTranscriptLoader.transcriptURL(for: agent.descriptor)
        )
    }
}

import AppKit

/// The detailed reading behind a sidebar workprint: a bounded repository atlas, a chronological
/// ribbon for non-file actions, exact counts, and (for project scope) recent agent provenance.
final class AgentWorkSummaryView: NSView, ThemedComponent {
    private enum Layout {
        static let atlasHeight: CGFloat = 94
        static let ribbonHeight: CGFloat = 10
    }

    private let titleLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(wrappingLabelWithString: "")
    private let actionLabel = NSTextField(wrappingLabelWithString: "")
    private let contributorLabel = NSTextField(wrappingLabelWithString: "")
    private let legendLabel = NSTextField(wrappingLabelWithString: "")
    private let atlas = FileActivityMapView()
    private let ribbon = AgentWorkRibbonView()
    private let appEvents = AppEventObservations()

    private var target: AgentWorkTarget?
    private var injectedPresentation: AgentWorkPresentation?

    init(target: AgentWorkTarget? = nil) {
        self.target = target
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setup()
        observeChanges()
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func bind(to target: AgentWorkTarget?) {
        self.target = target
        injectedPresentation = nil
        refresh()
    }

    /// Render harness injection; production views bind to the store instead.
    func setPresentation(_ presentation: AgentWorkPresentation?) {
        target = nil
        injectedPresentation = presentation
        refresh()
    }

    func setClock(_ clock: @escaping () -> Date) {
        atlas.clock = clock
    }

    private func setup() {
        setAccessibilityRole(.group)
        setAccessibilityLabel(L10n.string("Observed agent work"))

        titleLabel.applyFont(.caption)
        titleLabel.textColor = Design.Text.label

        for label in [countLabel, actionLabel, contributorLabel, legendLabel] {
            label.applyFont(.subheading)
            label.textColor = Design.Text.secondary
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        contributorLabel.preferredMaxLayoutWidth = SessionPopoverDefaults.contentWidth
        legendLabel.preferredMaxLayoutWidth = SessionPopoverDefaults.contentWidth
        countLabel.preferredMaxLayoutWidth = SessionPopoverDefaults.contentWidth
        actionLabel.preferredMaxLayoutWidth = SessionPopoverDefaults.contentWidth
        legendLabel.textColor = Design.Text.tertiary

        atlas.translatesAutoresizingMaskIntoConstraints = false
        atlas.setAccessibilityIdentifier("agent-work.detail-atlas")
        ribbon.translatesAutoresizingMaskIntoConstraints = false
        ribbon.setAccessibilityIdentifier("agent-work.activity-ribbon")

        let stack = NSStackView(views: [
            titleLabel, countLabel, atlas, ribbon, actionLabel, contributorLabel, legendLabel
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.small
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            widthAnchor.constraint(equalToConstant: SessionPopoverDefaults.contentWidth),
            atlas.widthAnchor.constraint(equalTo: stack.widthAnchor),
            atlas.heightAnchor.constraint(equalToConstant: Layout.atlasHeight),
            ribbon.widthAnchor.constraint(equalTo: stack.widthAnchor),
            ribbon.heightAnchor.constraint(equalToConstant: Layout.ribbonHeight),
            countLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            actionLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            contributorLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            legendLabel.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    private func observeChanges() {
        appEvents.observe(AgentWorkDidChange.self) { [weak self] event in
            guard let self, let target = self.target,
                  target.projectID == event.projectID,
                  target.sessionID == nil || target.sessionID == event.sessionID else { return }
            self.refresh()
        }
    }

    private func refresh() {
        let presentation: AgentWorkPresentation?
        if let target {
            presentation = AgentWorkTraceStore.shared.presentation(for: target)
            atlas.bind(to: target)
        } else {
            presentation = injectedPresentation
            atlas.setWorkPresentation(presentation)
        }

        guard let presentation else {
            titleLabel.stringValue = L10n.string("Observed work")
            countLabel.stringValue = L10n.string("Loading repository activity…")
            actionLabel.stringValue = ""
            contributorLabel.stringValue = ""
            contributorLabel.isHidden = true
            legendLabel.stringValue = L10n.string("Thin marks are reads; solid marks are edits.")
            ribbon.setActions([])
            return
        }

        let projectScope = presentation.scope.isProjectScope
        titleLabel.stringValue = projectScope
            ? L10n.string("Project work · all agents")
            : L10n.string("Observed work")

        let reads = presentation.bins.reduce(0) { $0 + $1.readCount }
        let edits = presentation.bins.reduce(0) { $0 + $1.editCount }
        countLabel.stringValue = L10n.format(
            "%d of %d files · %d reads · %d edits",
            presentation.touchedFileCount,
            max(presentation.repositoryFileCount, presentation.touchedFileCount),
            reads,
            edits
        )

        let shell = presentation.categoryCounts[.shell, default: 0]
        let searches = presentation.categoryCounts[.network, default: 0]
            + presentation.categoryCounts[.browser, default: 0]
        let subagents = presentation.categoryCounts[.subagent, default: 0]
        actionLabel.stringValue = L10n.format(
            "%d actions · %d shell · %d web · %d subagent",
            presentation.totalActionCount,
            shell,
            searches,
            subagents
        )
        ribbon.setActions(presentation.recentActions)

        if projectScope {
            contributorLabel.isHidden = false
            let names = presentation.recentContributors.prefix(4).map { contributor in
                contributor.sessionTitle.isEmpty ? contributor.agentLabel : contributor.sessionTitle
            }
            contributorLabel.stringValue = names.isEmpty
                ? L10n.string("No agent work observed yet")
                : L10n.format("Recent agents: %@", names.joined(separator: " · "))
            legendLabel.stringValue = L10n.string(
                "Thin marks are reads; solid marks are edits; a cap means agents overlap."
            )
        } else {
            contributorLabel.stringValue = ""
            contributorLabel.isHidden = true
            legendLabel.stringValue = L10n.string(
                "Thin marks are reads; solid marks are edits."
            )
        }

        setAccessibilityValue(countLabel.stringValue + ". " + actionLabel.stringValue)
    }
}

/// A chronological, category-coloured ribbon. It draws at most the trace's 96 retained actions.
private final class AgentWorkRibbonView: NSView, ThemedComponent {
    private var actions: [AgentWorkAction] = []
    private var themeRedraw: ThemeRedraw?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        themeRedraw = ThemeRedraw(self)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setActions(_ actions: [AgentWorkAction]) {
        self.actions = Array(actions.suffix(AgentSessionWorkTrace.Limits.recentActions))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        Design.Surface.divider.setFill()
        bounds.fill()
        guard !actions.isEmpty else { return }

        let count = actions.count
        for (index, action) in actions.enumerated() {
            let lower = floor(CGFloat(index) * bounds.width / CGFloat(count))
            let upper = floor(CGFloat(index + 1) * bounds.width / CGFloat(count))
            color(for: action.category).setFill()
            NSRect(
                x: lower,
                y: action.category == .filesystem ? 0 : bounds.height * 0.22,
                width: max(1, upper - lower),
                height: action.category == .filesystem ? bounds.height : bounds.height * 0.56
            ).fill()
        }
    }

    private func color(for category: ExecutionAuditRecord.Category) -> NSColor {
        let categories = ExecutionAuditRecord.Category.allCases
        let index = categories.firstIndex(of: category) ?? 0
        return Design.Categorical.hue(at: index).color
    }
}

private extension AgentWorkPresentation.Scope {
    var isProjectScope: Bool {
        if case .project = self { return true }
        return false
    }
}

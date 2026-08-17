import AppKit

/// The bounded overview above the Activity tree: a repository atlas, a chronological ribbon for
/// non-file actions, exact counts, and (for project scope) recent agent provenance.
///
/// The counts are the atlas' and ribbon's own legend. The edit and read marks beside their
/// numbers draw with the map's exact encoding (`FileActivityInk`), and each action count wears
/// its ribbon hue, so the prose sentence that used to explain both is down to the one fact no
/// mark can carry alone — the multi-agent cap.
final class AgentWorkSummaryView: NSView, ThemedComponent {
    private let titleLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let contributorLabel = NSTextField(wrappingLabelWithString: "")
    private let legendLabel = NSTextField(wrappingLabelWithString: "")
    private let atlas = FileActivityMapView()
    private let ribbon = AgentWorkRibbonView()
    private let appEvents = AppEventObservations()

    private let filesToken = WorkCountToken()
    private let editsToken = WorkCountToken(mark: .edit)
    private let readsToken = WorkCountToken(mark: .read)
    private let observedToken = WorkCountToken(mark: .observed)
    private let actionsToken = WorkCountToken()
    private let shellToken = WorkCountToken(mark: .action(.shell))
    private let webToken = WorkCountToken(mark: .action(.network))
    private let subagentToken = WorkCountToken(mark: .action(.subagent))
    private let otherToken = WorkCountToken(mark: .action(nil))
    private let statsRow = WorkTokenFlowView()
    private let actionsRow = WorkTokenFlowView()

    private var target: AgentWorkTarget?
    private var injectedPresentation: AgentWorkPresentation?
    private var injectedSource: AgentWorkSource?

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
        injectedSource = nil
        refresh()
    }

    /// Render harness injection; production views bind to the store instead.
    func setPresentation(
        _ presentation: AgentWorkPresentation?,
        source: AgentWorkSource = .live
    ) {
        target = nil
        injectedPresentation = presentation
        injectedSource = source
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

        for label in [statusLabel, contributorLabel, legendLabel] {
            label.applyFont(.subheading)
            label.textColor = Design.Text.secondary
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        legendLabel.textColor = Design.Text.tertiary

        statsRow.setTokens([filesToken, editsToken, readsToken, observedToken])
        actionsRow.setTokens([actionsToken, shellToken, webToken, subagentToken, otherToken])

        atlas.translatesAutoresizingMaskIntoConstraints = false
        atlas.setAccessibilityIdentifier("agent-work.detail-atlas")
        ribbon.translatesAutoresizingMaskIntoConstraints = false
        ribbon.setAccessibilityIdentifier("agent-work.activity-ribbon")

        let stack = NSStackView(views: [
            titleLabel, statusLabel, statsRow, atlas, ribbon,
            actionsRow, contributorLabel, legendLabel
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.small
        // The ribbon is the atlas' own bottom edge, not a sibling group.
        stack.setCustomSpacing(Design.Spacing.hairline, after: atlas)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            atlas.widthAnchor.constraint(equalTo: stack.widthAnchor),
            atlas.heightAnchor.constraint(equalToConstant: SummaryLayout.atlasHeight),
            ribbon.widthAnchor.constraint(equalTo: stack.widthAnchor),
            ribbon.heightAnchor.constraint(equalToConstant: SummaryLayout.ribbonHeight),
            statsRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            actionsRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            contributorLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            legendLabel.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    /// A wrapping label wraps at the width it *has*, not at a width guessed up front. The old
    /// fixed `preferredMaxLayoutWidth` computed a one-line intrinsic height at popover width,
    /// the constraint solve then narrowed the label, and the second line was clipped out of
    /// existence — the visible symptom was a contributor list ending in a dangling separator.
    override func layout() {
        super.layout()
        for label in [statusLabel, contributorLabel, legendLabel]
        where label.preferredMaxLayoutWidth != bounds.width {
            label.preferredMaxLayoutWidth = bounds.width
        }
    }

    private func observeChanges() {
        appEvents.observe(AgentWorkDidChange.self) { [weak self] event in
            guard let self, let target = self.target,
                  target.projectID == event.projectID,
                  target.sessionID == nil || target.sessionID == event.sessionID else { return }
            self.refresh()
        }
    }

    /// What this session's reading can come from, which decides both whether the card draws at
    /// all and which counts it is entitled to show. Project scope aggregates many sessions with
    /// different answers, so it asks nothing and shows everything it has.
    private var source: AgentWorkSource {
        if let sessionID = target?.sessionID { return .resolve(sessionID: sessionID) }
        return injectedSource ?? .live
    }

    private func refresh() {
        // Nothing feeds this session. Drawing the repository silhouette with zeros beside it
        // said "this chat did nothing" in the same picture that says "nobody was watching"; the
        // sentence is the only honest thing the card has, so it is the only thing it shows.
        // Project scope resolves to `.live` and therefore never lands here: it aggregates many
        // sessions, and one of them being unwatchable says nothing about the rest.
        //
        // Resolved before the atlas is bound, so a card that will draw no atlas does not ask the
        // store to enumerate a checkout to build one.
        let source = self.source
        guard source.hasAnySource else {
            showUnavailable(source)
            return
        }

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
            statusLabel.stringValue = L10n.string("Loading repository activity…")
            statusLabel.isHidden = false
            statsRow.isHidden = true
            actionsRow.isHidden = true
            atlas.isHidden = false
            ribbon.isHidden = false
            contributorLabel.stringValue = ""
            contributorLabel.isHidden = true
            legendLabel.stringValue = ""
            legendLabel.isHidden = true
            ribbon.setActions([])
            setAccessibilityValue(statusLabel.stringValue)
            return
        }

        statusLabel.isHidden = true
        statsRow.isHidden = false
        atlas.isHidden = false
        // Actions are tool calls. A git-observed reading has none by construction, so the row
        // and the chronology under the atlas would be permanent zeros and an empty strip rather
        // than a quiet stretch of a real one.
        actionsRow.isHidden = !source.reportsExactCalls
        ribbon.isHidden = !source.reportsExactCalls

        let projectScope = presentation.scope.isProjectScope
        titleLabel.stringValue = projectScope
            ? L10n.string("Project work · all agents")
            : L10n.string("Observed work")

        let reads = presentation.bins.reduce(0) { $0 + $1.readCount }
        let edits = presentation.bins.reduce(0) { $0 + $1.editCount }
        let observed = presentation.observedChangeCount
        let repositoryFiles = max(presentation.repositoryFileCount, presentation.touchedFileCount)
        filesToken.set(
            value: presentation.touchedFileCount,
            unit: L10n.format("of %@ files", WorkCountFormat.grouped(repositoryFiles))
        )
        editsToken.set(value: edits, unit: L10n.string("edits"))
        readsToken.set(value: reads, unit: L10n.string("reads"))
        observedToken.set(value: observed, unit: L10n.string("changed"))

        // A count this source cannot produce is withheld, not shown as zero: "0 reads" is a
        // measurement, and a runtime whose reads nobody can see has not taken one.
        editsToken.isHidden = !source.reportsExactCalls
        readsToken.isHidden = !source.reportsExactCalls
        observedToken.isHidden = observed == 0

        let shell = presentation.categoryCounts[.shell, default: 0]
        let web = presentation.categoryCounts[.network, default: 0]
            + presentation.categoryCounts[.browser, default: 0]
        let subagents = presentation.categoryCounts[.subagent, default: 0]
        let filesystem = presentation.categoryCounts[.filesystem, default: 0]
        let other = presentation.totalActionCount - shell - web - subagents - filesystem
        actionsToken.set(value: presentation.totalActionCount, unit: L10n.string("actions"))
        shellToken.set(value: shell, unit: L10n.string("shell"))
        webToken.set(value: web, unit: L10n.string("web"))
        subagentToken.set(value: subagents, unit: L10n.string("subagent"))
        otherToken.set(value: other, unit: L10n.string("other"))
        // A zero count is ground, not figure — the total already says how much work there was.
        shellToken.isHidden = shell == 0
        webToken.isHidden = web == 0
        subagentToken.isHidden = subagents == 0
        otherToken.isHidden = other <= 0
        statsRow.noteTokensChanged()
        actionsRow.noteTokensChanged()
        ribbon.setActions(presentation.recentActions)

        if projectScope {
            contributorLabel.isHidden = false
            let names = presentation.recentContributors.prefix(4)
                .compactMap { contributor -> String? in
                    let name = contributor.sessionTitle.isEmpty
                        ? contributor.agentLabel
                        : contributor.sessionTitle
                    return name.isEmpty ? nil : name
                }
            contributorLabel.stringValue = names.isEmpty
                ? L10n.string("No agent work observed yet")
                : L10n.format("Recent agents: %@", names.joined(separator: " · "))
        } else {
            contributorLabel.stringValue = ""
            contributorLabel.isHidden = true
        }

        var legend: [String] = []
        if projectScope {
            // No colour word: the cap draws in the label ink, which is dark on a light ground.
            legend.append(L10n.string("A capped mark means more than one agent touched it."))
        }
        // The provenance line, and the whole reason the observed marks are colourless: what the
        // repository saw change is a weaker fact than what a tool said it wrote, and the card
        // has to say which one a mark is.
        if !source.reportsExactCalls {
            legend.append(L10n.string("Changed files only. This runtime reports no reads or edits."))
        } else if observed > 0 {
            legend.append(
                L10n.string("Plain marks are files a turn changed with no tool naming them.")
            )
        }
        legendLabel.stringValue = legend.joined(separator: " ")
        legendLabel.isHidden = legend.isEmpty

        var spoken = source.reportsExactCalls
            ? L10n.format(
                "%d of %d files · %d reads · %d edits",
                presentation.touchedFileCount,
                repositoryFiles,
                reads,
                edits
            )
            : L10n.format(
                "%d of %d files",
                presentation.touchedFileCount,
                repositoryFiles
            )
        if observed > 0 {
            spoken += " · " + L10n.format("%d observed changes", observed)
        }
        if source.reportsExactCalls {
            spoken += ". " + L10n.format(
                "%d actions · %d shell · %d web · %d subagent",
                presentation.totalActionCount,
                shell,
                web,
                subagents
            )
        }
        setAccessibilityValue(spoken)
    }

    /// The card for a session nothing feeds: one sentence, and none of the encodings it has no
    /// data for. A reading that cannot be taken is not a reading of zero.
    private func showUnavailable(_ source: AgentWorkSource) {
        titleLabel.stringValue = L10n.string("Observed work")
        statusLabel.stringValue = Self.unavailableSentence(source)
        statusLabel.isHidden = false
        statsRow.isHidden = true
        actionsRow.isHidden = true
        contributorLabel.stringValue = ""
        contributorLabel.isHidden = true
        legendLabel.stringValue = ""
        legendLabel.isHidden = true
        atlas.isHidden = true
        ribbon.isHidden = true
        ribbon.setActions([])
        setAccessibilityValue(statusLabel.stringValue)
    }

    private static func unavailableSentence(_ source: AgentWorkSource) -> String {
        guard case .unavailable(let reason) = source else {
            return L10n.string("Nothing observed for this session yet.")
        }
        switch reason {
        case .runtimeKeepsNoReadableTranscript:
            // Not "no work": the work happened. Threading has no way to see it, and says which
            // way would start working.
            return L10n.string(
                "This runtime keeps no transcript Threading can read. Files a turn changes appear here once it has run in a git checkout."
            )
        case .transcriptNotWrittenYet:
            return L10n.string("No transcript for this session yet.")
        }
    }
}

// MARK: - Summary Metrics

private enum SummaryLayout {
    static let atlasHeight: CGFloat = 94
    static let ribbonHeight: CGFloat = 6
    static let markSize: CGFloat = 8
}

/// Counts read as one system when they group the same way everywhere on the card.
@MainActor
private enum WorkCountFormat {
    private static let formatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    static func grouped(_ value: Int) -> String {
        formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}

/// The ribbon's palette — one place for the strip and for the dots that name it. Only the
/// categories a count token names get a hue; the rare rest fold into a muted "other", the
/// same rule `CodeStatsBar` uses for its language fold.
@MainActor
private enum WorkActionInk {
    /// Held below full so the chronology reads as ground beside the atlas, not candy over it.
    static let dimming: CGFloat = 0.75

    static func hue(for category: ExecutionAuditRecord.Category?) -> Design.Categorical.Hue? {
        switch category {
        case .shell:
            return Design.Categorical.hue(at: 1) // Orange, unchanged from the index mapping.
        case .network, .browser:
            return Design.Categorical.hue(at: 3) // Teal — one visual "web" category.
        case .subagent:
            return Design.Categorical.hue(at: 5) // Indigo.
        default:
            return nil
        }
    }

    static func ink(for category: ExecutionAuditRecord.Category?) -> NSColor {
        let base = hue(for: category)?.color ?? Design.Text.tertiary
        return base.withAlphaComponent(base.alphaComponent * dimming)
    }
}

// MARK: - Token Flow Row

/// A run of count tokens that wraps instead of clipping. A fixed horizontal stack cut the
/// trailing token off under wide typefaces at pane widths the old wrapping label handled, and
/// truncating a count's unit word would hide exactly the word that names the number. Bounded:
/// at most five tokens, laid out only when width or content changes.
private final class WorkTokenFlowView: NSView {
    private var tokens: [NSView] = []
    private var intrinsicHeight: CGFloat = 0

    override var isFlipped: Bool { true }

    func setTokens(_ views: [NSView]) {
        tokens.forEach { $0.removeFromSuperview() }
        tokens = views
        tokens.forEach(addSubview)
        noteTokensChanged()
    }

    /// The owner says a token's text or visibility changed; sizes are re-fit on next layout.
    func noteTokensChanged() {
        needsLayout = true
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for token in tokens where !token.isHidden {
            let size = token.fittingSize
            if x > 0, x + size.width > bounds.width {
                x = 0
                y += lineHeight + Design.Spacing.tight
                lineHeight = 0
            }
            token.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
            x += size.width + Design.Spacing.medium
            lineHeight = max(lineHeight, size.height)
        }
        let height = y + lineHeight
        if height != intrinsicHeight {
            intrinsicHeight = height
            invalidateIntrinsicContentSize()
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: intrinsicHeight)
    }
}

// MARK: - Count Token

/// One count in a summary row: an optional mark drawn in the atlas/ribbon's own encoding, the
/// number leading in fixed-width digits, the word for it receding beside it.
private final class WorkCountToken: NSView {
    private let markView: WorkMarkView?
    private let valueLabel = NSTextField(labelWithString: "")
    private let unitLabel = NSTextField(labelWithString: "")

    init(mark: WorkMarkView.Encoding? = nil) {
        markView = mark.map(WorkMarkView.init)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        valueLabel.applyFont(.numericControl(weight: .semibold))
        valueLabel.textColor = Design.Text.label
        unitLabel.applyFont(.subheading)
        unitLabel.textColor = Design.Text.secondary

        var constraints: [NSLayoutConstraint] = []
        for view in [markView, valueLabel, unitLabel].compactMap({ $0 }) {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        if let markView {
            constraints += [
                markView.leadingAnchor.constraint(equalTo: leadingAnchor),
                markView.centerYAnchor.constraint(equalTo: valueLabel.centerYAnchor),
                markView.widthAnchor.constraint(equalToConstant: SummaryLayout.markSize),
                markView.heightAnchor.constraint(equalToConstant: SummaryLayout.markSize),
                valueLabel.leadingAnchor.constraint(
                    equalTo: markView.trailingAnchor,
                    constant: Design.Spacing.tight
                )
            ]
        } else {
            constraints.append(valueLabel.leadingAnchor.constraint(equalTo: leadingAnchor))
        }
        constraints += [
            valueLabel.topAnchor.constraint(equalTo: topAnchor),
            valueLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
            unitLabel.leadingAnchor.constraint(
                equalTo: valueLabel.trailingAnchor,
                constant: Design.Spacing.tight
            ),
            unitLabel.firstBaselineAnchor.constraint(equalTo: valueLabel.firstBaselineAnchor),
            unitLabel.trailingAnchor.constraint(equalTo: trailingAnchor)
        ]
        NSLayoutConstraint.activate(constraints)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func set(value: Int, unit: String) {
        valueLabel.stringValue = WorkCountFormat.grouped(value)
        unitLabel.stringValue = unit
    }
}

// MARK: - Mark

/// The mark beside a count, drawn with the encoding it names: an edit cell, a read cell, or an
/// action category's ribbon ink. Decorative — the labels beside it carry the words.
private final class WorkMarkView: NSView, ThemedComponent {
    enum Encoding {
        case edit
        case read
        case observed
        case action(ExecutionAuditRecord.Category?)
    }

    private let encoding: Encoding
    private var themeRedraw: ThemeRedraw?

    init(encoding: Encoding) {
        self.encoding = encoding
        super.init(frame: .zero)
        themeRedraw = ThemeRedraw(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Matches the atlas, so the read strip sits on the same edge here as there.
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        switch encoding {
        case .edit:
            FileActivityInk.edit.setFill()
            bounds.fill()
        case .read:
            FileActivityInk.restingEven.setFill()
            bounds.fill()
            FileActivityInk.read.setFill()
            NSRect(
                x: bounds.minX,
                y: bounds.minY,
                width: bounds.width,
                height: max(1, floor(bounds.height * FileActivityInk.readStripFraction))
            ).fill()
        case .observed:
            // The same whole-cell fill an edit draws, in the colourless ink: the shape says "this
            // file was touched" and the absence of accent says nobody claimed it.
            FileActivityInk.observed.setFill()
            bounds.fill()
        case .action(let category):
            WorkActionInk.ink(for: category).setFill()
            NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5)).fill()
        }
    }
}

// MARK: - Ribbon

/// A chronological ribbon of the trace's recent non-file actions — file work is the atlas'
/// story directly above, and repeating it here as full-height blocks made this strip the
/// loudest ink on the card. Adjacent same-category actions merge into one run, every run draws
/// at one height in ink held below full, and the hues are named by the count tokens beneath
/// the strip rather than by a prose legend. Draws at most the trace's 96 retained actions.
private final class AgentWorkRibbonView: NSView, ThemedComponent {
    private enum Metrics {
        static let runGap: CGFloat = 1
        static let cornerRadius: CGFloat = 2
    }

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
        self.actions = actions
            .suffix(AgentSessionWorkTrace.Limits.recentActions)
            .filter { $0.category != .filesystem }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSBezierPath(
            roundedRect: bounds,
            xRadius: Metrics.cornerRadius,
            yRadius: Metrics.cornerRadius
        ).addClip()
        Design.Surface.divider.setFill()
        bounds.fill()
        guard !actions.isEmpty else { return }

        let count = actions.count
        var index = 0
        while index < count {
            var end = index + 1
            while end < count, actions[end].category == actions[index].category { end += 1 }
            let lower = floor(CGFloat(index) * bounds.width / CGFloat(count))
            let upper = floor(CGFloat(end) * bounds.width / CGFloat(count))
            let trailingGap = end < count ? Metrics.runGap : 0
            WorkActionInk.ink(for: actions[index].category).setFill()
            NSRect(
                x: lower,
                y: 0,
                width: max(1, upper - lower - trailingGap),
                height: bounds.height
            ).fill()
            index = end
        }
    }
}

private extension AgentWorkPresentation.Scope {
    var isProjectScope: Bool {
        if case .project = self { return true }
        return false
    }
}

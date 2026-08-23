import AppKit

// MARK: - Defaults

private enum BackgroundSessionsListDefaults {

    /// A row is two single lines plus the card's own breathing, so it is a fixed measure rather
    /// than an automatic one: every row here has exactly the same shape, and an automatic height
    /// would buy a wrapping budget nothing in the row can spend.
    static let rowHeight: CGFloat = 54

    /// The viewport never collapses below one row, so an answer arriving into an empty list does
    /// not make the page jump.
    static let minimumHeight = rowHeight

    /// Six rows, then it scrolls inside itself. The daemon is expected to hold about eight and
    /// stress-tested at forty (`pty-host.md`), and a settings card that grows to forty rows is a
    /// page nobody can reach the bottom of. The cap is what makes this a bounded surface over an
    /// externally sized list rather than a stack that happens to be short today.
    static let maximumVisibleRows = 6

    static let maximumHeight = rowHeight * CGFloat(maximumVisibleRows)

    static let columnIdentifier = NSUserInterfaceItemIdentifier("BackgroundSessionsColumn")
    static let cellIdentifier = NSUserInterfaceItemIdentifier("BackgroundSessionsRow")

    /// Below this, a child is described in words rather than measured.
    ///
    /// The formatter's smallest unit is a minute, so a session forty seconds old comes out as
    /// "Running for 0m" — which reads as a broken clock rather than as a new agent, and was
    /// visible in the rendered list and in no assertion anybody would have written.
    static let justStartedSeconds: TimeInterval = 60

    /// How an uptime reads. Two units, abbreviated: "4h 12m" answers "has this been stuck all
    /// afternoon?", and a third unit answers nothing anybody asked.
    static let uptime: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter
    }()
}

// MARK: - The list

/// What `threading-ptyd` is holding, with a way to end each one.
///
/// **The surface a wedged detached agent is found on.** Everything else about a host-backed
/// session is invisible by design — that is the feature — so this is the one place that says a
/// child exists, how long it has been running, and which process it is, and the one place that
/// can end it.
///
/// A table over a value model rather than a stack of retained rows. The count comes from another
/// process and is therefore unbounded as far as this page is concerned, so the viewport is capped
/// and AppKit constructs only the rows inside it. It is embedded in a vertically scrolling
/// settings page, so it hands the wheel back at its own content ends
/// (`ThemedScrollView.VerticalScrollHandoff.atContentEnds`) — a nested list that swallows a
/// gesture is a page the user cannot scroll past.
///
/// The empty state is not a blank panel: it carries the reason, which is `PTYHostAvailability`'s
/// and is the whole point of that type having separate cases. `requiresApproval` is the one
/// reason with a fix the app cannot perform, so it is the one that grows a button.
final class BackgroundSessionsListView: NSView, NSTableViewDataSource, NSTableViewDelegate {

    // MARK: - Types

    /// What the user pressed. Held by the page, which owns the confirmation and the inventory.
    struct Actions {
        var stop: (PTYHostHeldSession) -> Void
        var openLoginItems: () -> Void
    }

    // MARK: - Properties

    private let actions: Actions
    private let table = ThemedTableView()
    private let scroll = ThemedScrollView()
    private let content = NSStackView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let emptyAction: ThemedButton
    private let emptyRow = NSView()

    private lazy var heightConstraint = scroll.heightAnchor.constraint(
        equalToConstant: BackgroundSessionsListDefaults.minimumHeight
    )

    private var sessions: [PTYHostHeldSession] = []
    private var now = Date()

    /// The complete cheap model against the live AppKit viewport, for the stress fixture and for
    /// a test that wants to know the cap is real.
    var sessionCountForTesting: Int { sessions.count }
    var materializedRowCountForTesting: Int {
        var count = 0
        table.enumerateAvailableRowViews { _, _ in count += 1 }
        return count
    }
    var viewportHeightForTesting: CGFloat { heightConstraint.constant }
    var verticalScrollHandoffForTesting: ThemedScrollView.VerticalScrollHandoff {
        scroll.verticalScrollHandoff
    }
    var emptyMessageForTesting: String { emptyLabel.stringValue }
    var showsEmptyStateForTesting: Bool { !emptyRow.isHidden }
    var showsLoginItemsActionForTesting: Bool { !emptyAction.isHidden }

    // MARK: - Initialization

    init(actions: Actions) {
        self.actions = actions
        emptyAction = ThemedButton(title: L10n.string("Open Login Items…"), target: nil, action: nil)
        super.init(frame: .zero)
        emptyAction.target = self
        emptyAction.action = #selector(openLoginItemsPressed)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public Methods

    /// Draws one state. Called again whenever the survey answers; the value model is what moves,
    /// and AppKit recycles whatever the viewport still shows.
    func show(_ state: PTYHostBackgroundSessionsState, at now: Date = Date()) {
        self.now = now
        sessions = state.sessions
        emptyLabel.stringValue = state.emptyMessage
        emptyAction.isHidden = !state.status.offersLoginItems
        emptyRow.isHidden = !sessions.isEmpty
        scroll.isHidden = sessions.isEmpty
        heightConstraint.constant = min(
            max(
                CGFloat(sessions.count) * BackgroundSessionsListDefaults.rowHeight,
                BackgroundSessionsListDefaults.minimumHeight
            ),
            BackgroundSessionsListDefaults.maximumHeight
        )
        table.reloadData()
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        table.fitSoleColumnToWidth()
    }

    // MARK: - Private Methods

    private func setupViews() {
        translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: BackgroundSessionsListDefaults.columnIdentifier)
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.selectionHighlightStyle = .none
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.intercellSpacing = .zero
        table.rowHeight = BackgroundSessionsListDefaults.rowHeight
        // An `NSTableView` installed as a scroll view's document does not inherit the clip width
        // through Auto Layout; without this its launch-time fitting width becomes permanent.
        table.autoresizingMask = [.width]
        table.delegate = self
        table.dataSource = self

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        // The page below this is the vertical scroller the user is actually driving. Handing the
        // wheel back at the content ends is what stops a six-row list from being a place the
        // gesture dies.
        scroll.verticalScrollHandoff = .atContentEnds
        scroll.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.applyFont(.body)
        emptyLabel.textColor = Design.Text.secondary
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        emptyAction.emphasis = .secondary
        emptyAction.translatesAutoresizingMaskIntoConstraints = false
        emptyAction.setContentHuggingPriority(.required, for: .horizontal)
        emptyAction.setContentCompressionResistancePriority(.required, for: .horizontal)

        let emptyContent = NSStackView(views: [emptyLabel, emptyAction])
        emptyContent.orientation = .horizontal
        emptyContent.alignment = .centerY
        emptyContent.distribution = .fill
        emptyContent.spacing = Design.Spacing.medium
        emptyContent.translatesAutoresizingMaskIntoConstraints = false

        emptyRow.translatesAutoresizingMaskIntoConstraints = false
        emptyRow.addSubview(emptyContent)
        NSLayoutConstraint.activate([
            emptyContent.topAnchor.constraint(
                equalTo: emptyRow.topAnchor,
                constant: Design.Spacing.medium
            ),
            emptyContent.bottomAnchor.constraint(
                equalTo: emptyRow.bottomAnchor,
                constant: -Design.Spacing.medium
            ),
            emptyContent.leadingAnchor.constraint(
                equalTo: emptyRow.leadingAnchor,
                constant: Design.Spacing.inset
            ),
            emptyContent.trailingAnchor.constraint(
                equalTo: emptyRow.trailingAnchor,
                constant: -Design.Spacing.inset
            ),
            emptyRow.heightAnchor.constraint(
                greaterThanOrEqualToConstant: SettingsUIDefaults.rowHeight
            )
        ])

        // A stack rather than two pinned siblings: a hidden arranged view leaves the layout
        // entirely, so the card is exactly as tall as whichever half is showing.
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 0
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addArrangedSubview(emptyRow)
        content.addArrangedSubview(scroll)

        // The list reads as one contained group rather than floating on the page — the card the
        // themes list draws for its own list, and the same surface roles.
        applySurface(fill: Design.Surface.panel, radius: .panel, border: Design.Surface.border)
        addSubview(content)

        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            emptyRow.widthAnchor.constraint(equalTo: content.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: content.widthAnchor),
            heightConstraint
        ])

        setAccessibilityIdentifier("advanced.background-sessions")
        show(.surveying)
    }

    // MARK: - Table

    func numberOfRows(in _: NSTableView) -> Int { sessions.count }

    /// These rows are content, not a choice. A list that says nothing about selection gets the
    /// system's accent rather than the theme's.
    func tableView(_: NSTableView, shouldSelectRow _: Int) -> Bool { false }

    func tableView(_ tableView: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
        guard sessions.indices.contains(row) else { return nil }
        let identifier = BackgroundSessionsListDefaults.cellIdentifier
        let host = tableView.makeView(withIdentifier: identifier, owner: self)
            as? ThemedVirtualTableCell ?? ThemedVirtualTableCell()
        host.identifier = identifier
        host.install(
            rowContent(for: sessions[row], at: row),
            columnWidth: tableView.tableColumns.first?.width ?? tableView.bounds.width,
            horizontalInset: Design.Spacing.inset,
            topInset: Design.Spacing.small,
            bottomInset: Design.Spacing.small
        )
        return host
    }

    /// The name on top, everything that identifies the process underneath, and the one action on
    /// the trailing edge.
    private func rowContent(for session: PTYHostHeldSession, at index: Int) -> NSView {
        let name = NSTextField(labelWithString: session.name)
        name.applyFont(.body)
        name.textColor = Design.Text.label
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let detail = NSTextField(labelWithString: Self.detail(for: session, at: now))
        detail.applyFont(.subheading)
        detail.textColor = Design.Text.secondary
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let labels = NSStackView(views: [name, detail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = Design.Spacing.hairline
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // Target/action rather than a captured closure: a `ThemedControl` is an `NSControl`, so
        // its press arrives as an action and the sender's tag is what names which row was
        // pressed — the rule `PaneNoticeView` states for its own answers, and the reason a
        // recycled cell cannot end up holding a stale session in a closure.
        let stop = ThemedButton(title: L10n.string("Stop"), target: self, action: #selector(stopPressed(_:)))
        stop.emphasis = .secondary
        stop.tag = index
        // An ended child has nothing left to stop. Disabled rather than dropped: a control that
        // vanishes explains less than one that waits.
        stop.isEnabled = !session.hasExited
        stop.setAccessibilityLabel(L10n.format("Stop %@", session.name))
        stop.setContentHuggingPriority(.required, for: .horizontal)
        stop.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = NSStackView(views: [labels, stop])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = Design.Spacing.medium
        return row
    }

    // MARK: - Actions

    @objc private func stopPressed(_ sender: ThemedButton) {
        guard sessions.indices.contains(sender.tag) else { return }
        actions.stop(sessions[sender.tag])
    }

    @objc private func openLoginItemsPressed() {
        actions.openLoginItems()
    }

    // MARK: - Copy

    /// Project, runtime, uptime and pid, in that order: what it is, what it is running, how long
    /// it has been, and the number a support answer needs.
    static func detail(for session: PTYHostHeldSession, at now: Date) -> String {
        var parts: [String] = []
        if let project = session.project, !project.isEmpty { parts.append(project) }
        if let agent = session.agent, !agent.isEmpty { parts.append(agent) }
        parts.append(uptime(for: session, at: now))
        // `%@` over `%lld`, because `L10n.format` formats against the current locale and a pid is
        // an identifier rather than a quantity: `%lld` renders 5150 as "5,150", which is not a
        // number anybody can paste into `kill` or look for in Activity Monitor.
        parts.append(L10n.format("pid %@", String(session.pid)))
        return parts.joined(separator: " · ")
    }

    private static func uptime(for session: PTYHostHeldSession, at now: Date) -> String {
        guard !session.hasExited else { return L10n.string("Ended") }
        let elapsed = max(0, now.timeIntervalSince(session.startedAt))
        guard elapsed >= BackgroundSessionsListDefaults.justStartedSeconds,
              let measure = BackgroundSessionsListDefaults.uptime.string(from: elapsed),
              !measure.isEmpty else {
            return L10n.string("Just started")
        }
        return L10n.format("Running for %@", measure)
    }
}

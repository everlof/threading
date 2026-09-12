import AppKit

/// The manager's host-owned Chats tab, projected from durable supervision rows.
@MainActor
final class SupervisionListViewController: NSViewController {
    struct Row {
        let supervision: Supervision
        let session: AgentSession
        let activity: SessionActivity
        let lastEvent: SupervisionEvent?
    }

    let managerID: SessionID
    private let rowsProvider: (() -> [Row])?
    private let now: () -> Date
    var onOpen: ((SessionID) -> Void)?
    var onMessage: ((SessionID) -> Void)?
    var onArchive: ((SessionID) -> Void)?
    var onRelease: ((SessionID) -> Void)?

    private(set) var rows: [Row] = []
    private let events = AppEventObservations()
    private var refreshIsScheduled = false
    private let root = ThemedSurfaceView()
    private let titleLabel = NSTextField(labelWithString: L10n.string("Managed chats"))
    private let countLabel = NSTextField(labelWithString: "")
    private let explanationLabel = NSTextField(
        wrappingLabelWithString: L10n.string("Briefs and events are read from Threading's supervision record, not this manager's transcript.")
    )
    private let emptyLabel = NSTextField(
        wrappingLabelWithString: L10n.string("No managed chats yet. Spawn or adopt a chat to keep its brief and events here.")
    )
    private let table = ThemedTableView()
    private let scroll = ThemedScrollView()

    init(
        managerID: SessionID,
        rowsProvider: (() -> [Row])? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.managerID = managerID
        self.rowsProvider = rowsProvider
        self.now = now
        super.init(nibName: nil, bundle: nil)
        events.observe(SupervisionDidChange.self) { [weak self] event in
            guard event.managerID == self?.managerID else { return }
            self?.scheduleRefresh()
        }
        events.observe(SessionWorkDidChange.self) { [weak self] event in
            guard self?.rows.contains(where: { $0.session.id == event.sessionID }) == true else { return }
            self?.scheduleRefresh()
        }
        events.observe(SessionActivityDidChange.self) { [weak self] event in
            guard self?.rows.contains(where: { $0.session.id == event.sessionID }) == true else { return }
            self?.scheduleRefresh()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        root.applySurface(fill: Design.Surface.ground, radius: .fixed(0), pattern: .backdrop)
        root.frame = NSRect(x: 0, y: 0, width: 560, height: 640)
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        build()
        refresh()
    }

    private func scheduleRefresh() {
        guard !refreshIsScheduled else { return }
        refreshIsScheduled = true
        // A work stamp precedes its runtime/receipt changes. Read the completed projection once.
        Task { @MainActor [weak self] in
            guard let self else { return }
            refreshIsScheduled = false
            refresh()
        }
    }

    func refresh() {
        if let rowsProvider {
            rows = rowsProvider()
        } else {
            rows = ControlGrantStore.shared.activeChildren(of: managerID).compactMap { supervision in
                guard let session = ProjectStore.shared.session(withID: supervision.childID) else { return nil }
                return Row(
                    supervision: supervision,
                    session: session,
                    activity: AgentRuntime.shared.activity(sessionID: session.id),
                    lastEvent: ControlGrantStore.shared.events(for: supervision.id).last
                )
            }
        }

        rows.sort {
            if $0.session.lastUsedAt != $1.session.lastUsedAt {
                return $0.session.lastUsedAt > $1.session.lastUsedAt
            }
            return $0.session.id.uuidString < $1.session.id.uuidString
        }

        countLabel.stringValue = rows.count == 1
            ? L10n.string("1 managed chat")
            : L10n.format("%lld managed chats", Int64(rows.count))
        emptyLabel.isHidden = !rows.isEmpty
        scroll.isHidden = rows.isEmpty
        table.reloadData()
    }

    private func build() {
        titleLabel.applyFont(.heading)
        titleLabel.textColor = Design.Text.label
        countLabel.applyFont(.caption)
        countLabel.textColor = Design.Text.tertiary
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        explanationLabel.applyFont(.detail())
        explanationLabel.textColor = Design.Text.secondary
        explanationLabel.maximumNumberOfLines = 2
        emptyLabel.applyFont(.detail())
        emptyLabel.textColor = Design.Text.tertiary
        emptyLabel.alignment = .center

        let heading = NSStackView(views: [titleLabel, countLabel])
        heading.orientation = .horizontal
        heading.alignment = .firstBaseline
        heading.spacing = Design.Spacing.small
        let header = NSStackView(views: [heading, explanationLabel])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = Design.Spacing.small

        table.headerView = nil
        table.rowHeight = 76
        table.intercellSpacing = .zero
        table.delegate = self
        table.dataSource = self
        table.doubleAction = #selector(openSelection)
        table.target = self
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("managed-chat"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        scroll.documentView = table
        scroll.hasVerticalScroller = true

        [header, scroll, emptyLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview($0)
        }
        let inset = Design.Spacing.large
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: inset),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -inset),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: Design.Spacing.large),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: inset),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -inset),
        ])
    }

    @objc private func openSelection() {
        guard rows.indices.contains(table.clickedRow) else { return }
        onOpen?(rows[table.clickedRow].session.id)
    }

    private func model(for row: Row) -> SupervisionRowView.Model {
        let brief = row.supervision.brief.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        let event: String
        if let last = row.lastEvent {
            let when = Self.relative.localizedString(for: last.at, relativeTo: now())
            event = "\(Self.eventName(last.kind)) · \(when)"
        } else {
            event = L10n.string("No events yet")
        }
        return .init(
            title: row.session.displayTitle,
            agentImage: row.session.kind.icon,
            activity: Self.activityName(row.activity),
            brief: brief,
            event: event,
            accessibility: L10n.format(
                "%1$@, %2$@, brief: %3$@, last event: %4$@",
                row.session.displayTitle,
                Self.activityName(row.activity),
                brief,
                event
            )
        )
    }

    private static func activityName(_ activity: SessionActivity) -> String {
        switch activity {
        case .dormant: L10n.string("Dormant")
        case .idle: L10n.string("Idle")
        case .working: L10n.string("Working")
        case .readyWithBackgroundWork: L10n.string("Ready · background work")
        case .awaitingUser: L10n.string("Waiting for you")
        case .needsAttention: L10n.string("Needs attention")
        case .limitReached: L10n.string("Limit reached")
        }
    }

    private static func eventName(_ event: SupervisionEventKind) -> String {
        switch event {
        case .assigned: L10n.string("Assigned")
        case .settled: L10n.string("Settled")
        case .exited: L10n.string("Exited")
        case .needsAttention: L10n.string("Needs attention")
        case .limitNearing: L10n.string("Limit nearing")
        case .limitReached: L10n.string("Limit reached")
        case .archived: L10n.string("Archived")
        case .moved: L10n.string("Moved")
        case .workspaceFinished: L10n.string("Workspace finished")
        case .reportReceived: L10n.string("Report received")
        case .revoked: L10n.string("Revoked")
        case .released: L10n.string("Released")
        case .eventsDropped: L10n.string("Older events dropped")
        }
    }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
}

extension SupervisionListViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let item = rows[row]
        let view = SupervisionRowView()
        view.configure(model(for: item))
        view.onOpen = { [weak self] in self?.onOpen?(item.session.id) }
        view.onMessage = { [weak self] in self?.onMessage?(item.session.id) }
        view.onArchive = { [weak self] in self?.onArchive?(item.session.id) }
        view.onRelease = { [weak self] in self?.onRelease?(item.session.id) }
        return view
    }
}

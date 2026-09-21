import AppKit

/// The machines a person's projects can run agent sessions on.
///
/// Hosts used to be a destination typed into each project, which meant configuring one machine
/// again for every checkout on it and having nowhere to say whether it was reachable. This is that
/// one place: add a machine, see what it is doing, read why it refused, and remove it.
///
/// **State here is the coordinator's, never the record's.** Whether a host is preparing, fetching
/// components, ready or refusing is a fact about this run of the app
/// (`RemoteExecutionHosts.phase(for:)`), so the page reads it live and redraws on the coordinator's
/// own notification. A record that remembered "ready" would be wrong the moment the machine was
/// switched off.
final class RemoteHostsPreferencesViewController: NSViewController {

    private enum PresentationRow {
        case note
        case empty
        case host(Int)
    }

    // MARK: - Properties

    private let store: RemoteHostStore
    private let hostsCoordinator: RemoteExecutionHosts
    private var rows: [RemoteHostRecord] = []
    private var presentationRows: [PresentationRow] = []
    private var pageView: SettingsPageView?
    private let appEvents = AppEventObservations()

    private lazy var tableView: ThemedGroupedTableView = {
        let table = ThemedGroupedTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("RemoteHostsSettingsContent"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.selectionHighlightStyle = .none
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.intercellSpacing = .zero
        table.rowHeight = RemoteHostsSettingsDefaults.estimatedRowHeight
        table.usesAutomaticRowHeights = true
        table.autoresizingMask = [.width]
        table.delegate = self
        table.dataSource = self
        return table
    }()

    private lazy var scrollView: ThemedScrollView = {
        let scroll = ThemedScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.documentView = tableView
        return scroll
    }()

    private lazy var addButton: ThemedButton = {
        let button = SettingsUI.button(RemoteHostsSettingsStrings.add, target: self, action: #selector(addHost))
        button.setAccessibilityIdentifier("settings.remote-hosts.add")
        return button
    }()

    private lazy var listBody: NSView = {
        let body = NSView()
        addButton.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(addButton)
        body.addSubview(scrollView)
        NSLayoutConstraint.activate([
            addButton.topAnchor.constraint(equalTo: body.topAnchor, constant: Design.Spacing.large),
            addButton.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: Design.Size.glowGutter),
            scrollView.topAnchor.constraint(equalTo: addButton.bottomAnchor, constant: Design.Spacing.medium),
            scrollView.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: body.bottomAnchor)
        ])
        return body
    }()

    init(store: RemoteHostStore? = nil, coordinator: RemoteExecutionHosts = .shared) {
        self.store = store ?? .shared
        self.hostsCoordinator = coordinator
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
        let page = SettingsUI.listPage(
            title: "Remote Hosts",
            summary: RemoteHostsSettingsStrings.summary(0),
            body: listBody
        )
        page.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(page)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: view.topAnchor),
            page.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            page.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        pageView = page
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        appEvents.observe(RemoteHostsDidChange.self) { [weak self] _ in self?.reload() }
        appEvents.observe(ProjectsDidChange.self) { [weak self] _ in self?.reload() }
        // The coordinator posts through the ordinary centre rather than as an `AppEvent`: it runs
        // off the main actor and predates the event types.
        appEvents.observe(RemoteExecutionHosts.didChangeNotification) { [weak self] in
            self?.reload()
        }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        ProjectStore.shared.refreshExecutionHosts(from: store)
        reload()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let width = tableView.tableColumns.first?.width ?? tableView.bounds.width
        tableView.enumerateAvailableRowViews { rowView, _ in
            for cell in rowView.subviews {
                (cell as? ThemedVirtualTableCell)?.setColumnWidth(width)
            }
        }
    }

    // MARK: - Build

    private func reload() {
        rows = store.ordered
        presentationRows = [.note] + (rows.isEmpty ? [.empty] : rows.indices.map(PresentationRow.host))
        pageView?.updateSummary(RemoteHostsSettingsStrings.summary(rows.count))
        updateCardDecorations()
        tableView.reloadData()
    }

    private func updateCardDecorations() {
        let hostRows = presentationRows.indices.filter {
            if case .host = presentationRows[$0] { return true }
            return false
        }
        guard let first = hostRows.first, let last = hostRows.last else {
            tableView.cardDecorations = []
            return
        }
        tableView.cardDecorations = [ThemedTableCardDecoration(rows: first...last)]
    }

    /// One machine: its name over what `ssh` connects to and what runs on it, the state word for
    /// what it is doing now, and the three things a person does to it.
    private func makeRow(_ record: RemoteHostRecord, index: Int) -> NSView {
        let title = NSTextField(labelWithString: record.displayName)
        title.applyFont(.body)
        title.textColor = Design.Text.label
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let usage = ProjectStore.shared.projects(onHost: record.id).count
        let captionText = RemoteHostsSettingsStrings.caption(record, projects: usage)
        let caption = NSTextField(labelWithString: captionText)
        caption.isHidden = captionText.isEmpty
        caption.applyFont(.caption)
        caption.textColor = Design.Text.secondary
        caption.lineBreakMode = .byTruncatingTail
        caption.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let state = RemoteHostPresentation.state(
            of: record,
            phase: hostsCoordinator.phase(for: record.sshDestination),
            step: hostsCoordinator.step(for: record.sshDestination)
        )
        let status = NSTextField(labelWithString: state.label)
        status.applyFont(.caption)
        status.textColor = state.color
        status.setAccessibilityIdentifier("settings.remote-hosts.state.\(index)")
        status.setContentHuggingPriority(.required, for: .horizontal)

        let labels = NSStackView(views: [title, caption])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = Design.Spacing.hairline

        let check = SettingsUI.button(RemoteHostsSettingsStrings.check, target: self, action: #selector(checkHost(_:)))
        check.tag = index
        check.isEnabled = state.allowsChecking
        let edit = SettingsUI.button(RemoteHostsSettingsStrings.edit, target: self, action: #selector(editHost(_:)))
        edit.tag = index
        let remove = SettingsUI.button(RemoteHostsSettingsStrings.remove, target: self, action: #selector(removeHost(_:)))
        remove.tag = index

        let row = NSStackView(views: [labels, status, check, edit, remove])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Design.Spacing.medium
        row.setHuggingPriority(.defaultLow, for: .horizontal)
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        if let detail = state.detail {
            let explanation = NSTextField(wrappingLabelWithString: detail)
            explanation.applyFont(.caption)
            explanation.textColor = Design.Text.secondary
            explanation.setAccessibilityIdentifier("settings.remote-hosts.detail.\(index)")
            let stack = NSStackView(views: [row, explanation])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = Design.Spacing.small
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            explanation.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            return padded(stack)
        }
        return padded(row)
    }

    private func padded(_ content: NSView) -> NSView {
        let container = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Design.Spacing.inset),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Design.Spacing.inset),
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: Design.Spacing.medium),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Design.Spacing.medium)
        ])
        return container
    }

    // MARK: - Actions

    @objc private func addHost() {
        guard let record = RemoteHostRecordPromptAlert.ask(editing: nil) else { return }
        announce(store.add(record), record: record)
    }

    @objc private func editHost(_ sender: NSButton) {
        guard rows.indices.contains(sender.tag),
              let edited = RemoteHostRecordPromptAlert.ask(editing: rows[sender.tag]) else { return }
        let outcome = store.update(edited)
        if outcome == .applied {
            ProjectStore.shared.refreshExecutionHosts(from: store)
        }
        announce(outcome, record: edited)
    }

    @objc private func removeHost(_ sender: NSButton) {
        guard rows.indices.contains(sender.tag) else { return }
        let record = rows[sender.tag]
        let projects: [Project] = ProjectStore.shared.projects(onHost: record.id)
        let confirmed = ConfirmationAlert.ask(ConfirmationRequest(
            prompt: .removeRemoteHost,
            title: RemoteHostsSettingsStrings.removeTitle(record),
            message: RemoteHostsSettingsStrings.removeMessage(projects.map(\.name)),
            confirmTitle: RemoteHostsSettingsStrings.remove
        ))
        guard confirmed else { return }
        let outcome = store.remove(record.id)
        if outcome == .applied {
            // The machine is gone, so the projects that ran on it run here again — said plainly in
            // the message above rather than discovered at the next launch.
            ProjectStore.shared.refreshExecutionHosts(from: store)
        }
        announce(outcome, record: record)
    }

    /// Prepares the host now, so a person can find out whether it works without starting a session
    /// on it. The first check on a machine is also what downloads this build's Linux components.
    @objc private func checkHost(_ sender: NSButton) {
        guard rows.indices.contains(sender.tag) else { return }
        let record = rows[sender.tag]
        _ = hostsCoordinator.readiness(
            for: record.sshDestination,
            components: RemoteHostComponentSource.current(),
            appSocketPath: MCPServer.shared.socketPath
        )
        reload()
    }

    private func announce(_ outcome: RemoteHostStore.Outcome, record: RemoteHostRecord) {
        switch outcome {
        case .applied:
            reload()
        case .refused(let problem):
            NoticeAlert.show(
                NoticeRequest(title: RemoteHostsSettingsStrings.notSaved, message: problem.message),
                in: view.window
            )
        case .duplicate:
            NoticeAlert.show(
                NoticeRequest(
                    title: RemoteHostsSettingsStrings.notSaved,
                    message: RemoteHostsSettingsStrings.duplicate(record.destination)
                ),
                in: view.window
            )
        case .notPersisted:
            NoticeAlert.show(
                NoticeRequest(
                    title: RemoteHostsSettingsStrings.notSaved,
                    message: RemoteHostsSettingsStrings.notPersisted
                ),
                in: view.window
            )
        }
    }

    // MARK: - Testing seams

    var rowCountForTesting: Int { presentationRows.count }
    var hostCountForTesting: Int { rows.count }
}

// MARK: - Table

extension RemoteHostsPreferencesViewController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int { presentationRows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard presentationRows.indices.contains(row) else { return nil }
        let host = (tableView.makeView(
            withIdentifier: RemoteHostsSettingsDefaults.cellIdentifier,
            owner: self
        ) as? ThemedVirtualTableCell) ?? ThemedVirtualTableCell()
        host.identifier = RemoteHostsSettingsDefaults.cellIdentifier

        let content: NSView
        switch presentationRows[row] {
        case .note:
            content = SettingsUI.note(RemoteHostPresentation.componentNote(), localizes: false)
        case .empty:
            content = SettingsUI.note(RemoteHostsSettingsStrings.empty, localizes: false)
        case .host(let index):
            content = rows.indices.contains(index) ? makeRow(rows[index], index: index) : NSView()
        }
        // The note stands off the card below it; the rows themselves are the card's own run.
        let isNote: Bool
        if case .note = presentationRows[row] { isNote = true } else { isNote = false }
        host.install(
            content,
            columnWidth: tableColumn?.width ?? tableView.bounds.width,
            horizontalInset: Design.Size.glowGutter,
            topInset: 0,
            bottomInset: isNote ? Design.Spacing.medium : 0
        )
        return host
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
}

// MARK: - What a host is doing

/// The words this page puts on a host's state, apart from the page so they can be asserted without
/// a window.
@MainActor
enum RemoteHostPresentation {

    struct State: Equatable {
        let label: String
        let color: NSColor
        /// The sentence under the row: why it refused, and what to do about it.
        let detail: String?
        /// Whether checking it now would do anything.
        let allowsChecking: Bool
    }

    static func state(
        of record: RemoteHostRecord,
        phase: RemoteHostPhase,
        step: RemoteHostStep?
    ) -> State {
        guard record.isValid else {
            return State(
                label: RemoteHostsSettingsStrings.unusable,
                color: Design.Status.negative,
                detail: record.problem?.message,
                allowsChecking: false
            )
        }
        switch phase {
        case .idle:
            return State(
                label: RemoteHostsSettingsStrings.notChecked,
                color: Design.Text.secondary,
                detail: nil,
                allowsChecking: true
            )
        case .preparing:
            if case .fetchingComponents(let fraction) = step {
                return State(
                    label: RemoteHostsSettingsStrings.downloading(fraction),
                    color: Design.Status.warning,
                    detail: RemoteHostsSettingsStrings.downloadingDetail,
                    allowsChecking: false
                )
            }
            return State(
                label: RemoteHostsSettingsStrings.settingUp,
                color: Design.Status.warning,
                detail: nil,
                allowsChecking: false
            )
        case .ready(let context):
            // Reachable, installed, and still not able to run an agent: the CLI is missing, or
            // nobody has signed in to it there. Said here rather than discovered inside a session
            // that opens on a login prompt.
            if context.facts.claudePath == nil {
                return State(
                    label: RemoteHostsSettingsStrings.needsAgent,
                    color: Design.Status.warning,
                    detail: RemoteHostsSettingsStrings.installAgent(record.destination),
                    allowsChecking: true
                )
            }
            if context.facts.claudeSignedIn == false {
                return State(
                    label: RemoteHostsSettingsStrings.needsSignIn,
                    color: Design.Status.warning,
                    detail: RemoteHostsSettingsStrings.signInThere(record.destination),
                    allowsChecking: true
                )
            }
            return State(
                label: RemoteHostsSettingsStrings.ready,
                color: Design.Status.positive,
                detail: nil,
                allowsChecking: true
            )
        case .failed(let failure):
            return State(
                label: RemoteHostsSettingsStrings.unreachable,
                color: Design.Status.negative,
                detail: guidance(for: failure),
                allowsChecking: true
            )
        }
    }

    /// What went wrong, in words that say what to do next.
    ///
    /// The one that matters most is host-key verification: `ssh` runs in `BatchMode`, so a machine
    /// the person has never connected to simply refuses, and "unreachable" would send them looking
    /// at the network. Threading deliberately does not answer that prompt for them — accepting a
    /// host key is the person's decision and their `known_hosts` — so the page hands them the exact
    /// command instead.
    static func guidance(for failure: RemoteHostFailure) -> String {
        let detail = failure.detail
        if detail.localizedCaseInsensitiveContains("Host key verification failed")
            || detail.localizedCaseInsensitiveContains("Host key for")
            || detail.localizedCaseInsensitiveContains("known_hosts") {
            return RemoteHostsSettingsStrings.unknownHostKey
        }
        if detail.localizedCaseInsensitiveContains("Permission denied") {
            return RemoteHostsSettingsStrings.permissionDenied
        }
        if failure.token.hasPrefix("component") {
            return detail
        }
        switch failure.token {
        case "noSystemd":
            return RemoteHostsSettingsStrings.noSystemd
        case "unsupportedArchitecture":
            return RemoteHostsSettingsStrings.unsupportedArchitecture(detail)
        case "noComponents":
            return RemoteHostsSettingsStrings.noComponents
        default:
            return detail.isEmpty ? RemoteHostsSettingsStrings.unreachableDetail : detail
        }
    }

    /// The line above the list: where this build's Linux components come from, if anywhere.
    @MainActor
    static func componentNote() -> String {
        if AppSettings.shared.developerRemoteHostBinaryDirectory != nil {
            return RemoteHostsSettingsStrings.developerComponents
        }
        if !RemoteHostComponentSource.hasPublishedComponents {
            return RemoteHostsSettingsStrings.noComponents
        }
        return RemoteHostsSettingsStrings.note
    }
}

// MARK: - Strings and constants

enum RemoteHostsSettingsStrings {
    static var add: String { L10n.string("Add Host…") }
    static var check: String { L10n.string("Check") }
    static var edit: String { L10n.string("Edit…") }
    static var remove: String { L10n.string("Remove") }
    static var ready: String { L10n.string("Ready") }
    static var settingUp: String { L10n.string("Setting up…") }
    static var notChecked: String { L10n.string("Not checked") }
    static var unreachable: String { L10n.string("Unreachable") }
    static var unusable: String { L10n.string("Not usable") }
    static var needsAgent: String { L10n.string("Claude missing") }
    static var needsSignIn: String { L10n.string("Not signed in") }

    static func installAgent(_ destination: String) -> String {
        L10n.format(
            "Ready, but the host’s login shell doesn’t find claude. Install it there, then check again: ssh %@ and follow claude.ai/install.",
            destination
        )
    }

    static func signInThere(_ destination: String) -> String {
        L10n.format(
            "Ready, but Claude isn’t signed in on the host. Run “ssh -t %@ claude” once, sign in there, then check again.",
            destination
        )
    }
    static var notSaved: String { L10n.string("The host wasn’t saved") }

    static var note: String {
        L10n.string("Machines your projects can run Claude Code terminal sessions on, over ssh. A project picks one and names its folder there.")
    }

    static var empty: String {
        L10n.string("No hosts yet. Add a Linux machine you can reach with ssh, then choose it on a project.")
    }

    static var developerComponents: String {
        L10n.string("Using the Linux components from your developer directory instead of the published ones.")
    }

    static var noComponents: String {
        L10n.string("This build has no Linux components, so it can’t set up a host yet.")
    }

    static var downloadingDetail: String {
        L10n.string("The Linux components are downloaded once and shared by every host of the same kind.")
    }

    static var unknownHostKey: String {
        L10n.string("This machine isn’t in your known_hosts, and Threading never answers that question for you. Connect once in a terminal with ssh, accept the fingerprint, then check again.")
    }

    static var permissionDenied: String {
        L10n.string("The host refused your key. Check that your ssh key is on it and that your agent is unlocked.")
    }

    static var noSystemd: String {
        L10n.string("This machine has no systemd user session, which Threading needs to keep a host running there.")
    }

    static var unreachableDetail: String {
        L10n.string("Threading couldn’t reach this machine with ssh.")
    }

    static var notPersisted: String {
        L10n.string("The list of hosts couldn’t be written, so the change was not kept.")
    }

    static func unsupportedArchitecture(_ machine: String) -> String {
        L10n.format("Threading has no Linux components for this machine (%@).", machine)
    }

    static func summary(_ count: Int) -> String {
        count == 1 ? L10n.string("1 host") : L10n.format("%lld hosts", count)
    }

    static func downloading(_ fraction: Double) -> String {
        L10n.format("Downloading %lld%%", Int((fraction * 100).rounded()))
    }

    static func duplicate(_ destination: String) -> String {
        L10n.format("Another host already connects to %@.", destination)
    }

    /// The line under the name: what `ssh` connects to, and what runs on it. A machine with no name
    /// of its own is already titled by its destination, so the caption does not say it twice.
    static func caption(_ record: RemoteHostRecord, projects: Int) -> String {
        let named = !record.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let machine = named ? L10n.format("ssh %@", record.destination) : ""
        let use: String
        switch projects {
        case 0: use = ""
        case 1: use = L10n.string("1 project")
        default: use = L10n.format("%lld projects", projects)
        }
        return [machine, use].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static func removeTitle(_ record: RemoteHostRecord) -> String {
        L10n.format("Remove “%@”?", record.displayName)
    }

    static func removeMessage(_ projectNames: [String]) -> String {
        guard !projectNames.isEmpty else {
            return L10n.string("Nothing on this Mac runs on it. Sessions already running on the machine keep running there.")
        }
        return L10n.format(
            "%@ will run on this Mac again. Sessions already running on the machine keep running there, and Threading will no longer reach them.",
            projectNames.joined(separator: ", ")
        )
    }
}

enum RemoteHostsSettingsDefaults {
    static let estimatedRowHeight: CGFloat = 56
    static let cellIdentifier = NSUserInterfaceItemIdentifier("RemoteHostsSettingsCell")
}

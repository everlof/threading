import AppKit

/// A session's live development console. Only the visible pane polls; capture remains in the
/// bounded helper journal while another tab is selected. Rows are reused by the themed table.
@MainActor
final class WebExtensionWorkbenchViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    let sessionID: SessionID
    private var project: URL
    private let service: any WebExtensionServicing
    private let observations = AppEventObservations()
    private var targets: [WebExtensionTarget] = []
    private var runs: [WebExtensionRun] = []
    private var events: [WebExtensionEvent] = []
    private var cursor = 0
    /// The worker that issued `events`' IDs and `cursor`. A restarted worker numbers from 1 again.
    private var workerGeneration: String?
    private var polling: Task<Void, Never>?
    private var operating = false
    private var selectedTarget: String?
    private var filterGeneration = 0
    private var projectGeneration = 0
    private var terminated = false

    private let root = ThemedSurfaceView()
    private let picker = ThemedPopUp()
    private let search = ThemedSearchField()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let configuration = NSTextField(wrappingLabelWithString: "")
    private let table = ThemedTableView()
    private let scroll = ThemedScrollView()
    private let detail = ThemedTextView.scrolling()
    private let startButton = ThemedButton(title: L10n.string("Start"), target: nil, action: nil)
    private let reloadButton = ThemedButton(title: L10n.string("Rebuild & Reload"), target: nil, action: nil)
    private let stopButton = ThemedButton(title: L10n.string("Stop"), target: nil, action: nil)
    private let testButton = ThemedButton(title: L10n.string("Run Tests"), target: nil, action: nil)
    private let actions = ThemedPopUp()
    private let eventCount = NSTextField(labelWithString: "")

    private enum Layout {
        static let initialSize = NSSize(width: 760, height: 660)
        static let rowHeight: CGFloat = 54
        static let detailHeight: CGFloat = 170
        static let maximumRows = 2000
        static let pollNanoseconds: UInt64 = 500_000_000
    }

    init(sessionID: SessionID, project: URL, service: any WebExtensionServicing = WebExtensionDevelopmentService.shared) {
        self.sessionID = sessionID
        self.project = project
        self.service = service
        super.init(nibName: nil, bundle: nil)
        observations.observe(WebExtensionDidChange.self) { [weak self] event in
            guard let self, event.sessionID == sessionID, !operating, !terminated else { return }
            Task { await self.refreshProject() }
        }
        observations.observe(SessionProjectDidChange.self) { [weak self] event in
            guard let self, event.sessionID == sessionID,
                  let directory = ProjectStore.shared.workingDirectory(forSessionID: sessionID) else { return }
            projectGeneration += 1
            self.project = URL(fileURLWithPath: directory)
            operating = false
            runs = []
            targets = []
            resetEvents()
            Task { await self.refreshProject() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        root.frame = NSRect(origin: .zero, size: Layout.initialSize)
        root.applySurface(fill: Design.Surface.ground, radius: .fixed(0), pattern: .backdrop)
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let title = NSTextField(labelWithString: L10n.string("Web Extensions"))
        title.applyFont(.heading)
        title.textColor = Design.Text.label
        status.applyFont(.caption)
        status.textColor = Design.Text.secondary
        status.maximumNumberOfLines = 4
        configuration.applyFont(.code())
        configuration.textColor = Design.Text.secondary
        configuration.maximumNumberOfLines = 3
        picker.setAccessibilityIdentifier("webExtensions.target")
        picker.target = self
        picker.action = #selector(targetChanged)
        search.placeholderString = L10n.string("Search extension events")
        search.setAccessibilityIdentifier("webExtensions.search")
        search.delegate = self
        for (button, selector, identifier) in [
            (startButton, #selector(start), "start"), (reloadButton, #selector(reload), "reload"),
            (stopButton, #selector(stop), "stop"), (testButton, #selector(runTests), "test")
        ] {
            button.target = self
            button.action = selector
            button.setAccessibilityIdentifier("webExtensions." + identifier)
        }
        configureActions()
        let titleRow = NSStackView(views: [title, NSView(), actions])
        titleRow.alignment = .centerY
        let targetRow = NSStackView(views: [picker, NSView(), startButton, stopButton])
        targetRow.alignment = .centerY
        let controls = NSStackView(views: [reloadButton, testButton, NSView()])
        controls.alignment = .centerY
        controls.spacing = Design.Spacing.small
        let header = NSStackView(views: [titleRow, targetRow, controls, configuration, status, search])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = Design.Spacing.medium
        header.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(header)
        for row in [titleRow, targetRow, controls, search] { row.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true }
        configuration.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true
        status.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("event"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        // An edge-to-edge diagnostic list must not also acquire AppKit's automatic inset
        // gutters: each tile would widen the table and trigger another column fit.
        table.style = .plain
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.autoresizingMask = [.width]
        table.rowHeight = Layout.rowHeight
        table.intercellSpacing = .zero
        table.soleColumnFillsBoundsExactly = true
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityIdentifier("webExtensions.events")
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        detail.textView.isEditable = false
        detail.textView.isSelectable = true
        detail.textView.applyFont(.code())
        detail.textView.string = L10n.string("Select an event to inspect its stack and context.")
        let sourceButton = ThemedButton(title: L10n.string("Open Source"), target: self, action: #selector(openSource))
        eventCount.applyFont(.caption)
        eventCount.textColor = Design.Text.secondary
        let footer = NSStackView(views: [sourceButton, NSView(), eventCount])
        for child in [scroll, detail, footer] {
            child.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(child)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: Design.Spacing.large),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Design.Spacing.large),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Design.Spacing.large),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: Design.Spacing.medium),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: detail.topAnchor, constant: -Design.Spacing.small),
            detail.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            detail.heightAnchor.constraint(equalToConstant: Layout.detailHeight),
            detail.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -Design.Spacing.small),
            footer.leadingAnchor.constraint(equalTo: header.leadingAnchor), footer.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Design.Spacing.medium)
        ])
        updateState()
        status.stringValue = L10n.string("Reading extension project…")
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard polling == nil, !terminated else { return }
        polling = Task { [weak self] in
            await self?.refreshProject()
            while !Task.isCancelled {
                await self?.readEvents()
                try? await Task.sleep(nanoseconds: Layout.pollNanoseconds)
            }
        }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        polling?.cancel()
        polling = nil
    }

    func terminate() {
        terminated = true
        projectGeneration += 1
        polling?.cancel()
        polling = nil
        service.release(sessionID)
    }

    private func configureActions() {
        actions.pullsDown = true
        actions.addItem(withTitle: L10n.string("Project"))
        for (title, action) in [("Create Starter Extension", WebExtensionRequest.Action.scaffold),
                                ("Open Browser Debugger", .debug), ("Open Extension Popup", .popup), ("Open Extension Options", .options),
                                ("Install Development Tools", .setup), ("Package Safari", .packageSafari), ("Clear Events", .clear)] {
            actions.addItem(ThemedMenuItem(title: L10n.string(title), onChoose: { [weak self] in self?.perform(action) }))
        }
        actions.addItem(ThemedMenuItem(title: L10n.string("Open Configuration"), onChoose: { [weak self] in
            guard let self else { return }
            _ = ExternalAppLauncher.shared.openInPreferredApp(.file(project.appendingPathComponent(".threading/web-extensions.json"), line: nil))
        }))
        actions.addItem(ThemedMenuItem(title: L10n.string("Show Development Build"), onChoose: { [weak self] in
            guard let self, let run = runs.first(where: { $0.target == self.selectedTarget }) else { return }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: run.directory)])
        }))
        actions.addItem(ThemedMenuItem(title: L10n.string("Refresh Project"), onChoose: { [weak self] in
            Task { await self?.refreshProject() }
        }))
    }

    private func refreshProject() async {
        guard !terminated, !service.isBusy(sessionID) else { return }
        let generation = projectGeneration
        let reply = await service.call(.init(action: .inspect), sessionID: sessionID, project: project)
        guard generation == projectGeneration else { return }
        switch reply {
        case .failure(let message): status.stringValue = message
        case .success(let payload, _):
            adopt(generation: payload.generation)
            targets = payload.targets ?? []
            runs = payload.runs ?? []
            picker.removeAllItems()
            for target in targets { picker.addItem(withTitle: "\(target.id) · \(target.browser)") }
            if let index = targets.firstIndex(where: { $0.id == selectedTarget }) { picker.selectItem(at: index) }
            else { picker.selectItem(at: 0); selectedTarget = targets.first?.id }
            updateState()
        }
    }

    private func updateState() {
        let target = targets.first { $0.id == selectedTarget }
        let run = runs.first { $0.target == selectedTarget }
        configuration.stringValue = target.map { ([$0.source] + ($0.build ?? [])).joined(separator: "  ") }
            ?? L10n.string("Open a manifest project, or choose Project → Create Starter Extension.")
        status.stringValue = run.map { "\($0.status) · \($0.browserVersion ?? $0.browser) · \($0.build)\n\(($0.contexts ?? []).joined(separator: ", "))\n\($0.instructions ?? "")" }
            ?? L10n.string("Development copies report console, JavaScript errors and failed fetches. Browser-internal errors and MAIN-world scripts are not captured.")
        startButton.isEnabled = target != nil && run == nil && !operating
        reloadButton.isEnabled = run != nil && !operating
        stopButton.isEnabled = run != nil && !operating
        testButton.isEnabled = run != nil && !operating
        picker.isEnabled = !operating
        actions.isEnabled = !operating
    }

    private func perform(_ action: WebExtensionRequest.Action) {
        guard !terminated, !operating else { return }
        let generation = projectGeneration
        operating = true
        updateState()
        status.stringValue = L10n.string("Development operation in progress…")
        Task {
            let reply = await service.call(.init(action: action, target: selectedTarget), sessionID: sessionID, project: project)
            guard generation == projectGeneration else { return }
            operating = false
            if action == .clear { resetEvents() }
            await refreshProject()
            switch reply {
            case .failure(let message): status.stringValue = message
            case .success(let payload, let text):
                if let instructions = payload.instructions { status.stringValue = instructions }
                detail.textView.string = text
                if action == .packageSafari, let project = payload.project { NSWorkspace.shared.open(URL(fileURLWithPath: project)) }
            }
            await readEvents()
        }
    }

    private func readEvents() async {
        guard !terminated, !operating, !service.isBusy(sessionID) else { return }
        let generation = filterGeneration
        let request = WebExtensionRequest(action: .events, after: cursor, limit: WebExtensionDefaults.eventPageLimit,
                                          query: search.stringValue)
        guard case .success(let payload, _) = await service.call(request, sessionID: sessionID, project: project),
              generation == filterGeneration, let incoming = payload.events else { return }
        // This page was read with the previous worker's cursor; read the new worker from its start.
        guard !adopt(generation: payload.generation) else { return }
        cursor = payload.cursor ?? cursor
        if let latest = payload.runs, latest != runs { runs = latest; updateState() }
        eventCount.stringValue = String(format: L10n.string("%d retained · %d dropped"), payload.retained ?? events.count + incoming.count,
                                        (payload.dropped ?? 0) + (payload.evicted ?? 0))
        guard !incoming.isEmpty else { return }
        let selectedID = events.indices.contains(table.selectedRow) ? events[table.selectedRow].id : nil
        let follows = table.selectedRow < 0 && scroll.contentView.bounds.maxY >= table.bounds.maxY - Layout.rowHeight
        events.append(contentsOf: incoming)
        if events.count > Layout.maximumRows {
            events.removeFirst(events.count - Layout.maximumRows)
            table.reloadData()
            if let selectedID, let row = events.firstIndex(where: { $0.id == selectedID }) {
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            } else { table.deselectAll(nil) }
        } else { table.noteNumberOfRowsChanged() }
        if follows { table.scrollRowToVisible(events.count - 1) }
    }

    private func resetEvents() {
        filterGeneration += 1
        cursor = 0
        events.removeAll()
        table.reloadData()
    }

    /// Rows from an earlier worker would alias the new worker's IDs, so Open Source could resolve
    /// a stale row to a different event. Returns whether the rows were discarded.
    @discardableResult
    private func adopt(generation: String?) -> Bool {
        guard let generation, generation != workerGeneration else { return false }
        let replaced = workerGeneration != nil
        workerGeneration = generation
        guard replaced else { return false }
        resetEvents()
        detail.textView.string = L10n.string("Select an event to inspect its stack and context.")
        return true
    }

    @objc private func targetChanged() { selectedTarget = targets.indices.contains(picker.indexOfSelectedItem) ? targets[picker.indexOfSelectedItem].id : nil; updateState() }
    @objc private func start() { perform(.start) }
    @objc private func reload() { perform(.reload) }
    @objc private func stop() { perform(.stop) }
    @objc private func runTests() { perform(.test) }
    @objc private func openSource() {
        guard events.indices.contains(table.selectedRow) else { return }
        let event = events[table.selectedRow]
        Task {
            let request = WebExtensionRequest(action: .source, target: event.target, event: event.id, generation: workerGeneration)
            switch await service.call(request, sessionID: sessionID, project: project) {
            case .success(let payload, _):
                if let path = payload.path { _ = ExternalAppLauncher.shared.openInPreferredApp(.file(URL(fileURLWithPath: path), line: payload.line)) }
            case .failure(let message): status.stringValue = message
            }
        }
    }

    func controlTextDidChange(_ notification: Notification) { resetEvents(); Task { await readEvents() } }
    func numberOfRows(in tableView: NSTableView) -> Int { events.count }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard events.indices.contains(table.selectedRow) else { return }
        detail.textView.string = events[table.selectedRow].detail
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("WebExtensionEvent")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? WebExtensionEventCell ?? WebExtensionEventCell()
        cell.identifier = identifier
        cell.configure(events[row])
        return cell
    }
}

private final class WebExtensionEventCell: NSTableCellView, ThemeDerivedContent {
    private let headline = NSTextField(labelWithString: "")
    private let message = NSTextField(labelWithString: "")
    private var isError = false
    override var backgroundStyle: NSView.BackgroundStyle { didSet { rederiveThemedContent() } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        headline.applyFont(.caption)
        message.applyFont(.body)
        for label in [headline, message] { label.lineBreakMode = .byTruncatingTail; addSubview(label) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(_ event: WebExtensionEvent) {
        headline.stringValue = event.summary
        isError = event.level == "error"
        message.stringValue = event.message.replacingOccurrences(of: "\n", with: " ")
        rederiveThemedContent()
        setAccessibilityLabel(event.summary + ": " + event.message)
    }
    func rederiveThemedContent() {
        let selected = backgroundStyle == .emphasized
        headline.textColor = selected ? Design.Text.selected : (isError ? Design.Status.negative : Design.Text.secondary)
        message.textColor = selected ? Design.Text.selected : Design.Text.label
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        rederiveThemedContent()
    }
    override func layout() {
        super.layout()
        let inset = Design.Spacing.medium
        headline.frame = NSRect(x: inset, y: bounds.height / 2, width: max(0, bounds.width - 2 * inset), height: bounds.height / 2 - Design.Spacing.small)
        message.frame = NSRect(x: inset, y: Design.Spacing.small, width: max(0, bounds.width - 2 * inset), height: bounds.height / 2 - Design.Spacing.small)
    }
}

import AppKit

/// The Mac adapter for the host command plane. The controller owns only presentation,
/// filtering and keyboard focus; it never implements a command.
@MainActor
final class CommandPaletteViewController: NSViewController {
    private let catalog: () -> [HostCommandDescriptor]
    private let invoke: (String) -> HostCommandInvocationOutcome
    private let searchField = ThemedSearchField()
    private let tableView = ThemedTableView()
    private var allCommands: [HostCommandDescriptor] = []
    private var visibleCommands: [HostCommandDescriptor] = []
    private var selectedID: String?
    private var filterGeneration = 0
    private var filterTask: Task<Void, Never>?
    nonisolated(unsafe) private var keyMonitor: Any?
    private var presentation: InWindowOverlay.Presentation?
    private let appEvents = AppEventObservations()

    var onDismiss: (() -> Void)?

    init(
        catalog: @escaping () -> [HostCommandDescriptor],
        invoke: @escaping (String) -> HostCommandInvocationOutcome
    ) {
        self.catalog = catalog
        self.invoke = invoke
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        filterTask?.cancel()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        view = root

        let surface = ThemedSurfaceView()
        surface.applySurface(
            fill: Design.Surface.background,
            radius: .panel,
            border: Design.Surface.border
        )
        root.addSubview(surface)

        let heading = NSTextField(labelWithString: L10n.string("Command Palette"))
        heading.applyFont(.heading)
        heading.textColor = Design.Text.label

        searchField.placeholderString = L10n.string("Type a command")
        searchField.setAccessibilityLabel(L10n.string("Command search"))
        searchField.delegate = self

        tableView.dataSource = self
        tableView.delegate = self
        tableView.headerView = nil
        tableView.style = .inset
        tableView.rowHeight = CommandPaletteLayout.rowHeight
        tableView.target = self
        tableView.doubleAction = #selector(confirmSelection)
        tableView.setAccessibilityLabel(L10n.string("Commands"))
        tableView.addTableColumn(NSTableColumn(identifier: CommandPaletteLayout.column))

        let scroll = ThemedScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.applySurface(fill: Design.Surface.panel, radius: .panel, border: Design.Surface.border)

        let hint = NSTextField(
            labelWithString: L10n.string("↑↓ Move   Return Run   Escape Close")
        )
        hint.applyFont(.caption)
        hint.textColor = Design.Text.tertiary

        let stack = NSStackView(views: [heading, searchField, scroll, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.medium
        stack.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(stack)

        NSLayoutConstraint.activate([
            surface.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            surface.topAnchor.constraint(equalTo: root.topAnchor, constant: Design.Spacing.pane),
            surface.widthAnchor.constraint(equalToConstant: CommandPaletteLayout.width),
            surface.heightAnchor.constraint(lessThanOrEqualTo: root.heightAnchor, constant: -2 * Design.Spacing.pane),
            stack.topAnchor.constraint(equalTo: surface.topAnchor, constant: Design.Spacing.pane),
            stack.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -Design.Spacing.pane),
            stack.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: Design.Spacing.pane),
            stack.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -Design.Spacing.pane),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: CommandPaletteLayout.listHeight),
            searchField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            hint.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        appEvents.observe(CommandRegistryDidChange.self) { [weak self] _ in
            self?.reloadCatalog()
        }
        reloadCatalog()
    }

    func present(in window: NSWindow) {
        _ = view
        presentation = InWindowOverlay.install(view, in: window) { [weak self] in
            self?.dismiss()
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak window] event in
            guard let self, event.window === window else { return event }
            return self.handleKey(event) ? nil : event
        }
        window.makeFirstResponder(searchField)
    }

    func dismiss() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        presentation?.remove()
        presentation = nil
        onDismiss?()
    }

    private func reloadCatalog() {
        allCommands = catalog()
        applySearch()
    }

    private func applySearch() {
        filterTask?.cancel()
        filterGeneration += 1
        let generation = filterGeneration
        let commands = allCommands
        let query = searchField.stringValue
        filterTask = Task.detached(priority: .userInitiated) { [self] in
            let results = HostCommandSearch.results(in: commands, matching: query)
            guard !Task.isCancelled else { return }
            await finishSearch(results, generation: generation)
        }
    }

    private func finishSearch(
        _ results: [HostCommandDescriptor],
        generation: Int
    ) {
        guard generation == filterGeneration else { return }
        visibleCommands = results
        if selectedID.map({ id in results.contains { $0.id == id } }) != true {
            selectedID = results.first?.id
        }
        tableView.reloadData()
        restoreSelection()
    }

    private func restoreSelection() {
        guard let selectedID,
              let row = visibleCommands.firstIndex(where: { $0.id == selectedID }) else {
            tableView.deselectAll(nil)
            return
        }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53:
            dismiss()
            return true
        case 125:
            moveSelection(by: 1)
            return true
        case 126:
            moveSelection(by: -1)
            return true
        case 36, 76:
            confirmSelection()
            return true
        default:
            return false
        }
    }

    private func moveSelection(by offset: Int) {
        guard !visibleCommands.isEmpty else { return }
        let current = selectedID.flatMap { id in visibleCommands.firstIndex { $0.id == id } } ?? 0
        let next = min(max(current + offset, 0), visibleCommands.count - 1)
        selectedID = visibleCommands[next].id
        restoreSelection()
    }

    @objc private func confirmSelection() {
        guard let selectedID,
              let command = visibleCommands.first(where: { $0.id == selectedID }),
              command.availability.isAvailable else {
            NSSound.beep()
            return
        }
        switch invoke(command.id) {
        case .invoked:
            dismiss()
        case .refused:
            NSSound.beep()
            reloadCatalog()
        }
    }

    private func makeRow(_ command: HostCommandDescriptor) -> NSView {
        let title = NSTextField(labelWithString: command.title)
        title.applyFont(.body)
        title.textColor = command.availability.isAvailable ? Design.Text.label : Design.Text.tertiary
        title.lineBreakMode = .byTruncatingTail

        let detailText = command.availability.disabledReason ?? command.detail ?? originTitle(command.origin)
        let detail = NSTextField(labelWithString: detailText)
        detail.applyFont(.caption)
        detail.textColor = Design.Text.tertiary
        detail.lineBreakMode = .byTruncatingTail

        let labels = NSStackView(views: [title, detail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = Design.Spacing.hairline
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let shortcut = NSTextField(labelWithString: command.shortcut ?? "")
        shortcut.applyFont(.code())
        shortcut.textColor = Design.Text.secondary
        shortcut.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView(views: [labels, shortcut])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Design.Spacing.medium
        row.edgeInsets = NSEdgeInsets(
            top: Design.Spacing.small,
            left: Design.Spacing.small,
            bottom: Design.Spacing.small,
            right: Design.Spacing.small
        )
        row.setAccessibilityElement(true)
        row.setAccessibilityLabel(command.title)
        if let reason = command.availability.disabledReason {
            row.setAccessibilityHelp(reason)
        }
        return row
    }

    private func originTitle(_ origin: HostCommandDescriptor.Origin) -> String {
        switch origin {
        case .builtIn: return L10n.string("Threading")
        case .extensionCommand(_, let name, _): return name
        }
    }

    // Test seams exercise the exact keyboard state machine without synthesizing a global event.
    var visibleCommandIDsForTesting: [String] { visibleCommands.map(\.id) }
    var selectedCommandIDForTesting: String? { selectedID }
    func setSearchQueryForTesting(_ query: String) {
        searchField.stringValue = query
        applySearch()
    }
    func moveSelectionForTesting(by offset: Int) { moveSelection(by: offset) }
    func confirmSelectionForTesting() { confirmSelection() }
}

extension CommandPaletteViewController: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) { applySearch() }
}

extension CommandPaletteViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { visibleCommands.count }
}

extension CommandPaletteViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard visibleCommands.indices.contains(row) else { return nil }
        return makeRow(visibleCommands[row])
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        selectedID = visibleCommands.indices.contains(row) ? visibleCommands[row].id : nil
    }
}

@MainActor
private enum CommandPaletteLayout {
    static let width: CGFloat = 620
    static let listHeight: CGFloat = 330
    static let rowHeight: CGFloat = 52
    static let column = NSUserInterfaceItemIdentifier("CommandPaletteColumn")
}

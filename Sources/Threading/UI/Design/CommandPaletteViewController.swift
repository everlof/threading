import AppKit

/// The Mac-only bridge from a command id to the shortcut store. Command invocation remains in
/// the frontend-neutral host plane; this adapter gives the palette the same edit operation the
/// Keyboard settings page already uses without importing AppKit key events into that contract.
@MainActor
struct CommandPaletteShortcutEditing {
    let shortcut: (String) -> KeyboardShortcut?
    /// Returns an inline refusal when the chord is already owned by another command.
    let record: (String, KeyboardShortcut?) -> String?
}

/// The Mac adapter for the host command plane. The controller owns only presentation,
/// filtering, input collection and keyboard focus; it never implements a command.
@MainActor
final class CommandPaletteViewController: NSViewController {
    private enum Step: Equatable {
        case commands
        case input(commandID: String, request: HostCommandInputRequest)
    }

    private let catalog: () -> [HostCommandDescriptor]
    private let inputOptions: (String) -> [HostCommandInputOption]
    private let invokeRequest: (HostCommandInvocationRequest) -> HostCommandInvocationOutcome
    private let shortcutEditing: CommandPaletteShortcutEditing?
    private let heading = NSTextField(labelWithString: L10n.string("Command Palette"))
    private let searchField = ThemedSearchField()
    private let tableView = ThemedTableView()
    private let leadingHint = NSTextField(labelWithString: "")
    private let trailingHint = NSTextField(labelWithString: "")
    private var allCommands: [HostCommandDescriptor] = []
    private var visibleCommands: [HostCommandDescriptor] = []
    private var allInputOptions: [HostCommandInputOption] = []
    private var visibleInputOptions: [HostCommandInputOption] = []
    private var selectedCommandID: String?
    private var selectedInputID: String?
    private var commandQuery = ""
    private var step = Step.commands
    private var shortcutConflictByCommandID: [String: String] = [:]
    private var shortcutRecordersByCommandID: [String: ShortcutRecorderView] = [:]
    private weak var activeShortcutRecorder: ShortcutRecorderView?
    private var filterGeneration = 0
    private var filterTask: Task<Void, Never>?
    private var preferredListHeightConstraint: NSLayoutConstraint?
    private weak var paletteSurface: NSView?
    nonisolated(unsafe) private var keyMonitor: Any?
    private var presentation: InWindowOverlay.Presentation?
    private weak var presentationWindow: NSWindow?
    private let appEvents = AppEventObservations()

    var onDismiss: (() -> Void)?

    init(
        catalog: @escaping () -> [HostCommandDescriptor],
        invoke: @escaping (String) -> HostCommandInvocationOutcome
    ) {
        self.catalog = catalog
        self.inputOptions = { _ in [] }
        self.invokeRequest = { invoke($0.commandID) }
        self.shortcutEditing = nil
        super.init(nibName: nil, bundle: nil)
    }

    init(
        catalog: @escaping () -> [HostCommandDescriptor],
        inputOptions: @escaping (String) -> [HostCommandInputOption],
        invokeRequest: @escaping (HostCommandInvocationRequest) -> HostCommandInvocationOutcome,
        shortcutEditing: CommandPaletteShortcutEditing?
    ) {
        self.catalog = catalog
        self.inputOptions = inputOptions
        self.invokeRequest = invokeRequest
        self.shortcutEditing = shortcutEditing
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
        paletteSurface = surface
        surface.applySurface(
            fill: Design.Surface.background,
            radius: .panel,
            border: Design.Surface.border
        )
        root.addSubview(surface)

        heading.applyFont(.heading)
        heading.textColor = Design.Text.label
        heading.lineBreakMode = .byTruncatingTail

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

        let footer = makeFooter()
        let stack = NSStackView(views: [heading, searchField, scroll, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.medium
        stack.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(stack)

        let preferredWidth = surface.widthAnchor.constraint(equalToConstant: CommandPaletteLayout.width)
        preferredWidth.priority = .init(CommandPaletteLayout.preferredConstraintPriority)
        let preferredListHeight = scroll.heightAnchor.constraint(
            equalToConstant: CommandPaletteLayout.listHeight
        )
        preferredListHeight.priority = .init(CommandPaletteLayout.preferredConstraintPriority)
        preferredListHeightConstraint = preferredListHeight

        NSLayoutConstraint.activate([
            surface.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            surface.topAnchor.constraint(equalTo: root.topAnchor, constant: Design.Spacing.pane),
            surface.bottomAnchor.constraint(
                lessThanOrEqualTo: root.bottomAnchor,
                constant: -Design.Spacing.pane
            ),
            surface.leadingAnchor.constraint(
                greaterThanOrEqualTo: root.leadingAnchor,
                constant: Design.Spacing.pane
            ),
            surface.trailingAnchor.constraint(
                lessThanOrEqualTo: root.trailingAnchor,
                constant: -Design.Spacing.pane
            ),
            surface.widthAnchor.constraint(lessThanOrEqualToConstant: CommandPaletteLayout.width),
            preferredWidth,
            stack.topAnchor.constraint(equalTo: surface.topAnchor, constant: Design.Spacing.pane),
            stack.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -Design.Spacing.pane),
            stack.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: Design.Spacing.pane),
            stack.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -Design.Spacing.pane),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(
                greaterThanOrEqualToConstant: CommandPaletteLayout.minimumListHeight
            ),
            preferredListHeight,
            searchField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        appEvents.observe(CommandRegistryDidChange.self) { [weak self] _ in
            self?.reloadCatalog()
        }
        appEvents.observe(KeyboardShortcutsDidChange.self) { [weak self] _ in
            self?.reloadCatalog()
        }
        reloadCatalog()
    }

    func present(in window: NSWindow) {
        _ = view
        presentationWindow = window
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
        removePresentation()
        presentationWindow = nil
        onDismiss?()
    }

    private func removePresentation() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        presentation?.remove()
        presentation = nil
    }

    private func makeFooter() -> NSView {
        for label in [leadingHint, trailingHint] {
            label.applyFont(.caption)
            label.textColor = Design.Text.tertiary
            label.lineBreakMode = .byTruncatingTail
        }
        trailingHint.alignment = .right

        let footer = NSView()
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(leadingHint)
        footer.addSubview(trailingHint)
        leadingHint.translatesAutoresizingMaskIntoConstraints = false
        trailingHint.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            leadingHint.topAnchor.constraint(equalTo: footer.topAnchor),
            leadingHint.bottomAnchor.constraint(equalTo: footer.bottomAnchor),
            leadingHint.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            trailingHint.topAnchor.constraint(equalTo: footer.topAnchor),
            trailingHint.bottomAnchor.constraint(equalTo: footer.bottomAnchor),
            trailingHint.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            trailingHint.leadingAnchor.constraint(
                greaterThanOrEqualTo: leadingHint.trailingAnchor,
                constant: Design.Spacing.medium
            ),
        ])
        updateHints()
        return footer
    }

    private func reloadCatalog() {
        allCommands = catalog()
        if case .input(let commandID, _) = step,
           !allCommands.contains(where: { $0.id == commandID }) {
            returnToCommands()
            return
        }
        applySearch()
    }

    private func applySearch() {
        filterTask?.cancel()
        filterGeneration += 1
        let generation = filterGeneration
        let query = searchField.stringValue

        switch step {
        case .commands:
            let commands = allCommands
            filterTask = Task.detached(priority: .userInitiated) { [self] in
                let results = HostCommandSearch.results(in: commands, matching: query)
                guard !Task.isCancelled else { return }
                await finishCommandSearch(results, generation: generation)
            }
        case .input:
            let options = allInputOptions
            filterTask = Task.detached(priority: .userInitiated) { [self] in
                let results = HostCommandInputSearch.results(in: options, matching: query)
                guard !Task.isCancelled else { return }
                await finishInputSearch(results, generation: generation)
            }
        }
    }

    private func finishCommandSearch(
        _ results: [HostCommandDescriptor],
        generation: Int
    ) {
        guard generation == filterGeneration, step == .commands else { return }
        visibleCommands = results
        if selectedCommandID.map({ id in results.contains { $0.id == id } }) != true {
            selectedCommandID = results.first?.id
        }
        reloadTableAndRestoreSelection()
    }

    private func finishInputSearch(
        _ results: [HostCommandInputOption],
        generation: Int
    ) {
        guard generation == filterGeneration,
              case .input = step else { return }
        visibleInputOptions = results
        if selectedInputID.map({ id in results.contains { $0.id == id } }) != true {
            selectedInputID = results.first?.id
        }
        reloadTableAndRestoreSelection()
    }

    private func reloadTableAndRestoreSelection() {
        shortcutRecordersByCommandID.removeAll()
        let resultCount: Int
        switch step {
        case .commands: resultCount = visibleCommands.count
        case .input: resultCount = visibleInputOptions.count
        }
        preferredListHeightConstraint?.constant = CommandPaletteLayout.listHeight(
            forResultCount: resultCount
        )
        tableView.reloadData()
        restoreSelection()
        updateHints()
    }

    private func restoreSelection() {
        let row: Int?
        switch step {
        case .commands:
            row = selectedCommandID.flatMap { id in visibleCommands.firstIndex { $0.id == id } }
        case .input:
            row = selectedInputID.flatMap { id in visibleInputOptions.firstIndex { $0.id == id } }
        }
        guard let row else {
            tableView.deselectAll(nil)
            return
        }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        if activeShortcutRecorder?.isRecording == true { return false }

        switch event.keyCode {
        case CommandPaletteKeys.escape:
            if case .input = step {
                returnToCommands()
            } else {
                dismiss()
            }
            return true
        case CommandPaletteKeys.downArrow:
            moveSelection(by: 1)
            return true
        case CommandPaletteKeys.upArrow:
            moveSelection(by: -1)
            return true
        case CommandPaletteKeys.tab:
            guard case .commands = step,
                  selectedCommand?.nextInput != nil else { return false }
            confirmSelection()
            return true
        case CommandPaletteKeys.returnKey, CommandPaletteKeys.keypadEnter:
            confirmSelection()
            return true
        default:
            return false
        }
    }

    private func moveSelection(by offset: Int) {
        let count: Int
        let current: Int
        switch step {
        case .commands:
            count = visibleCommands.count
            current = selectedCommandID.flatMap { id in
                visibleCommands.firstIndex { $0.id == id }
            } ?? 0
        case .input:
            count = visibleInputOptions.count
            current = selectedInputID.flatMap { id in
                visibleInputOptions.firstIndex { $0.id == id }
            } ?? 0
        }
        guard count > 0 else { return }
        let next = min(max(current + offset, 0), count - 1)
        switch step {
        case .commands: selectedCommandID = visibleCommands[next].id
        case .input: selectedInputID = visibleInputOptions[next].id
        }
        restoreSelection()
        updateHints()
    }

    private var selectedCommand: HostCommandDescriptor? {
        guard let selectedCommandID else { return nil }
        return visibleCommands.first { $0.id == selectedCommandID }
    }

    @objc private func confirmSelection() {
        switch step {
        case .commands:
            guard let command = selectedCommand else {
                SystemAlert.refuse()
                return
            }
            if let request = command.nextInput {
                beginInput(for: command, request: request)
                return
            }
            guard command.availability.isAvailable else {
                SystemAlert.refuse()
                return
            }
            invoke(HostCommandInvocationRequest(commandID: command.id))

        case .input(let commandID, let request):
            guard let selectedInputID,
                  visibleInputOptions.contains(where: { $0.id == selectedInputID }) else {
                SystemAlert.refuse()
                return
            }
            invoke(HostCommandInvocationRequest(
                commandID: commandID,
                input: HostCommandInputValue(kind: request.kind, id: selectedInputID)
            ))
        }
    }

    private func beginInput(
        for command: HostCommandDescriptor,
        request: HostCommandInputRequest
    ) {
        commandQuery = searchField.stringValue
        allInputOptions = inputOptions(command.id)
        visibleInputOptions = []
        selectedInputID = nil
        step = .input(commandID: command.id, request: request)
        heading.stringValue = command.title
        searchField.stringValue = ""
        searchField.placeholderString = request.searchPlaceholder
        searchField.setAccessibilityLabel(request.prompt)
        tableView.setAccessibilityLabel(request.prompt)
        applySearch()
    }

    private func returnToCommands() {
        filterTask?.cancel()
        step = .commands
        allInputOptions = []
        visibleInputOptions = []
        selectedInputID = nil
        heading.stringValue = L10n.string("Command Palette")
        searchField.stringValue = commandQuery
        searchField.placeholderString = L10n.string("Type a command")
        searchField.setAccessibilityLabel(L10n.string("Command search"))
        tableView.setAccessibilityLabel(L10n.string("Commands"))
        applySearch()
    }

    private func invoke(_ request: HostCommandInvocationRequest) {
        // Commands may synchronously present their own sheet, popover or overlay. Remove the
        // palette first so two modal surfaces never compete, while retaining this controller
        // until the invocation outcome tells us whether a dynamic refusal needs restoration.
        let window = presentationWindow
        removePresentation()
        switch invokeRequest(request) {
        case .invoked:
            presentationWindow = nil
            onDismiss?()
        case .refused:
            SystemAlert.refuse()
            reloadCatalog()
            if let window { present(in: window) }
        }
    }

    private func updateHints() {
        if activeShortcutRecorder?.isRecording == true {
            leadingHint.stringValue = L10n.string("Press shortcut   Delete Clear   Escape Cancel")
            trailingHint.stringValue = ""
            return
        }

        switch step {
        case .commands:
            if selectedCommand?.nextInput?.kind == .session {
                leadingHint.stringValue = L10n.string(
                    "↑↓ Move   Tab or Return Choose Session   Escape Close"
                )
            } else {
                leadingHint.stringValue = L10n.string("↑↓ Move   Return Run   Escape Close")
            }
            trailingHint.stringValue = shortcutEditing == nil
                ? ""
                : L10n.string("Click shortcut to edit")
        case .input:
            leadingHint.stringValue = L10n.string("↑↓ Move   Return Run   Escape Back")
            trailingHint.stringValue = ""
        }
    }

    private func makeCommandRow(_ command: HostCommandDescriptor) -> NSView {
        let canProceed = command.availability.isAvailable || command.nextInput != nil
        let detailText = shortcutConflictByCommandID[command.id]
            ?? command.nextInput?.prompt
            ?? command.availability.disabledReason
            ?? command.detail
            ?? originTitle(command.origin)

        let accessory: NSView?
        if command.shortcutEditable, let shortcutEditing {
            let recorder = ShortcutRecorderView(
                shortcut: shortcutEditing.shortcut(command.id),
                presentation: .inline
            )
            recorder.setAccessibilityIdentifier("commandPalette.shortcut.\(command.id)")
            recorder.conflictText = shortcutConflictByCommandID[command.id]
            recorder.onRecordingChange = { [weak self, weak recorder] recording in
                guard let self else { return }
                if recording {
                    self.activeShortcutRecorder = recorder
                    self.selectedCommandID = command.id
                    self.restoreSelection()
                } else if self.activeShortcutRecorder === recorder {
                    self.activeShortcutRecorder = nil
                }
                self.updateHints()
            }
            recorder.onRecord = { [weak self] shortcut in
                guard let self else { return }
                if let refusal = shortcutEditing.record(command.id, shortcut) {
                    self.shortcutConflictByCommandID[command.id] = refusal
                } else {
                    self.shortcutConflictByCommandID.removeValue(forKey: command.id)
                }
                self.reloadCatalog()
            }
            shortcutRecordersByCommandID[command.id] = recorder
            accessory = recorder
        } else if let shortcut = command.shortcut {
            let label = NSTextField(labelWithString: shortcut)
            label.applyFont(.code())
            label.textColor = Design.Text.secondary
            label.alignment = .right
            accessory = label
        } else {
            accessory = nil
        }

        return CommandPaletteRowView(
            title: command.title,
            detail: detailText,
            isEnabled: canProceed,
            accessory: accessory
        )
    }

    private func makeInputRow(_ option: HostCommandInputOption) -> NSView {
        CommandPaletteRowView(
            title: option.title,
            detail: option.detail,
            isEnabled: true,
            accessory: nil
        )
    }

    private func originTitle(_ origin: HostCommandDescriptor.Origin) -> String {
        switch origin {
        case .builtIn: return L10n.string("Threading")
        case .extensionCommand(_, let name, _): return name
        case .projectScript: return L10n.string("Project Scripts")
        }
    }

    // Test seams exercise the exact keyboard state machine without synthesizing a global event.
    var isPresentedForTesting: Bool { presentation != nil }
    var paletteSurfaceSizeForTesting: NSSize? { paletteSurface?.frame.size }
    var visibleCommandIDsForTesting: [String] { visibleCommands.map(\.id) }
    var selectedCommandIDForTesting: String? { selectedCommandID }
    var isCollectingInputForTesting: Bool {
        if case .input = step { return true }
        return false
    }
    var visibleInputIDsForTesting: [String] { visibleInputOptions.map(\.id) }
    var selectedInputIDForTesting: String? { selectedInputID }
    func shortcutRecorderForTesting(commandID: String) -> ShortcutRecorderView? {
        shortcutRecordersByCommandID[commandID]
    }
    func setSearchQueryForTesting(_ query: String) {
        searchField.stringValue = query
        applySearch()
    }
    func moveSelectionForTesting(by offset: Int) { moveSelection(by: offset) }
    func confirmSelectionForTesting() { confirmSelection() }
    func returnToCommandsForTesting() { returnToCommands() }
}

extension CommandPaletteViewController: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) { applySearch() }
}

extension CommandPaletteViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        switch step {
        case .commands: visibleCommands.count
        case .input: visibleInputOptions.count
        }
    }
}

extension CommandPaletteViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch step {
        case .commands:
            guard visibleCommands.indices.contains(row) else { return nil }
            return makeCommandRow(visibleCommands[row])
        case .input:
            guard visibleInputOptions.indices.contains(row) else { return nil }
            return makeInputRow(visibleInputOptions[row])
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        switch step {
        case .commands:
            selectedCommandID = visibleCommands.indices.contains(row) ? visibleCommands[row].id : nil
        case .input:
            selectedInputID = visibleInputOptions.indices.contains(row) ? visibleInputOptions[row].id : nil
        }
        updateHints()
    }
}

@MainActor
private final class CommandPaletteRowView: NSView {
    init(title: String, detail: String?, isEnabled: Bool, accessory: NSView?) {
        super.init(frame: .zero)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.applyFont(.body)
        titleLabel.textColor = isEnabled ? Design.Text.label : Design.Text.tertiary
        titleLabel.lineBreakMode = .byTruncatingTail

        let detailLabel = NSTextField(labelWithString: detail ?? "")
        detailLabel.applyFont(.caption)
        detailLabel.textColor = Design.Text.tertiary
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.isHidden = detail == nil

        let labels = NSStackView(views: [titleLabel, detailLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = Design.Spacing.hairline
        labels.translatesAutoresizingMaskIntoConstraints = false
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(labels)

        var constraints = [
            labels.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Design.Spacing.small),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
        ]
        if let accessory {
            accessory.translatesAutoresizingMaskIntoConstraints = false
            addSubview(accessory)
            constraints += [
                accessory.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Design.Spacing.small),
                accessory.centerYAnchor.constraint(equalTo: centerYAnchor),
                labels.trailingAnchor.constraint(
                    lessThanOrEqualTo: accessory.leadingAnchor,
                    constant: -Design.Spacing.medium
                ),
            ]
        } else {
            constraints.append(
                labels.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Design.Spacing.small)
            )
        }
        NSLayoutConstraint.activate(constraints)

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(title)
        if let detail { setAccessibilityHelp(detail) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor
private enum CommandPaletteLayout {
    static let width: CGFloat = 620
    static let rowHeight: CGFloat = 46
    static let minimumRows = 2
    static let maximumRows = 6
    /// Inset-style AppKit tables reserve ten points above their first row. The remaining two
    /// points keep the scroll-view border from clipping the last row at compact heights.
    static let listChromeHeight: CGFloat = 12
    static let listHeight = listHeight(forResultCount: maximumRows)
    static let minimumListHeight = listHeight(forResultCount: minimumRows)
    static let preferredConstraintPriority: Float = 999
    static let column = NSUserInterfaceItemIdentifier("CommandPaletteColumn")

    static func listHeight(forResultCount resultCount: Int) -> CGFloat {
        let rowCount = min(max(resultCount, minimumRows), maximumRows)
        return CGFloat(rowCount) * rowHeight + listChromeHeight
    }
}

private enum CommandPaletteKeys {
    static let returnKey: UInt16 = 36
    static let tab: UInt16 = 48
    static let escape: UInt16 = 53
    static let keypadEnter: UInt16 = 76
    static let downArrow: UInt16 = 125
    static let upArrow: UInt16 = 126
}

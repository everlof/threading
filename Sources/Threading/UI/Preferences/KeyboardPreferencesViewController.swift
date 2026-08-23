import AppKit

/// The Keyboard page: every command the menu bar offers, and the chord it answers to.
///
/// It lists the fixed commands alongside the editable ones on purpose. Most of why a shortcuts
/// page gets opened is "what is this key already doing" — a page that showed only what it would
/// let you change could not answer that, and would make a conflict with ⌘Q look like a free slot.
final class KeyboardPreferencesViewController: NSViewController {

    private enum PresentationRow {
        case note
        case composer
        case group(Int)
        case command(group: Int, command: Int)
        case reset
    }

    // MARK: - Properties

    private let store: ShortcutOverrideStore
    private let registry: CommandRegistry
    private let appEvents = AppEventObservations()

    /// The complete command inventory is cheap value state. Extensions and project scripts are
    /// provider-sized, so their recorder controls belong only to the AppKit viewport.
    private var groups: [(group: AppCommand.Group, commands: [AppCommand])] = []
    private var presentationRows: [PresentationRow] = []

    /// The command groups whose shortcut rows are unfolded, by group name. A view state,
    /// kept for the session only.
    private var expandedGroups: Set<String> = []

    /// The Return-key choice. Held across cell reuse rather than rebuilt with the rest of its
    /// fixed row: it is the one control here that is not a chord recorder, and re-adding the same
    /// pop-up keeps its open menu and selection from being torn out underneath a click.
    private lazy var returnKeyPopUp = SettingsUI.popUp(
        target: self,
        action: #selector(returnKeyChanged)
    )

    /// The line under that row, which names the chord the choice leaves behind. Re-captured when
    /// its fixed row materializes because the row builds a fresh label each time.
    private var returnKeyDetail: NSTextField?

    private lazy var tableView: ThemedGroupedTableView = {
        let table = ThemedGroupedTableView()
        let column = NSTableColumn(
            identifier: NSUserInterfaceItemIdentifier("KeyboardSettingsContent")
        )
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.selectionHighlightStyle = .none
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.intercellSpacing = .zero
        table.rowHeight = KeyboardPreferencesLayout.estimatedRowHeight
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

    init(
        registry: CommandRegistry = .shared,
        store: ShortcutOverrideStore? = nil
    ) {
        self.registry = registry
        self.store = store ?? .shared
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
        let page = SettingsUI.listPage(title: "Keyboard", body: scrollView)
        page.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(page)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: view.topAnchor),
            page.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            page.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        reload()
        appEvents.observe(CommandRegistryDidChange.self) { [weak self] _ in
            self?.reload()
        }
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

    // MARK: - Building

    private func reload() {
        groups = registry.grouped()
        expandedGroups.formIntersection(Set(groups.map { $0.group.rawValue }))
        reloadPresentationRows()
    }

    /// Opening a fold inserts command coordinates, not controls. A shortcut change can affect a
    /// conflict subtitle anywhere in the inventory, so reloading the value projection is still
    /// correct; the fixed scroll owner and viewport survive it.
    private func reloadPresentationRows() {
        var rows: [PresentationRow] = [.note, .composer]
        for (groupIndex, entry) in groups.enumerated() {
            rows.append(.group(groupIndex))
            guard expandedGroups.contains(entry.group.rawValue) else { continue }
            rows.append(contentsOf: entry.commands.indices.map {
                .command(group: groupIndex, command: $0)
            })
        }
        rows.append(.reset)
        presentationRows = rows
        updateCardDecorations()
        tableView.reloadData()
    }

    private func shortcutCount(_ count: Int) -> String {
        count == 1
            ? L10n.string("1 shortcut")
            : L10n.format("%lld shortcuts", Int64(count))
    }

    private func makeRow(_ command: AppCommand) -> NSView {
        let shortcut = store.shortcut(for: command)

        guard command.isEditable else {
            // A plain label, not a disabled recorder: a dimmed control still invites a click,
            // and these can never be clicked to any effect.
            let label = NSTextField(labelWithString: shortcut?.displayString ?? ShortcutRecorderStrings.unbound)
            label.applyFont(.code())
            label.textColor = Design.Text.tertiary
            return SettingsUI.row(title: rowTitle(command), subtitle: nil, control: label)
        }

        let recorder = ShortcutRecorderView(shortcut: shortcut)
        recorder.onRecord = { [weak self] captured in
            self?.record(captured, for: command)
        }

        return SettingsUI.row(
            title: rowTitle(command),
            subtitle: subtitle(for: command, shortcut: shortcut),
            control: recorder
        )
    }

    /// Return sits on this page rather than among the command chords because it is not one: it
    /// is never unbound, never in conflict, and belongs to a field rather than to the menu bar.
    /// It is here all the same, because "what is this key already doing" is what brings people
    /// to a shortcuts page, and Return is the key they are most often asking about.
    private func makeReturnKeyRow() -> NSView {
        returnKeyPopUp.removeAllItems()
        for value in PromptReturnKey.allCases {
            returnKeyPopUp.addItem(
                ThemedMenuItem(title: value.settingsTitle, representedValue: value)
            )
        }
        returnKeyPopUp.selectItem(
            at: PromptReturnKey.allCases.firstIndex(of: AppSettings.promptReturnKey) ?? 0
        )

        var detail: NSTextField?
        let row = SettingsUI.row(
            title: Strings.returnKeyTitle,
            subtitle: AppSettings.promptReturnKey.settingsDetail,
            control: returnKeyPopUp,
            subtitleField: &detail,
            // The detail is already localised by `PromptReturnKey`, and a second pass would ask
            // the catalogue for a *translated* string as if it were a source key.
            localizes: false
        )
        returnKeyDetail = detail
        return row
    }

    private func rowTitle(_ command: AppCommand) -> String {
        guard let extensionName = command.origin.extensionName else { return command.title }
        return "\(extensionName) — \(command.title)"
    }

    /// The row's second line carries the two things that are not visible in the chord itself:
    /// that it collides with something, and that it is no longer the default.
    private func subtitle(for command: AppCommand, shortcut: KeyboardShortcut?) -> String? {
        if let shortcut, let other = store.conflict(for: shortcut, excluding: command) {
            return L10n.format(Strings.conflictFormat, other.title)
        }
        if let fallback = command.defaultShortcut,
           let other = store.defaultConflict(for: command) {
            return L10n.format(
                Strings.defaultConflictFormat,
                fallback.displayString,
                other.title
            )
        }
        guard store.isOverridden(command) else { return nil }

        guard let fallback = command.defaultShortcut else { return Strings.changedNoDefault }
        return L10n.format(Strings.changedFormat, fallback.displayString)
    }

    // MARK: - Actions

    /// A chord already spoken for is refused rather than taken.
    ///
    /// Stealing it would be the other reasonable design, and is worse here: the command that lost
    /// its shortcut is somewhere else on a long page, so the user would be told nothing and would
    /// discover it the next time they reached for the key that no longer works.
    private func record(_ shortcut: KeyboardShortcut?, for command: AppCommand) {
        if let shortcut, let other = store.conflict(for: shortcut, excluding: command) {
            presentConflict(shortcut, taken: other)
            reloadPresentationRows()
            return
        }

        store.setShortcut(shortcut, for: command)
        reloadPresentationRows()
    }

    private func presentConflict(_ shortcut: KeyboardShortcut, taken other: AppCommand) {
        let alert = ThemedAlert()
        alert.messageText = L10n.format(Strings.conflictTitle, shortcut.displayString)
        alert.informativeText = L10n.format(Strings.conflictBody, other.title)
        alert.alertStyle = .warning
        alert.runModal()
    }

    /// Updates the line in place rather than rebuilding the page: the whole point of the detail
    /// is to answer "then how do I get the other one", and it has to be readable in the moment
    /// the choice is made, not after the row it belongs to has been replaced under the pointer.
    @objc private func returnKeyChanged() {
        guard let value = returnKeyPopUp.selectedItem?.representedValue as? PromptReturnKey else {
            return
        }
        AppSettings.shared.promptReturnKey = value
        returnKeyDetail?.stringValue = value.settingsDetail
    }

    @objc private func resetAllClicked() {
        store.resetAll()
        reloadPresentationRows()
    }
}

// MARK: - Virtual Rows

extension KeyboardPreferencesViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in _: NSTableView) -> Int {
        presentationRows.count
    }

    func tableView(_: NSTableView, shouldSelectRow _: Int) -> Bool {
        false
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor _: NSTableColumn?,
        row tableRow: Int
    ) -> NSView? {
        guard presentationRows.indices.contains(tableRow) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("KeyboardSettingsVirtualRow")
        let host = tableView.makeView(
            withIdentifier: identifier,
            owner: self
        ) as? ThemedVirtualTableCell ?? ThemedVirtualTableCell()
        host.identifier = identifier
        host.install(
            content(for: presentationRows[tableRow]),
            columnWidth: tableView.tableColumns.first?.width ?? tableView.bounds.width,
            horizontalInset: Design.Size.glowGutter,
            topInset: topInset(forRowAt: tableRow),
            bottomInset: tableRow == presentationRows.count - 1 ? Design.Spacing.large : 0
        )
        return host
    }

    private func content(for row: PresentationRow) -> NSView {
        switch row {
        case .note:
            return SettingsUI.note(Strings.note)
        case .composer:
            return SettingsUI.section(
                Strings.composerSection,
                SettingsCard(rows: [makeReturnKeyRow()])
            )
        case .group(let groupIndex):
            guard groups.indices.contains(groupIndex) else { return NSView() }
            let entry = groups[groupIndex]
            let key = entry.group.rawValue
            return SettingsUI.disclosureHeader(
                title: key,
                summary: shortcutCount(entry.commands.count),
                isExpanded: expandedGroups.contains(key),
                onToggle: { [weak self] expanded in
                    self?.setGroup(key, expanded: expanded)
                }
            )
        case .command(let groupIndex, let commandIndex):
            guard groups.indices.contains(groupIndex),
                  groups[groupIndex].commands.indices.contains(commandIndex) else {
                return NSView()
            }
            return makeRow(groups[groupIndex].commands[commandIndex])
        case .reset:
            return SettingsCard(rows: [SettingsUI.row(
                title: Strings.resetTitle,
                subtitle: Strings.resetSubtitle,
                control: SettingsUI.button(
                    Strings.resetButton,
                    target: self,
                    action: #selector(resetAllClicked)
                )
            )])
        }
    }

    private func topInset(forRowAt index: Int) -> CGFloat {
        guard presentationRows.indices.contains(index) else { return 0 }
        switch presentationRows[index] {
        case .note, .composer, .group, .reset:
            return Design.Spacing.large
        case .command:
            return 0
        }
    }

    private func setGroup(_ key: String, expanded: Bool) {
        if expanded {
            expandedGroups.insert(key)
        } else {
            expandedGroups.remove(key)
        }
        reloadPresentationRows()
    }

    private func updateCardDecorations() {
        var boundsByGroup: [Int: (first: Int, last: Int)] = [:]
        for (index, row) in presentationRows.enumerated() {
            let groupIndex: Int?
            switch row {
            case .group(let index), .command(let index, _):
                groupIndex = index
            case .note, .composer, .reset:
                groupIndex = nil
            }
            guard let groupIndex else { continue }
            if var bounds = boundsByGroup[groupIndex] {
                bounds.last = index
                boundsByGroup[groupIndex] = bounds
            } else {
                boundsByGroup[groupIndex] = (index, index)
            }
        }
        tableView.cardDecorations = boundsByGroup.sorted { $0.key < $1.key }.map {
            ThemedTableCardDecoration(
                rows: $0.value.first...$0.value.last,
                topInset: Design.Spacing.large
            )
        }
    }

    var virtualRowCountForTesting: Int { presentationRows.count }

    var materializedRowCountForTesting: Int {
        var count = 0
        tableView.enumerateAvailableRowViews { _, _ in count += 1 }
        return count
    }

    func setGroupExpandedForTesting(_ group: AppCommand.Group, expanded: Bool) {
        setGroup(group.rawValue, expanded: expanded)
    }

    func scrollCommandToVisibleForTesting(group: AppCommand.Group, index: Int) {
        guard let groupIndex = groups.firstIndex(where: { $0.group == group }),
              let row = presentationRows.firstIndex(where: { presentationRow in
                  guard case .command(let candidateGroup, let candidateCommand) = presentationRow
                  else { return false }
                  return candidateGroup == groupIndex && candidateCommand == index
              }) else { return }
        tableView.scrollRowToVisible(row)
    }
}

private enum KeyboardPreferencesLayout {
    static let estimatedRowHeight: CGFloat = 72
}

// MARK: - Strings

private enum Strings {
    static var heading: String { L10n.string("Keyboard") }
    static var note: String {
        L10n.string(
            "Click a shortcut and press the keys you want. "
                + "Escape cancels, Delete removes the shortcut."
        )
    }

    /// A source key, localised by `SettingsUI.section` like every other section caption.
    static let composerSection = "Composer"

    /// Localised here instead, because the row it titles is built with `localizes: false` —
    /// its subtitle arrives from `PromptReturnKey` already translated.
    static var returnKeyTitle: String { L10n.string("When writing a prompt, press Return to") }

    static let conflictFormat = "Already used by %@"
    static let defaultConflictFormat = "Default %@ is used by %@"
    static let changedFormat = "Changed from %@"
    static var changedNoDefault: String { L10n.string("Changed") }

    static let conflictTitle = "%@ is already in use"
    static let conflictBody = "That combination belongs to “%@”. "
        + "Choose a different one, or clear that shortcut first."

    static var resetTitle: String { L10n.string("Reset Shortcuts") }
    static var resetSubtitle: String {
        L10n.string("Puts every shortcut back to its default.")
    }
    static var resetButton: String { L10n.string("Reset All") }
}

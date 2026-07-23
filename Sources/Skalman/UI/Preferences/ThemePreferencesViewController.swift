import AppKit
import UniformTypeIdentifiers

/// The Themes page: the list of themes, a preview of the selected one, and its palette.
///
/// This page sets the **default** theme — the one every session that has not been given its
/// own follows. The narrower scopes are assigned where they apply, from a session's or a
/// project's own menu, since that is where the thing being themed can be seen.
final class ThemePreferencesViewController: NSViewController {

    // MARK: - Constants

    private enum Layout {
        static let listHeight: CGFloat = 190
        static let rowHeight: CGFloat = 36
        static let buttonWidth: CGFloat = 28
        static let buttonHeight: CGFloat = 22
    }

    private enum Strings {
        static let defaultNote = """
            The default theme applies to every terminal that has not been given one of its own. \
            A project or a single session can override it from its ⋯ menu in the sidebar.
            """
        static let builtInNote = """
            Built-in themes cannot be edited. Duplicate this one to change its colours.
            """
    }

    // MARK: - Properties

    private var themes: [TerminalTheme] = []
    private var selectedTheme: TerminalTheme?
    private let appEvents = AppEventObservations()

    private var isBuiltInSelected: Bool {
        selectedTheme.map { ThemeManager.shared.isBuiltIn($0) } ?? false
    }

    // MARK: - UI Elements

    private lazy var themeTableView: NSTableView = {
        let table = NSTableView()
        table.headerView = nil
        table.rowHeight = Layout.rowHeight
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.backgroundColor = .clear
        table.style = .inset
        table.delegate = self
        table.dataSource = self
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ThemeName")))
        table.doubleAction = #selector(useSelectedTheme)
        table.target = self
        return table
    }()

    private lazy var themeScrollView: NSScrollView = {
        let scroll = NSScrollView()
        scroll.documentView = themeTableView
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        return scroll
    }()

    private lazy var addButton = iconButton("plus", tooltip: "New Theme", action: #selector(addTheme))
    private lazy var removeButton = iconButton("minus", tooltip: "Delete Theme", action: #selector(removeTheme))

    private lazy var actionButton: NSPopUpButton = {
        let button = NSPopUpButton()
        button.pullsDown = true
        button.bezelStyle = .smallSquare
        button.isBordered = false

        let menu = NSMenu()
        menu.addItem(withTitle: "", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "Duplicate", action: #selector(duplicateTheme), keyEquivalent: "")
        menu.addItem(withTitle: "Rename…", action: #selector(renameTheme), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Import from Terminal.app…", action: #selector(importFromTerminal), keyEquivalent: "")
        menu.addItem(withTitle: "Export…", action: #selector(exportTheme), keyEquivalent: "")

        for item in menu.items { item.target = self }
        button.menu = menu

        if let gear = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Actions") {
            button.item(at: 0)?.image = gear
        }

        return button
    }()

    private lazy var useThemeButton: NSButton = {
        let button = NSButton(title: "Use as Default", target: self, action: #selector(useSelectedTheme))
        button.bezelStyle = .rounded
        button.controlSize = .regular
        return button
    }()

    private let previewView = ThemePreviewView()
    private let colorEditor = ThemeColorEditor()

    private weak var appThemePopUp: NSPopUpButton?
    private weak var appThemeSubtitle: NSTextField?

    /// Explains why the palette below it is read-only, and offers the way out. Hidden for a
    /// custom theme, where the palette simply works.
    private lazy var builtInNote = SettingsUI.note(Strings.builtInNote)

    private lazy var duplicateButton = SettingsUI.button("Duplicate", target: self, action: #selector(duplicateTheme))

    private lazy var builtInBanner: NSView = {
        let stack = NSStackView(views: [builtInNote, duplicateButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Design.Spacing.medium
        builtInNote.setContentHuggingPriority(.defaultLow, for: .horizontal)
        duplicateButton.setContentHuggingPriority(.required, for: .horizontal)
        return stack
    }()

    // MARK: - Initialization

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        loadThemes()

        colorEditor.onChange = { [weak self] key, color in
            self?.apply(color, for: key)
        }

        appEvents.observe(ThemesDidChange.self) { [weak self] _ in self?.themesDidChange() }
        appEvents.observe(ProfileDidChange.self) { [weak self] _ in self?.themesDidChange() }
    }

    // MARK: - Setup

    private func setupUI() {
        let page = SettingsUI.page([
            SettingsUI.heading("Themes"),
            SettingsUI.section("App", appThemeSection()),
            SettingsUI.section("Terminal", themeListSection()),
            SettingsUI.section("Preview", previewView),
            SettingsUI.section("Colors", colorsSection())
        ])

        page.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(page)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: view.topAnchor),
            page.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            page.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    /// The app's own theme — the window, sidebar, panels and text — chosen for the whole app.
    ///
    /// App-wide rather than per-session, unlike the terminal palette below it: there is one
    /// window, and a sidebar cannot be two colours at once. "System" is the default and is not
    /// a compromise — it resolves every role to the system colour the app always used, so the
    /// design system's light/dark and accent behaviour is intact for anyone who never picks a
    /// style.
    private func appThemeSection() -> NSView {
        let popUp = SettingsUI.popUp(target: self, action: #selector(appThemeChanged))
        for theme in AppThemeLibrary.stock {
            let item = NSMenuItem(title: theme.name, action: nil, keyEquivalent: "")
            item.representedObject = theme.id.rawValue
            popUp.menu?.addItem(item)
        }
        popUp.selectItem(at: AppThemeLibrary.stock.firstIndex { $0.id == AppThemeLibrary.current.id } ?? 0)
        appThemePopUp = popUp

        let card = SettingsCard(rows: [
            SettingsUI.row(
                title: "App theme",
                subtitle: AppThemeLibrary.current.summary,
                control: popUp,
                subtitleField: &appThemeSubtitle
            )
        ])
        return card
    }

    @objc private func appThemeChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let theme = AppThemeLibrary.theme(withID: AppThemeID(raw)) else { return }

        AppThemeLibrary.apply(theme)
        // The subtitle describes the *chosen* theme, so it moves with the choice — otherwise
        // it keeps describing the theme that was selected when the card was built.
        appThemeSubtitle?.stringValue = theme.summary ?? ""
    }

    /// The theme list on its flat surface, the list-editing controls beneath it, and a note
    /// saying what "default" actually means now that a session can override it.
    private func themeListSection() -> NSView {
        themeScrollView.translatesAutoresizingMaskIntoConstraints = false

        // A visible card holds the list, so the rows read as one contained group instead of
        // floating on the page. The scroll itself is transparent; the card draws the surface.
        let card = NSView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.applySurface(fill: Design.Surface.panel, radius: Design.Radius.panel, border: Design.Surface.border)
        card.addSubview(themeScrollView)

        NSLayoutConstraint.activate([
            card.heightAnchor.constraint(equalToConstant: Layout.listHeight),
            themeScrollView.topAnchor.constraint(equalTo: card.topAnchor, constant: Design.Spacing.small),
            themeScrollView.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -Design.Spacing.small),
            themeScrollView.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Design.Spacing.tight),
            themeScrollView.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Design.Spacing.tight)
        ])

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let buttonRow = NSStackView(views: [addButton, removeButton, actionButton, spacer, useThemeButton])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = Design.Spacing.small

        let note = SettingsUI.note(Strings.defaultNote)

        let stack = NSStackView(views: [card, buttonRow, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.medium
        stack.setCustomSpacing(Design.Spacing.small, after: card)

        for row in [card, buttonRow, note] as [NSView] {
            row.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
            row.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        }

        return stack
    }

    private func colorsSection() -> NSView {
        let stack = NSStackView(views: [builtInBanner, colorEditor])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.medium

        for row in [builtInBanner, colorEditor] as [NSView] {
            row.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
            row.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        }

        return stack
    }

    private func iconButton(_ symbol: String, tooltip: String, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        let button = NSButton(image: image ?? NSImage(), target: self, action: action)
        button.bezelStyle = .roundRect
        button.isBordered = true
        button.toolTip = tooltip
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: Layout.buttonWidth).isActive = true
        button.heightAnchor.constraint(equalToConstant: Layout.buttonHeight).isActive = true
        return button
    }

    // MARK: - Data

    private func loadThemes() {
        themes = ThemeManager.shared.allThemes
        themeTableView.reloadData()

        // Keep whatever was selected across a reload — editing a colour reloads the list, and
        // jumping back to the default theme mid-edit would be maddening.
        let target = selectedTheme?.name ?? ThemeAssignments.defaultTheme.name
        let index = themes.firstIndex { $0.name == target } ?? 0

        if !themes.isEmpty {
            selectedTheme = themes[index]
            themeTableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else {
            selectedTheme = nil
        }

        updateEditor()
    }

    private func themesDidChange() {
        loadThemes()
    }

    private func updateEditor() {
        previewView.show(selectedTheme)

        guard let theme = selectedTheme else {
            builtInBanner.isHidden = true
            removeButton.isEnabled = false
            return
        }

        let isBuiltIn = ThemeManager.shared.isBuiltIn(theme)
        colorEditor.show(theme, isEditable: !isBuiltIn)
        builtInBanner.isHidden = !isBuiltIn
        removeButton.isEnabled = !isBuiltIn
        useThemeButton.isEnabled = theme.name != ThemeAssignments.defaultTheme.name
    }

    // MARK: - Actions

    @objc private func useSelectedTheme() {
        guard let theme = selectedTheme else { return }
        ThemeAssignments.setDefaultTheme(theme)
        themeTableView.reloadData()
        updateEditor()
    }

    @objc private func addTheme() {
        var newTheme = TerminalTheme.basic
        newTheme.name = uniqueName(basedOn: "New Theme")

        guard ThemeAssignments.create(newTheme) else { return }

        selectedTheme = newTheme
        loadThemes()
        renameTheme()
    }

    private func uniqueName(basedOn base: String) -> String {
        var name = base
        var counter = 1
        while ThemeManager.shared.theme(named: name) != nil {
            counter += 1
            name = "\(base) \(counter)"
        }
        return name
    }

    @objc private func removeTheme() {
        guard let theme = selectedTheme else { return }

        guard !ThemeManager.shared.isBuiltIn(theme) else {
            presentAlert(
                "Cannot Delete",
                "Built-in themes cannot be deleted. Duplicate this one and change the copy instead."
            )
            return
        }

        let alert = NSAlert()
        alert.messageText = "Delete “\(theme.name)”?"
        alert.informativeText = "Sessions and projects using it fall back to the theme they inherit."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard ThemeManager.shared.deleteTheme(theme) else { return }

        selectedTheme = nil
        loadThemes()
    }

    @objc private func importFromTerminal() {
        guard let type = UTType(filenameExtension: "terminal"), let window = view.window else { return }

        let panel = NSOpenPanel()
        panel.allowedContentTypes = [type]
        panel.allowsMultipleSelection = true
        panel.message = "Select Terminal.app theme files to import"

        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self else { return }

            var lastImported: TerminalTheme?
            for url in panel.urls {
                do {
                    lastImported = try ThemeManager.shared.importAppleTerminalTheme(from: url)
                } catch {
                    NSAlert(error: error).runModal()
                }
            }

            guard let lastImported else { return }
            self.selectedTheme = lastImported
            self.loadThemes()
        }
    }

    @objc private func duplicateTheme() {
        guard let theme = selectedTheme else { return }
        selectedTheme = ThemeManager.shared.duplicateTheme(theme)
        loadThemes()
    }

    @objc private func renameTheme() {
        guard let theme = selectedTheme, !ThemeManager.shared.isBuiltIn(theme) else { return }

        let alert = NSAlert()
        alert.messageText = "Rename Theme"
        alert.informativeText = "Enter a new name for “\(theme.name)”:"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = theme.name
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != theme.name else { return }

        // Through `ThemeAssignments`, which re-points every session and project naming the old
        // one — `ThemeManager` alone would leave them all inheriting again.
        guard ThemeAssignments.rename(theme, to: newName) else {
            presentAlert("Cannot Rename", "A theme with that name already exists.")
            return
        }

        selectedTheme = ThemeManager.shared.theme(named: newName)
        loadThemes()
    }

    @objc private func exportTheme() {
        guard let theme = selectedTheme, let window = view.window else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(theme.name).json"
        panel.message = "Export theme as JSON"

        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }

            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(theme).write(to: url)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    /// Writes one changed colour back to the theme, and to the default if this is it.
    ///
    /// The list is *not* reloaded here: a reload rebuilds the rows under a colour panel the
    /// user is still dragging in, and the only thing on screen that a single colour changes is
    /// the row's own swatch and the preview.
    private func apply(_ color: NSColor, for key: ThemeColorKey) {
        guard var theme = selectedTheme, !ThemeManager.shared.isBuiltIn(theme) else { return }

        theme[key] = color
        ThemeManager.shared.addTheme(theme)
        selectedTheme = theme
        themes = ThemeManager.shared.allThemes

        previewView.show(theme)
        reloadRow(named: theme.name)

        // The default carries an embedded copy of the theme rather than its name, so an edit
        // reaches the terminals only by re-saving it.
        if ThemeAssignments.defaultTheme.name == theme.name {
            ThemeAssignments.setDefaultTheme(theme)
        } else {
            NotificationCenter.default.post(ThemeAssignmentsDidChange())
        }
    }

    private func reloadRow(named name: String) {
        guard let row = themes.firstIndex(where: { $0.name == name }) else { return }
        themeTableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
    }

    private func presentAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}

// MARK: - NSTableViewDataSource

extension ThemePreferencesViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        themes.count
    }
}

// MARK: - NSTableViewDelegate

extension ThemePreferencesViewController: NSTableViewDelegate {

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let theme = themes[row]
        let cell = tableView.makeView(withIdentifier: ThemeListRowView.identifier, owner: self)
            as? ThemeListRowView ?? ThemeListRowView()

        cell.configure(
            with: theme,
            isDefault: theme.name == ThemeAssignments.defaultTheme.name
        )
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = themeTableView.selectedRow
        guard row >= 0, row < themes.count else { return }
        selectedTheme = themes[row]
        updateEditor()
    }
}

// MARK: - Theme Row

/// One theme in the list: what it looks like, what it is called, and whether it is the default.
///
/// The swatch leads deliberately. A theme is a set of colours, so a column of names is a list
/// of things the user cannot see — the row's job is to make the list scannable without
/// selecting every entry in turn to preview it.
private final class ThemeListRowView: NSTableCellView {

    static let identifier = NSUserInterfaceItemIdentifier("ThemeListRow")

    private let swatch = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "Default")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier

        name.font = Design.Typography.body()
        name.lineBreakMode = .byTruncatingTail
        badge.font = Design.Typography.caption()
        badge.textColor = Design.Text.secondary

        let stack = NSStackView(views: [swatch, name, NSView(), badge])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Design.Spacing.medium
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Design.Spacing.small),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Design.Spacing.medium)
        ])

        name.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        badge.setContentHuggingPriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with theme: TerminalTheme, isDefault: Bool) {
        swatch.image = ThemeSwatchImage.listSwatch(for: theme)
        name.stringValue = theme.name
        badge.isHidden = !isDefault
    }
}

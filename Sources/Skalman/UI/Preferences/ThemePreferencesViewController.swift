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
        static let followTheme = "Follow Theme"
        static let followAppFont = "Follow App Font"
        static let builtInNote = """
            Built-in themes cannot be edited. Duplicate this one to change its colours.
            """
        static let followsAppNote = """
            These colours come from the app theme above. Duplicate them to edit a copy.
            """
    }

    // MARK: - Properties

    private var themes: [TerminalTheme] = []
    private var selectedTheme: TerminalTheme?
    private let appEvents = AppEventObservations()

    private var isBuiltInSelected: Bool {
        selectedTheme.map { ThemeManager.shared.isBuiltIn($0) } ?? false
    }

    /// Neither editable nor deletable, for the same reason: there is no palette here to change.
    /// The way to change what it draws is to change the app theme above it.
    private var isFollowsAppThemeSelected: Bool {
        selectedTheme?.id == .followsAppTheme
    }

    // MARK: - UI Elements

    private lazy var themeTableView: NSTableView = {
        let table = ThemedTableView()
        table.headerView = nil
        table.rowHeight = Layout.rowHeight
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.style = .inset
        table.delegate = self
        table.dataSource = self
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ThemeName")))
        table.doubleAction = #selector(useSelectedTheme)
        table.target = self
        return table
    }()

    private lazy var themeScrollView: NSScrollView = {
        let scroll = ThemedScrollView()
        scroll.documentView = themeTableView
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        return scroll
    }()

    private lazy var addButton = iconButton("plus", tooltip: "New Theme", action: #selector(addTheme))
    private lazy var removeButton = iconButton("minus", tooltip: "Delete Theme", action: #selector(removeTheme))

    private lazy var actionButton: ThemedPopUp = {
        let button = ThemedPopUp()
        button.pullsDown = true
        button.isBordered = false

        button.addItem(
            ThemedMenuItem(
                title: "",
                image: NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Actions")
            )
        )
        button.addItem(ThemedMenuItem(title: "Duplicate", onChoose: { [weak self] in
            self?.duplicateTheme()
        }))
        button.addItem(ThemedMenuItem(title: "Rename…", onChoose: { [weak self] in
            self?.renameTheme()
        }))
        button.addSeparator()
        button.addItem(ThemedMenuItem(title: "Import from Terminal.app…", onChoose: { [weak self] in
            self?.importFromTerminal()
        }))
        button.addItem(ThemedMenuItem(title: "Export…", onChoose: { [weak self] in
            self?.exportTheme()
        }))

        return button
    }()

    private lazy var useThemeButton: ThemedButton = {
        ThemedButton(title: "Use as Default", target: self, action: #selector(useSelectedTheme))
    }()

    private let previewView = ThemePreviewView()
    private let colorEditor = ThemeColorEditor()

    private weak var appThemePopUp: ThemedPopUp?
    private weak var chromeFontPopUp: ThemedPopUp?
    private weak var conversationFontPopUp: ThemedPopUp?
    private weak var appThemeSubtitle: NSTextField?
    private weak var duplicateAppThemeButton: ThemedButton?
    private weak var deleteAppThemeButton: ThemedButton?

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
        // The app-theme entry *is* the app theme's palette, so a switch changes what this list
        // shows as well as what the window is painted in.
        appEvents.observe(AppThemeDidChange.self) { [weak self] _ in self?.appThemeDidChange() }
        appEvents.observe(AppThemeLibraryDidChange.self) { [weak self] _ in
            self?.appThemeLibraryDidChange()
        }
        appEvents.observe(ProfileDidChange.self) { [weak self] _ in self?.themesDidChange() }
    }

    // MARK: - Setup

    private func setupUI() {
        let page = SettingsUI.page([
            SettingsUI.heading("Themes"),
            SettingsUI.section("App", appThemeSection()),
            SettingsUI.section("Fonts", fontSection()),
            SettingsUI.section("Terminal", themeListSection()),
            SettingsUI.section("Preview", previewView),
            SettingsUI.section("Colors", colorsSection())
        ], hostPage: .themes)

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
        appThemePopUp = popUp

        let duplicate = iconButton(
            "plus.square.on.square",
            tooltip: "Duplicate App Theme",
            action: #selector(duplicateAppTheme)
        )
        let delete = iconButton(
            "trash",
            tooltip: "Delete Custom App Theme",
            action: #selector(deleteAppTheme)
        )
        duplicateAppThemeButton = duplicate
        deleteAppThemeButton = delete

        let actions = NSStackView(views: [duplicate, delete])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = Design.Spacing.small

        let card = SettingsCard(rows: [
            SettingsUI.row(
                title: "App theme",
                subtitle: AppThemeLibrary.current.summary,
                control: popUp,
                subtitleField: &appThemeSubtitle
            ),
            SettingsUI.row(
                title: "Custom themes",
                subtitle: "Duplicate a built-in to make an editable copy.",
                control: actions
            )
        ])
        reloadAppThemeControls()
        return card
    }

    // MARK: - Fonts

    /// The user's own answer to the typeface question, which beats whatever the theme states.
    ///
    /// Two slots rather than one, and the second is the reason this is here rather than on
    /// General: a theme states a typeface, so overriding it belongs beside the theme. The
    /// conversation gets its own because it is the surface a reader *reads* — the terminal has
    /// had exactly this through `TerminalProfile` since long before the chrome could be themed.
    ///
    /// The lists are every family the machine has, not a curated set. A typeface is a taste, and
    /// a picker that offers four opinions is a fifth opinion.
    private func fontSection() -> NSView {
        let chrome = SettingsUI.popUp(target: self, action: #selector(chromeFontChanged))
        let conversation = SettingsUI.popUp(target: self, action: #selector(conversationFontChanged))
        chromeFontPopUp = chrome
        conversationFontPopUp = conversation

        let card = SettingsCard(rows: [
            SettingsUI.row(
                title: "App font",
                subtitle: "Overrides the typeface the theme states.",
                control: chrome
            ),
            SettingsUI.row(
                title: "Conversation font",
                subtitle: "The thread only. The terminal keeps its own font in Profile.",
                control: conversation
            )
        ])
        reloadFontControls()
        return card
    }

    /// Rebuilds both pickers. The families are read at build time rather than cached, since a
    /// font installed while the app is running — or registered by an extension enabling —
    /// should appear the next time this rebuilds. `Typography.availableFamilies` is the live
    /// list; `NSFontManager`'s snapshots on first access and misses extension fonts entirely.
    private func reloadFontControls() {
        let families = Design.Typography.availableFamilies

        for (popUp, inherit, selected) in [
            (chromeFontPopUp, Strings.followTheme, AppSettings.chromeFontFamily),
            (conversationFontPopUp, Strings.followAppFont, AppSettings.conversationFontFamily)
        ] {
            guard let popUp else { continue }
            popUp.removeAllItems()
            popUp.addItem(ThemedMenuItem(title: inherit, representedValue: FontChoice.inherit))
            for family in families {
                popUp.addItem(ThemedMenuItem(title: family, representedValue: family))
            }
            // A family the user chose and has since uninstalled keeps its recorded name — the
            // resolution falls through to the theme, and the picker says so by landing on the
            // inherit row rather than silently claiming a font that is no longer there.
            let index = selected.flatMap { families.firstIndex(of: $0).map { $0 + 1 } } ?? 0
            popUp.selectItem(at: index)
        }
    }

    @objc private func chromeFontChanged(_ sender: ThemedPopUp) {
        AppSettings.shared.chromeFontFamily = chosenFamily(from: sender)
    }

    @objc private func conversationFontChanged(_ sender: ThemedPopUp) {
        AppSettings.shared.conversationFontFamily = chosenFamily(from: sender)
    }

    private func chosenFamily(from popUp: ThemedPopUp) -> String? {
        guard let raw = popUp.selectedItem?.representedValue as? String,
              raw != FontChoice.inherit else { return nil }
        return raw
    }

    private enum FontChoice {
        /// A sentinel rather than `nil`, because a menu item's represented value is `Any?` and
        /// an absent one is indistinguishable from an item that failed to carry its value.
        static let inherit = "\u{0}inherit"
    }

    @objc private func appThemeChanged(_ sender: ThemedPopUp) {
        guard let raw = sender.selectedItem?.representedValue as? String,
              let theme = AppThemeLibrary.theme(withID: AppThemeID(raw)) else { return }

        AppThemeLibrary.apply(theme)
        // The subtitle describes the *chosen* theme, so it moves with the choice — otherwise
        // it keeps describing the theme that was selected when the card was built.
        appThemeSubtitle?.stringValue = theme.summary ?? ""
    }

    private func reloadAppThemeControls() {
        guard let popUp = appThemePopUp else { return }
        popUp.removeAllItems()
        for theme in AppThemeLibrary.all {
            // A contributed theme is labelled by the extension it came from — that is where a
            // user goes to update or remove it, and two extensions may both ship a "Storm".
            let title: String
            if AppThemeLibrary.isCustom(theme) {
                title = "\(theme.name) — Custom"
            } else if let contributor = AppThemeLibrary.contributorName(of: theme) {
                title = "\(theme.name) — \(contributor)"
            } else {
                title = theme.name
            }
            popUp.addItem(
                ThemedMenuItem(title: title, representedValue: theme.id.rawValue)
            )
        }
        let index = AppThemeLibrary.all.firstIndex {
            $0.id == AppThemeLibrary.current.id
        } ?? 0
        popUp.selectItem(at: index)
        appThemeSubtitle?.stringValue = AppThemeLibrary.current.summary ?? ""
        duplicateAppThemeButton?.isEnabled = true
        deleteAppThemeButton?.isEnabled = AppThemeLibrary.isCustom(AppThemeLibrary.current)
    }

    private func appThemeDidChange() {
        reloadAppThemeControls()
        // “Follow App Theme” is a live terminal-palette entry.
        loadThemes()
        // A font-override change arrives as this same event (`startObservingFontOverrides`
        // deliberately reuses it), and this page is cached across visits — without a reload a
        // font chosen through MCP or another window leaves these pickers showing the old answer.
        reloadFontControls()
    }

    private func appThemeLibraryDidChange() {
        reloadAppThemeControls()
    }

    @objc private func duplicateAppTheme() {
        let source = AppThemeLibrary.current
        do {
            let copy = try AppThemeEditing.duplicate(
                source,
                id: AppThemeLibrary.makeCustomID(),
                name: AppThemeLibrary.uniqueCopyName(of: source)
            )
            try AppThemeLibrary.create(copy)
            AppThemeLibrary.apply(copy)
        } catch {
            presentAlert("Cannot Duplicate App Theme", error.localizedDescription)
        }
    }

    @objc private func deleteAppTheme() {
        let theme = AppThemeLibrary.current
        guard AppThemeLibrary.isCustom(theme) else {
            presentAlert(
                "Cannot Delete App Theme",
                "Built-in app themes are fixed. Duplicate one to make an editable custom theme."
            )
            return
        }

        let alert = NSAlert()
        alert.messageText = "Delete “\(theme.name)”?"
        alert.informativeText = "The app will return to the System theme."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        _ = AppThemeLibrary.delete(theme)
    }

    /// The theme list on its flat surface, the list-editing controls beneath it, and a note
    /// saying what "default" actually means now that a session can override it.
    private func themeListSection() -> NSView {
        themeScrollView.translatesAutoresizingMaskIntoConstraints = false

        // A visible card holds the list, so the rows read as one contained group instead of
        // floating on the page. The scroll itself is transparent; the card draws the surface.
        let card = NSView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.applySurface(fill: Design.Surface.panel, radius: .panel, border: Design.Surface.border)
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

    private func iconButton(_ symbol: String, tooltip: String, action: Selector) -> ThemedButton {
        let button = ThemedButton(symbol: symbol, accessibility: tooltip, target: self, action: action)
        button.isBordered = true
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: Layout.buttonWidth).isActive = true
        button.heightAnchor.constraint(equalToConstant: Layout.buttonHeight).isActive = true
        return button
    }

    // MARK: - Data

    private func loadThemes() {
        // The app-theme entry leads the list. It is not a palette anyone edits — it is the answer
        // "whatever the app theme says", shown with the palette that answer currently gives, so
        // choosing it is the same gesture as choosing any other row.
        themes = ThemeAssignments.selectableThemes
        themeTableView.reloadData()

        // Keep whatever was selected across a reload — editing a colour reloads the list, and
        // jumping back to the default theme mid-edit would be maddening.
        let target = selectedTheme?.id ?? ThemeAssignments.defaultTheme.id
        let index = themes.firstIndex { $0.id == target } ?? 0

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

        let isFixed = ThemeManager.shared.isBuiltIn(theme) || isFollowsAppThemeSelected
        colorEditor.show(theme, isEditable: !isFixed)
        builtInNote.stringValue = isFollowsAppThemeSelected ? Strings.followsAppNote : Strings.builtInNote
        builtInBanner.isHidden = !isFixed
        removeButton.isEnabled = !isFixed
        useThemeButton.isEnabled = theme.id != ThemeAssignments.defaultTheme.id
    }

    // MARK: - Actions

    @objc private func useSelectedTheme() {
        guard let theme = selectedTheme else { return }
        ThemeAssignments.setDefaultTheme(theme)
        themeTableView.reloadData()
        updateEditor()
    }

    @objc private func addTheme() {
        let newTheme = TerminalTheme.basic.duplicated(named: uniqueName(basedOn: "New Theme"))

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

        guard !isFollowsAppThemeSelected else {
            presentAlert(
                "Cannot Delete",
                "“\(TerminalThemeNames.followsAppTheme)” is not a palette — it draws with whatever "
                    + "the app theme states. Change the app theme above to change what it gives you."
            )
            return
        }

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

        let field = ThemedTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = theme.name
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != theme.name else { return }

        guard ThemeAssignments.rename(theme, to: newName) else {
            presentAlert("Cannot Rename", "A theme with that name already exists.")
            return
        }

        selectedTheme = ThemeManager.shared.theme(withID: theme.id)
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
        themes = ThemeAssignments.selectableThemes

        previewView.show(theme)
        reloadRow(withID: theme.id)

        // The default carries an embedded copy of the theme rather than only its ID, so an edit
        // reaches the terminals only by re-saving it.
        if ThemeAssignments.defaultTheme.id == theme.id {
            ThemeAssignments.setDefaultTheme(theme)
        } else {
            NotificationCenter.default.post(ThemeAssignmentsDidChange())
        }
    }

    private func reloadRow(withID id: TerminalThemeID) {
        guard let row = themes.firstIndex(where: { $0.id == id }) else { return }
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
            isDefault: theme.id == ThemeAssignments.defaultTheme.id
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

        name.applyFont(.body)
        name.lineBreakMode = .byTruncatingTail
        badge.applyFont(.caption)
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

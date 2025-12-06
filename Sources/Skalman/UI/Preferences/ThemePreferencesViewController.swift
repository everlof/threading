import AppKit
import UniformTypeIdentifiers

/// View controller for theme management in preferences.
final class ThemePreferencesViewController: NSViewController {

    // MARK: - Constants

    private enum Layout {
        static let padding: CGFloat = 24
        static let spacing: CGFloat = 16
        static let listWidth: CGFloat = 180
        static let previewHeight: CGFloat = 100
        static let colorWellSize: CGFloat = 24
        static let thumbnailWidth: CGFloat = 32
        static let thumbnailHeight: CGFloat = 24
    }

    // MARK: - Properties

    private var themes: [TerminalTheme] = []
    private var selectedTheme: TerminalTheme?

    // MARK: - UI Elements

    private lazy var splitView: NSSplitView = {
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        return split
    }()

    private lazy var themeTableView: NSTableView = {
        let table = NSTableView()
        table.headerView = nil
        table.rowHeight = 32
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.backgroundColor = .clear
        table.delegate = self
        table.dataSource = self

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ThemeName"))
        column.width = Layout.listWidth - 20
        table.addTableColumn(column)

        return table
    }()

    private lazy var themeScrollView: NSScrollView = {
        let scroll = NSScrollView()
        scroll.documentView = themeTableView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        return scroll
    }()

    private lazy var addButton: NSButton = {
        let button = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Add")!, target: self, action: #selector(addTheme))
        button.bezelStyle = .roundRect
        button.isBordered = true
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        button.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return button
    }()

    private lazy var removeButton: NSButton = {
        let button = NSButton(image: NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove")!, target: self, action: #selector(removeTheme))
        button.bezelStyle = .roundRect
        button.isBordered = true
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        button.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return button
    }()

    private lazy var actionButton: NSPopUpButton = {
        let button = NSPopUpButton()
        button.pullsDown = true
        button.bezelStyle = .smallSquare
        button.isBordered = false

        let menu = NSMenu()
        menu.addItem(withTitle: "", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "Import from Terminal.app...", action: #selector(importFromTerminal), keyEquivalent: "")
        menu.addItem(withTitle: "Duplicate", action: #selector(duplicateTheme), keyEquivalent: "")
        menu.addItem(withTitle: "Rename...", action: #selector(renameTheme), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Export...", action: #selector(exportTheme), keyEquivalent: "")

        for item in menu.items {
            item.target = self
        }

        button.menu = menu

        if let gearImage = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Actions") {
            button.item(at: 0)?.image = gearImage
        }

        return button
    }()

    private lazy var useThemeButton: NSButton = {
        let button = NSButton(title: "Use Theme", target: self, action: #selector(useSelectedTheme))
        button.bezelStyle = .rounded
        button.controlSize = .regular
        return button
    }()

    private lazy var previewView: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 6
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor.separatorColor.cgColor
        return view
    }()

    private lazy var previewLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.isBezeled = false
        label.drawsBackground = false
        label.isEditable = false
        label.isSelectable = false
        label.maximumNumberOfLines = 8
        return label
    }()

    private lazy var mainColorsSection: NSStackView = {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 24
        stack.alignment = .top
        return stack
    }()

    private lazy var ansiColorsSection: NSStackView = {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 12
        stack.alignment = .leading
        return stack
    }()

    private var colorWells: [String: NSColorWell] = [:]

    // MARK: - Initialization

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 420))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        loadThemes()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(themesDidChange),
            name: .themesDidChange,
            object: nil
        )

        // Add keyboard event monitoring for delete key
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self,
                  self.view.window?.firstResponder === self.themeTableView else {
                return event
            }

            // Check for Delete or Backspace key
            if event.keyCode == 51 || event.keyCode == 117 { // Backspace or Delete
                self.removeTheme()
                return nil // Consume the event
            }
            return event
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Setup

    private func setupUI() {
        // Left panel: theme list
        let leftPanel = NSView()
        leftPanel.translatesAutoresizingMaskIntoConstraints = false

        themeScrollView.translatesAutoresizingMaskIntoConstraints = false
        leftPanel.addSubview(themeScrollView)

        let buttonBar = NSStackView(views: [addButton, removeButton, actionButton])
        buttonBar.spacing = 0
        buttonBar.translatesAutoresizingMaskIntoConstraints = false
        leftPanel.addSubview(buttonBar)

        NSLayoutConstraint.activate([
            themeScrollView.topAnchor.constraint(equalTo: leftPanel.topAnchor),
            themeScrollView.leadingAnchor.constraint(equalTo: leftPanel.leadingAnchor),
            themeScrollView.trailingAnchor.constraint(equalTo: leftPanel.trailingAnchor),
            themeScrollView.bottomAnchor.constraint(equalTo: buttonBar.topAnchor, constant: -4),

            buttonBar.leadingAnchor.constraint(equalTo: leftPanel.leadingAnchor),
            buttonBar.bottomAnchor.constraint(equalTo: leftPanel.bottomAnchor),
            buttonBar.heightAnchor.constraint(equalToConstant: 24)
        ])

        // Right panel: theme editor
        let rightPanel = NSView()
        rightPanel.translatesAutoresizingMaskIntoConstraints = false

        // Preview
        previewView.translatesAutoresizingMaskIntoConstraints = false
        previewLabel.translatesAutoresizingMaskIntoConstraints = false
        previewView.addSubview(previewLabel)
        rightPanel.addSubview(previewView)

        // Main colors section (foreground, background, cursor, selection)
        let mainColorsLabel = NSTextField(labelWithString: "Main Colors")
        mainColorsLabel.font = .systemFont(ofSize: 11, weight: .medium)
        mainColorsLabel.textColor = .secondaryLabelColor
        mainColorsLabel.translatesAutoresizingMaskIntoConstraints = false
        rightPanel.addSubview(mainColorsLabel)

        setupMainColors()
        mainColorsSection.translatesAutoresizingMaskIntoConstraints = false
        rightPanel.addSubview(mainColorsSection)

        // ANSI colors section
        let ansiColorsLabel = NSTextField(labelWithString: "ANSI Colors")
        ansiColorsLabel.font = .systemFont(ofSize: 11, weight: .medium)
        ansiColorsLabel.textColor = .secondaryLabelColor
        ansiColorsLabel.translatesAutoresizingMaskIntoConstraints = false
        rightPanel.addSubview(ansiColorsLabel)

        setupANSIColors()
        ansiColorsSection.translatesAutoresizingMaskIntoConstraints = false
        rightPanel.addSubview(ansiColorsSection)

        // Use Theme button
        useThemeButton.translatesAutoresizingMaskIntoConstraints = false
        rightPanel.addSubview(useThemeButton)

        NSLayoutConstraint.activate([
            previewView.topAnchor.constraint(equalTo: rightPanel.topAnchor),
            previewView.leadingAnchor.constraint(equalTo: rightPanel.leadingAnchor),
            previewView.trailingAnchor.constraint(equalTo: rightPanel.trailingAnchor),
            previewView.heightAnchor.constraint(equalToConstant: Layout.previewHeight),

            previewLabel.topAnchor.constraint(equalTo: previewView.topAnchor, constant: 10),
            previewLabel.leadingAnchor.constraint(equalTo: previewView.leadingAnchor, constant: 10),
            previewLabel.trailingAnchor.constraint(equalTo: previewView.trailingAnchor, constant: -10),

            mainColorsLabel.topAnchor.constraint(equalTo: previewView.bottomAnchor, constant: 20),
            mainColorsLabel.leadingAnchor.constraint(equalTo: rightPanel.leadingAnchor),

            mainColorsSection.topAnchor.constraint(equalTo: mainColorsLabel.bottomAnchor, constant: 10),
            mainColorsSection.leadingAnchor.constraint(equalTo: rightPanel.leadingAnchor),
            mainColorsSection.trailingAnchor.constraint(lessThanOrEqualTo: rightPanel.trailingAnchor),

            ansiColorsLabel.topAnchor.constraint(equalTo: mainColorsSection.bottomAnchor, constant: 20),
            ansiColorsLabel.leadingAnchor.constraint(equalTo: rightPanel.leadingAnchor),

            ansiColorsSection.topAnchor.constraint(equalTo: ansiColorsLabel.bottomAnchor, constant: 10),
            ansiColorsSection.leadingAnchor.constraint(equalTo: rightPanel.leadingAnchor),
            ansiColorsSection.trailingAnchor.constraint(lessThanOrEqualTo: rightPanel.trailingAnchor),

            useThemeButton.topAnchor.constraint(equalTo: ansiColorsSection.bottomAnchor, constant: 20),
            useThemeButton.leadingAnchor.constraint(equalTo: rightPanel.leadingAnchor)
        ])

        // Main layout
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.addArrangedSubview(leftPanel)
        splitView.addArrangedSubview(rightPanel)
        view.addSubview(splitView)

        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: view.topAnchor, constant: Layout.padding),
            splitView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Layout.padding),
            splitView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Layout.padding),
            splitView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -Layout.padding),

            leftPanel.widthAnchor.constraint(equalToConstant: Layout.listWidth)
        ])
    }

    private func setupMainColors() {
        let mainColors: [(key: String, label: String)] = [
            ("foreground", "Text"),
            ("background", "Background"),
            ("cursor", "Cursor"),
            ("selection", "Selection")
        ]

        for colorInfo in mainColors {
            let stack = createLabeledColorWell(key: colorInfo.key, label: colorInfo.label)
            mainColorsSection.addArrangedSubview(stack)
        }
    }

    private func setupANSIColors() {
        // Normal colors row
        let normalRow = NSStackView()
        normalRow.orientation = .horizontal
        normalRow.spacing = 8

        let normalLabel = NSTextField(labelWithString: "Normal")
        normalLabel.font = .systemFont(ofSize: 11)
        normalLabel.textColor = .secondaryLabelColor
        normalLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        normalLabel.widthAnchor.constraint(equalToConstant: 50).isActive = true
        normalRow.addArrangedSubview(normalLabel)

        let normalColorsStack = NSStackView()
        normalColorsStack.orientation = .horizontal
        normalColorsStack.spacing = 4

        let normalColors = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white"]
        for key in normalColors {
            normalColorsStack.addArrangedSubview(createColorWell(key: key))
        }
        normalRow.addArrangedSubview(normalColorsStack)

        // Bright colors row
        let brightRow = NSStackView()
        brightRow.orientation = .horizontal
        brightRow.spacing = 8

        let brightLabel = NSTextField(labelWithString: "Bright")
        brightLabel.font = .systemFont(ofSize: 11)
        brightLabel.textColor = .secondaryLabelColor
        brightLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        brightLabel.widthAnchor.constraint(equalToConstant: 50).isActive = true
        brightRow.addArrangedSubview(brightLabel)

        let brightColorsStack = NSStackView()
        brightColorsStack.orientation = .horizontal
        brightColorsStack.spacing = 4

        let brightColors = ["brightBlack", "brightRed", "brightGreen", "brightYellow",
                           "brightBlue", "brightMagenta", "brightCyan", "brightWhite"]
        for key in brightColors {
            brightColorsStack.addArrangedSubview(createColorWell(key: key))
        }
        brightRow.addArrangedSubview(brightColorsStack)

        ansiColorsSection.addArrangedSubview(normalRow)
        ansiColorsSection.addArrangedSubview(brightRow)
    }

    private func createLabeledColorWell(key: String, label: String) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 6
        stack.alignment = .centerX

        let well: NSColorWell
        if #available(macOS 13.0, *) {
            well = NSColorWell(style: .minimal)
        } else {
            well = NSColorWell()
        }
        well.translatesAutoresizingMaskIntoConstraints = false
        well.widthAnchor.constraint(equalToConstant: 36).isActive = true
        well.heightAnchor.constraint(equalToConstant: 28).isActive = true
        well.target = self
        well.action = #selector(colorChanged(_:))
        colorWells[key] = well

        let labelField = NSTextField(labelWithString: label)
        labelField.font = .systemFont(ofSize: 10)
        labelField.textColor = .secondaryLabelColor

        stack.addArrangedSubview(well)
        stack.addArrangedSubview(labelField)

        return stack
    }

    private func createColorWell(key: String) -> NSColorWell {
        let well: NSColorWell
        if #available(macOS 13.0, *) {
            well = NSColorWell(style: .minimal)
        } else {
            well = NSColorWell()
        }
        well.translatesAutoresizingMaskIntoConstraints = false
        well.widthAnchor.constraint(equalToConstant: Layout.colorWellSize).isActive = true
        well.heightAnchor.constraint(equalToConstant: Layout.colorWellSize).isActive = true
        well.target = self
        well.action = #selector(colorChanged(_:))
        colorWells[key] = well
        return well
    }

    // MARK: - Data

    private func loadThemes() {
        themes = ThemeManager.shared.allThemes
        themeTableView.reloadData()

        if selectedTheme == nil && !themes.isEmpty {
            // Select the currently active theme by default
            let activeThemeName = ProfileStorage.shared.defaultProfile.theme.name
            if let index = themes.firstIndex(where: { $0.name == activeThemeName }) {
                selectedTheme = themes[index]
                themeTableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            } else {
                selectedTheme = themes[0]
                themeTableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            }
        }

        updateEditor()
    }

    @objc private func themesDidChange() {
        loadThemes()
    }

    private func updateEditor() {
        guard let theme = selectedTheme else {
            previewView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            previewLabel.stringValue = ""
            colorWells.values.forEach { $0.isEnabled = false }
            return
        }

        // Update preview with colored text
        previewView.layer?.backgroundColor = theme.background.cgColor
        previewLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

        let previewString = NSMutableAttributedString()
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

        // Line 1: prompt with bright green user and bright blue path
        previewString.append(NSAttributedString(string: "user@mac", attributes: [.foregroundColor: theme.brightGreen, .font: font]))
        previewString.append(NSAttributedString(string: ":", attributes: [.foregroundColor: theme.foreground, .font: font]))
        previewString.append(NSAttributedString(string: "~/projects", attributes: [.foregroundColor: theme.brightBlue, .font: font]))
        previewString.append(NSAttributedString(string: "$ ls\n", attributes: [.foregroundColor: theme.foreground, .font: font]))

        // Line 2: directory listing (bright blue for dirs, bright red for errors)
        previewString.append(NSAttributedString(string: "Documents  ", attributes: [.foregroundColor: theme.brightBlue, .font: font]))
        previewString.append(NSAttributedString(string: "README.md  ", attributes: [.foregroundColor: theme.foreground, .font: font]))
        previewString.append(NSAttributedString(string: "error.log\n", attributes: [.foregroundColor: theme.brightRed, .font: font]))

        // Line 3: bright yellow warning
        previewString.append(NSAttributedString(string: "Warning: ", attributes: [.foregroundColor: theme.brightYellow, .font: font]))
        previewString.append(NSAttributedString(string: "check config\n", attributes: [.foregroundColor: theme.foreground, .font: font]))

        // Line 4: cursor
        previewString.append(NSAttributedString(string: "$ _", attributes: [.foregroundColor: theme.foreground, .font: font]))

        previewLabel.attributedStringValue = previewString

        // Update color wells
        let isEditable = !ThemeManager.shared.isBuiltIn(theme)

        colorWells["foreground"]?.color = theme.foreground
        colorWells["background"]?.color = theme.background
        colorWells["cursor"]?.color = theme.cursor
        colorWells["selection"]?.color = theme.selection
        colorWells["black"]?.color = theme.black
        colorWells["red"]?.color = theme.red
        colorWells["green"]?.color = theme.green
        colorWells["yellow"]?.color = theme.yellow
        colorWells["blue"]?.color = theme.blue
        colorWells["magenta"]?.color = theme.magenta
        colorWells["cyan"]?.color = theme.cyan
        colorWells["white"]?.color = theme.white
        colorWells["brightBlack"]?.color = theme.brightBlack
        colorWells["brightRed"]?.color = theme.brightRed
        colorWells["brightGreen"]?.color = theme.brightGreen
        colorWells["brightYellow"]?.color = theme.brightYellow
        colorWells["brightBlue"]?.color = theme.brightBlue
        colorWells["brightMagenta"]?.color = theme.brightMagenta
        colorWells["brightCyan"]?.color = theme.brightCyan
        colorWells["brightWhite"]?.color = theme.brightWhite

        colorWells.values.forEach { $0.isEnabled = isEditable }
        removeButton.isEnabled = isEditable
    }

    // MARK: - Actions

    @objc private func useSelectedTheme() {
        guard let theme = selectedTheme else { return }
        ProfileStorage.shared.setTheme(theme)
        // Reload table to update checkmark indicator
        themeTableView.reloadData()
    }

    @objc private func addTheme() {
        var newTheme = TerminalTheme.basic
        var counter = 1
        var newName = "New Theme"

        while themes.contains(where: { $0.name == newName }) {
            counter += 1
            newName = "New Theme \(counter)"
        }

        newTheme.name = newName
        ThemeManager.shared.addTheme(newTheme)

        loadThemes()
        if let index = themes.firstIndex(where: { $0.name == newName }) {
            selectedTheme = themes[index]
            themeTableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            updateEditor()
        }
    }

    @objc private func removeTheme() {
        guard let theme = selectedTheme else { return }

        if ThemeManager.shared.isBuiltIn(theme) {
            let alert = NSAlert()
            alert.messageText = "Cannot Delete"
            alert.informativeText = "Built-in themes cannot be deleted. You can duplicate it and modify the copy."
            alert.runModal()
            return
        }

        let alert = NSAlert()
        alert.messageText = "Delete Theme"
        alert.informativeText = "Are you sure you want to delete \"\(theme.name)\"?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            let deleted = ThemeManager.shared.deleteTheme(theme)
            if deleted {
                // Reload themes first, then select a new one
                themes = ThemeManager.shared.allThemes
                selectedTheme = themes.first
                themeTableView.reloadData()
                if !themes.isEmpty {
                    themeTableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                }
                updateEditor()
            }
        }
    }

    @objc private func importFromTerminal() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "terminal")!]
        panel.allowsMultipleSelection = true
        panel.message = "Select Terminal.app theme files to import"

        panel.beginSheetModal(for: view.window!) { [weak self] response in
            guard response == .OK else { return }

            var lastImported: TerminalTheme?

            for url in panel.urls {
                do {
                    let theme = try ThemeManager.shared.importAppleTerminalTheme(from: url)
                    lastImported = theme
                } catch {
                    let alert = NSAlert(error: error)
                    alert.runModal()
                }
            }

            if let theme = lastImported {
                self?.loadThemes()
                if let index = self?.themes.firstIndex(where: { $0.name == theme.name }) {
                    self?.selectedTheme = theme
                    self?.themeTableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                    self?.updateEditor()
                }
            }
        }
    }

    @objc private func duplicateTheme() {
        guard let theme = selectedTheme else { return }

        let newTheme = ThemeManager.shared.duplicateTheme(theme)
        loadThemes()

        if let index = themes.firstIndex(where: { $0.name == newTheme.name }) {
            selectedTheme = newTheme
            themeTableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            updateEditor()
        }
    }

    @objc private func renameTheme() {
        guard let theme = selectedTheme, !ThemeManager.shared.isBuiltIn(theme) else { return }

        let alert = NSAlert()
        alert.messageText = "Rename Theme"
        alert.informativeText = "Enter a new name for \"\(theme.name)\":"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        textField.stringValue = theme.name
        alert.accessoryView = textField

        if alert.runModal() == .alertFirstButtonReturn {
            let newName = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !newName.isEmpty && newName != theme.name {
                if ThemeManager.shared.renameTheme(theme, to: newName) {
                    loadThemes()
                    if let index = themes.firstIndex(where: { $0.name == newName }) {
                        selectedTheme = themes[index]
                        themeTableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                    }
                } else {
                    let errorAlert = NSAlert()
                    errorAlert.messageText = "Cannot Rename"
                    errorAlert.informativeText = "A theme with that name already exists."
                    errorAlert.runModal()
                }
            }
        }
    }

    @objc private func exportTheme() {
        guard let theme = selectedTheme else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.json]
        panel.nameFieldStringValue = "\(theme.name).json"
        panel.message = "Export theme as JSON"

        panel.beginSheetModal(for: view.window!) { response in
            guard response == .OK, let url = panel.url else { return }

            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(theme)
                try data.write(to: url)
            } catch {
                let alert = NSAlert(error: error)
                alert.runModal()
            }
        }
    }

    @objc private func colorChanged(_ sender: NSColorWell) {
        guard var theme = selectedTheme, !ThemeManager.shared.isBuiltIn(theme) else { return }

        for (key, well) in colorWells where well === sender {
            let color = sender.color

            switch key {
            case "foreground": theme.foreground = color
            case "background": theme.background = color
            case "cursor": theme.cursor = color
            case "selection": theme.selection = color
            case "black": theme.black = color
            case "red": theme.red = color
            case "green": theme.green = color
            case "yellow": theme.yellow = color
            case "blue": theme.blue = color
            case "magenta": theme.magenta = color
            case "cyan": theme.cyan = color
            case "white": theme.white = color
            case "brightBlack": theme.brightBlack = color
            case "brightRed": theme.brightRed = color
            case "brightGreen": theme.brightGreen = color
            case "brightYellow": theme.brightYellow = color
            case "brightBlue": theme.brightBlue = color
            case "brightMagenta": theme.brightMagenta = color
            case "brightCyan": theme.brightCyan = color
            case "brightWhite": theme.brightWhite = color
            default: break
            }

            break
        }

        ThemeManager.shared.addTheme(theme)
        selectedTheme = theme
        updateEditor()

        // If this is the active theme, apply changes immediately to terminals
        if ProfileStorage.shared.defaultProfile.theme.name == theme.name {
            ProfileStorage.shared.setTheme(theme)
        }
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
        let isActiveTheme = ProfileStorage.shared.defaultProfile.theme.name == theme.name

        let cell = NSTableCellView()

        // Theme thumbnail with foreground color text
        let thumbnailView = NSView()
        thumbnailView.translatesAutoresizingMaskIntoConstraints = false
        thumbnailView.wantsLayer = true
        thumbnailView.layer?.cornerRadius = 4
        thumbnailView.layer?.backgroundColor = theme.background.cgColor
        thumbnailView.layer?.borderWidth = 1
        thumbnailView.layer?.borderColor = NSColor.separatorColor.cgColor

        // Mini text in thumbnail
        let miniText = NSTextField(labelWithString: ">_")
        miniText.translatesAutoresizingMaskIntoConstraints = false
        miniText.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .medium)
        miniText.textColor = theme.foreground
        miniText.isBezeled = false
        miniText.drawsBackground = false
        thumbnailView.addSubview(miniText)

        let textField = NSTextField(labelWithString: theme.name)
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.lineBreakMode = .byTruncatingTail

        if ThemeManager.shared.isBuiltIn(theme) {
            textField.textColor = .secondaryLabelColor
        }

        cell.addSubview(thumbnailView)
        cell.addSubview(textField)

        // Checkmark for active theme
        var trailingConstraint: NSLayoutConstraint
        if isActiveTheme {
            let checkmark = NSImageView()
            checkmark.translatesAutoresizingMaskIntoConstraints = false
            checkmark.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Active")
            checkmark.contentTintColor = .controlAccentColor
            cell.addSubview(checkmark)

            NSLayoutConstraint.activate([
                checkmark.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                checkmark.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                checkmark.widthAnchor.constraint(equalToConstant: 14),
                checkmark.heightAnchor.constraint(equalToConstant: 14)
            ])
            trailingConstraint = textField.trailingAnchor.constraint(equalTo: checkmark.leadingAnchor, constant: -4)
        } else {
            trailingConstraint = textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4)
        }

        NSLayoutConstraint.activate([
            thumbnailView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            thumbnailView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            thumbnailView.widthAnchor.constraint(equalToConstant: Layout.thumbnailWidth),
            thumbnailView.heightAnchor.constraint(equalToConstant: Layout.thumbnailHeight),

            miniText.centerXAnchor.constraint(equalTo: thumbnailView.centerXAnchor),
            miniText.centerYAnchor.constraint(equalTo: thumbnailView.centerYAnchor),

            textField.leadingAnchor.constraint(equalTo: thumbnailView.trailingAnchor, constant: 8),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            trailingConstraint
        ])

        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = themeTableView.selectedRow
        if row >= 0 && row < themes.count {
            selectedTheme = themes[row]
            updateEditor()
        }
    }
}

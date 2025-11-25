import AppKit

/// View controller for profile preferences (font, colors, theme).
final class ProfilePreferencesViewController: NSViewController {

    // MARK: - Constants

    private enum Layout {
        static let padding: CGFloat = 20
        static let spacing: CGFloat = 12
        static let labelWidth: CGFloat = 80
        static let previewHeight: CGFloat = 100
    }

    // MARK: - Properties

    private var currentProfile: TerminalProfile {
        didSet {
            updateUI()
            saveProfile()
        }
    }

    // MARK: - UI Elements

    private lazy var fontNameLabel: NSTextField = {
        NSTextField(labelWithString: "Font:")
    }()

    private lazy var fontButton: NSButton = {
        let button = NSButton(title: "SF Mono 13", target: self, action: #selector(showFontPanel))
        button.bezelStyle = .rounded
        return button
    }()

    private lazy var themeLabel: NSTextField = {
        NSTextField(labelWithString: "Theme:")
    }()

    private lazy var themePopup: NSPopUpButton = {
        let popup = NSPopUpButton()
        popup.target = self
        popup.action = #selector(themeChanged)

        for theme in TerminalTheme.allThemes {
            popup.addItem(withTitle: theme.name)
        }

        return popup
    }()

    private lazy var cursorStyleLabel: NSTextField = {
        NSTextField(labelWithString: "Cursor:")
    }()

    private lazy var cursorStylePopup: NSPopUpButton = {
        let popup = NSPopUpButton()
        popup.target = self
        popup.action = #selector(cursorStyleChanged)

        for style in TerminalProfile.CursorStyle.allCases {
            popup.addItem(withTitle: style.displayName)
        }

        return popup
    }()

    private lazy var cursorBlinkCheckbox: NSButton = {
        let button = NSButton(checkboxWithTitle: "Blinking cursor", target: self, action: #selector(cursorBlinkChanged))
        return button
    }()

    private lazy var scrollbackLabel: NSTextField = {
        NSTextField(labelWithString: "Scrollback:")
    }()

    private lazy var scrollbackTextField: NSTextField = {
        let field = NSTextField()
        field.placeholderString = "10000"
        field.formatter = NumberFormatter()
        field.target = self
        field.action = #selector(scrollbackChanged)
        return field
    }()

    private lazy var scrollbackSuffix: NSTextField = {
        NSTextField(labelWithString: "lines")
    }()

    private lazy var previewView: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 6
        return view
    }()

    private lazy var previewLabel: NSTextField = {
        let label = NSTextField(labelWithString: "user@mac ~ % ls -la")
        label.isBezeled = false
        label.drawsBackground = false
        label.isEditable = false
        label.isSelectable = false
        return label
    }()

    // MARK: - Initialization

    init() {
        self.currentProfile = ProfileStorage.shared.defaultProfile
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 350))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        updateUI()
    }

    // MARK: - Setup

    private func setupUI() {
        let stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = Layout.spacing
        stackView.translatesAutoresizingMaskIntoConstraints = false

        // Font row
        let fontRow = createRow(label: fontNameLabel, control: fontButton)

        // Theme row
        let themeRow = createRow(label: themeLabel, control: themePopup)

        // Cursor row
        let cursorRow = createRow(label: cursorStyleLabel, control: cursorStylePopup)

        // Scrollback row
        let scrollbackRow = NSStackView()
        scrollbackRow.orientation = .horizontal
        scrollbackRow.spacing = 8
        scrollbackLabel.translatesAutoresizingMaskIntoConstraints = false
        scrollbackLabel.widthAnchor.constraint(equalToConstant: Layout.labelWidth).isActive = true
        scrollbackTextField.translatesAutoresizingMaskIntoConstraints = false
        scrollbackTextField.widthAnchor.constraint(equalToConstant: 80).isActive = true
        scrollbackRow.addArrangedSubview(scrollbackLabel)
        scrollbackRow.addArrangedSubview(scrollbackTextField)
        scrollbackRow.addArrangedSubview(scrollbackSuffix)

        // Preview section
        let previewSectionLabel = NSTextField(labelWithString: "Preview")
        previewSectionLabel.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)

        previewView.translatesAutoresizingMaskIntoConstraints = false
        previewLabel.translatesAutoresizingMaskIntoConstraints = false
        previewView.addSubview(previewLabel)

        stackView.addArrangedSubview(fontRow)
        stackView.addArrangedSubview(themeRow)
        stackView.addArrangedSubview(cursorRow)
        stackView.addArrangedSubview(cursorBlinkCheckbox)
        stackView.addArrangedSubview(scrollbackRow)
        stackView.addArrangedSubview(createSpacer())
        stackView.addArrangedSubview(previewSectionLabel)
        stackView.addArrangedSubview(previewView)

        view.addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: view.topAnchor, constant: Layout.padding),
            stackView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Layout.padding),
            stackView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Layout.padding),

            previewView.heightAnchor.constraint(equalToConstant: Layout.previewHeight),
            previewView.widthAnchor.constraint(equalTo: stackView.widthAnchor),

            previewLabel.leadingAnchor.constraint(equalTo: previewView.leadingAnchor, constant: 10),
            previewLabel.topAnchor.constraint(equalTo: previewView.topAnchor, constant: 10)
        ])
    }

    private func createRow(label: NSTextField, control: NSView) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8

        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: Layout.labelWidth).isActive = true

        row.addArrangedSubview(label)
        row.addArrangedSubview(control)

        return row
    }

    private func createSpacer() -> NSView {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.heightAnchor.constraint(equalToConstant: Layout.spacing).isActive = true
        return spacer
    }

    // MARK: - Update UI

    private func updateUI() {
        // Font button
        fontButton.title = "\(currentProfile.fontName) \(Int(currentProfile.fontSize))"

        // Theme popup
        if let index = TerminalTheme.allThemes.firstIndex(where: { $0.name == currentProfile.theme.name }) {
            themePopup.selectItem(at: index)
        }

        // Cursor style
        if let index = TerminalProfile.CursorStyle.allCases.firstIndex(of: currentProfile.cursorStyle) {
            cursorStylePopup.selectItem(at: index)
        }

        // Cursor blink
        cursorBlinkCheckbox.state = currentProfile.cursorBlink ? .on : .off

        // Scrollback
        scrollbackTextField.integerValue = currentProfile.scrollbackLines

        // Preview
        updatePreview()
    }

    private func updatePreview() {
        previewView.layer?.backgroundColor = currentProfile.theme.background.cgColor

        previewLabel.textColor = currentProfile.theme.foreground
        previewLabel.font = NSFont.monospacedSystemFont(ofSize: currentProfile.fontSize, weight: .regular)
    }

    private func saveProfile() {
        ProfileStorage.shared.defaultProfile = currentProfile
        ProfileStorage.shared.save(currentProfile)
    }

    // MARK: - Actions

    @objc private func showFontPanel() {
        let fontManager = NSFontManager.shared
        fontManager.target = self
        fontManager.action = #selector(fontChanged(_:))

        let font = NSFont.monospacedSystemFont(ofSize: currentProfile.fontSize, weight: .regular)
        fontManager.setSelectedFont(font, isMultiple: false)

        let panel = fontManager.fontPanel(true)
        panel?.makeKeyAndOrderFront(nil)
    }

    @objc private func fontChanged(_ sender: NSFontManager) {
        let newFont = sender.convert(NSFont.systemFont(ofSize: currentProfile.fontSize))
        currentProfile.fontName = newFont.fontName
        currentProfile.fontSize = newFont.pointSize
    }

    @objc private func themeChanged() {
        let index = themePopup.indexOfSelectedItem
        guard index >= 0, index < TerminalTheme.allThemes.count else { return }
        currentProfile.theme = TerminalTheme.allThemes[index]
    }

    @objc private func cursorStyleChanged() {
        let index = cursorStylePopup.indexOfSelectedItem
        guard index >= 0, index < TerminalProfile.CursorStyle.allCases.count else { return }
        currentProfile.cursorStyle = TerminalProfile.CursorStyle.allCases[index]
    }

    @objc private func cursorBlinkChanged() {
        currentProfile.cursorBlink = cursorBlinkCheckbox.state == .on
    }

    @objc private func scrollbackChanged() {
        currentProfile.scrollbackLines = max(100, scrollbackTextField.integerValue)
    }
}

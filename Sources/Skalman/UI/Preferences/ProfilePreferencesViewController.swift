import AppKit

/// Profile preferences: font, cursor, scrollback, and a live terminal preview, built from the
/// settings UI kit (`SettingsUI`, `SettingsCard`) so the page matches the rest of the app.
final class ProfilePreferencesViewController: NSViewController {

    // MARK: - Constants

    private enum Layout {
        static let previewHeight: CGFloat = 100
    }

    // MARK: - Properties

    private var currentProfile: TerminalProfile {
        didSet {
            updateUI()
            saveProfile()
        }
    }

    private var fontButtonTitle: String {
        "\(currentProfile.fontName) \(Int(currentProfile.fontSize))"
    }

    // MARK: - Controls

    private lazy var fontButton: NSButton =
        SettingsUI.button(fontButtonTitle, target: self, action: #selector(showFontPanel))

    private lazy var cursorStylePopup: ThemedPopUp = {
        let popup = SettingsUI.popUp(target: self, action: #selector(cursorStyleChanged))
        for style in TerminalProfile.CursorStyle.allCases {
            popup.addItem(withTitle: style.displayName)
        }
        return popup
    }()

    private lazy var cursorBlinkToggle: ThemedToggle =
        SettingsUI.toggle(isOn: currentProfile.cursorBlink, target: self, action: #selector(cursorBlinkChanged))

    private lazy var scrollbackField: NSTextField = {
        let field = SettingsUI.textField(target: self, action: #selector(scrollbackChanged))
        field.placeholderString = "10000"
        field.formatter = NumberFormatter()
        return field
    }()

    private lazy var previewView: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.cornerCurve = .continuous
        view.layer?.cornerRadius = Design.Radius.control
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
        view = NSView()
        setupLayout()
        updateUI()
    }

    // MARK: - Setup

    private func setupLayout() {
        let text = SettingsCard(rows: [
            SettingsUI.row(title: "Font", control: fontButton)
        ])

        let cursor = SettingsCard(rows: [
            SettingsUI.row(title: "Style", control: cursorStylePopup),
            SettingsUI.row(title: "Blinking cursor", control: cursorBlinkToggle)
        ])

        let scrollback = SettingsCard(rows: [
            SettingsUI.row(title: "Lines kept",
                           subtitle: "Number of output lines retained above the visible screen.",
                           control: scrollbackField)
        ])

        let preview = SettingsCard(rows: [
            SettingsUI.fullRow(previewContent())
        ])

        let page = SettingsUI.page([
            SettingsUI.heading("Profiles"),
            SettingsUI.section("Text", text),
            SettingsUI.section("Cursor", cursor),
            SettingsUI.section("Scrollback", scrollback),
            SettingsUI.section("Preview", preview)
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

    /// The terminal preview: a rounded panel painted in the theme's background, holding a
    /// monospaced sample line in the theme's foreground.
    private func previewContent() -> NSView {
        previewView.translatesAutoresizingMaskIntoConstraints = false
        previewLabel.translatesAutoresizingMaskIntoConstraints = false
        previewView.addSubview(previewLabel)

        NSLayoutConstraint.activate([
            previewView.heightAnchor.constraint(equalToConstant: Layout.previewHeight),
            previewLabel.leadingAnchor.constraint(equalTo: previewView.leadingAnchor, constant: Design.Spacing.medium),
            previewLabel.topAnchor.constraint(equalTo: previewView.topAnchor, constant: Design.Spacing.medium)
        ])

        return previewView
    }

    // MARK: - Update UI

    private func updateUI() {
        fontButton.title = fontButtonTitle

        if let index = TerminalProfile.CursorStyle.allCases.firstIndex(of: currentProfile.cursorStyle) {
            cursorStylePopup.selectItem(at: index)
        }

        cursorBlinkToggle.state = currentProfile.cursorBlink ? .on : .off
        scrollbackField.integerValue = currentProfile.scrollbackLines

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

    @objc private func cursorStyleChanged() {
        let index = cursorStylePopup.indexOfSelectedItem
        guard index >= 0, index < TerminalProfile.CursorStyle.allCases.count else { return }
        currentProfile.cursorStyle = TerminalProfile.CursorStyle.allCases[index]
    }

    @objc private func cursorBlinkChanged() {
        currentProfile.cursorBlink = cursorBlinkToggle.state == .on
    }

    @objc private func scrollbackChanged() {
        currentProfile.scrollbackLines = max(100, scrollbackField.integerValue)
    }
}

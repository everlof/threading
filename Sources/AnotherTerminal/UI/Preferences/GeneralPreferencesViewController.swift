import AppKit

/// View controller for general preferences (shell, startup behavior).
final class GeneralPreferencesViewController: NSViewController {

    // MARK: - Constants

    private enum Layout {
        static let padding: CGFloat = 20
        static let spacing: CGFloat = 12
        static let labelWidth: CGFloat = 120
        static let controlWidth: CGFloat = 250
    }

    private enum UserDefaultsKeys {
        static let defaultShell = "defaultShell"
        static let openNewWindowOnLaunch = "openNewWindowOnLaunch"
        static let closeWindowOnShellExit = "closeWindowOnShellExit"
    }

    // MARK: - UI Elements

    private lazy var shellPathTextField: NSTextField = {
        let field = NSTextField()
        field.placeholderString = "/bin/bash"
        field.stringValue = UserDefaults.standard.string(forKey: UserDefaultsKeys.defaultShell) ?? TerminalDefaults.defaultShell
        field.target = self
        field.action = #selector(shellPathChanged)
        return field
    }()

    private lazy var browseButton: NSButton = {
        let button = NSButton(title: "Browse...", target: self, action: #selector(browseForShell))
        button.bezelStyle = .rounded
        return button
    }()

    private lazy var openWindowOnLaunchCheckbox: NSButton = {
        let button = NSButton(checkboxWithTitle: "Open new window on launch", target: self, action: #selector(openWindowOnLaunchChanged))
        button.state = UserDefaults.standard.bool(forKey: UserDefaultsKeys.openNewWindowOnLaunch) ? .on : .off
        return button
    }()

    private lazy var closeOnExitCheckbox: NSButton = {
        let button = NSButton(checkboxWithTitle: "Close window when shell exits", target: self, action: #selector(closeOnExitChanged))
        button.state = UserDefaults.standard.object(forKey: UserDefaultsKeys.closeWindowOnShellExit) == nil ? .on : (UserDefaults.standard.bool(forKey: UserDefaultsKeys.closeWindowOnShellExit) ? .on : .off)
        return button
    }()

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 300))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
    }

    // MARK: - Setup

    private func setupUI() {
        let stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = Layout.spacing
        stackView.translatesAutoresizingMaskIntoConstraints = false

        // Shell section
        let shellLabel = createSectionLabel("Default Shell")
        let shellRow = createShellRow()

        // Startup section
        let startupLabel = createSectionLabel("Startup")

        stackView.addArrangedSubview(shellLabel)
        stackView.addArrangedSubview(shellRow)
        stackView.addArrangedSubview(createSpacer())
        stackView.addArrangedSubview(startupLabel)
        stackView.addArrangedSubview(openWindowOnLaunchCheckbox)
        stackView.addArrangedSubview(closeOnExitCheckbox)

        view.addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: view.topAnchor, constant: Layout.padding),
            stackView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Layout.padding),
            stackView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Layout.padding)
        ])
    }

    private func createSectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        return label
    }

    private func createShellRow() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8

        shellPathTextField.translatesAutoresizingMaskIntoConstraints = false
        shellPathTextField.widthAnchor.constraint(equalToConstant: Layout.controlWidth).isActive = true

        row.addArrangedSubview(shellPathTextField)
        row.addArrangedSubview(browseButton)

        return row
    }

    private func createSpacer() -> NSView {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.heightAnchor.constraint(equalToConstant: Layout.spacing).isActive = true
        return spacer
    }

    // MARK: - Actions

    @objc private func shellPathChanged() {
        let path = shellPathTextField.stringValue
        UserDefaults.standard.set(path, forKey: UserDefaultsKeys.defaultShell)

        // Update default profile
        var profile = ProfileStorage.shared.defaultProfile
        profile.shellPath = path
        ProfileStorage.shared.defaultProfile = profile
    }

    @objc private func browseForShell() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/bin")
        panel.message = "Select a shell executable"

        panel.begin { [weak self] response in
            if response == .OK, let url = panel.url {
                self?.shellPathTextField.stringValue = url.path
                self?.shellPathChanged()
            }
        }
    }

    @objc private func openWindowOnLaunchChanged() {
        UserDefaults.standard.set(openWindowOnLaunchCheckbox.state == .on, forKey: UserDefaultsKeys.openNewWindowOnLaunch)
    }

    @objc private func closeOnExitChanged() {
        UserDefaults.standard.set(closeOnExitCheckbox.state == .on, forKey: UserDefaultsKeys.closeWindowOnShellExit)
    }
}

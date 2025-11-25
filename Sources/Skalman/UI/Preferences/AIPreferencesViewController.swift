import AppKit

/// View controller for AI preferences (provider selection, API keys).
final class AIPreferencesViewController: NSViewController {

    // MARK: - Constants

    private enum Layout {
        static let padding: CGFloat = 20
        static let spacing: CGFloat = 12
        static let labelWidth: CGFloat = 100
        static let controlWidth: CGFloat = 280
    }

    // MARK: - Properties

    private var settings: AISettings {
        get { AISettingsStorage.shared.settings }
        set {
            AISettingsStorage.shared.settings = newValue
            AIService.shared.reconfigure()
        }
    }

    // MARK: - UI Elements

    private lazy var shellIntegrationButton: NSButton = {
        let button = NSButton(title: "Copy Shell Integration Command", target: self, action: #selector(copyShellIntegration))
        button.bezelStyle = .rounded
        return button
    }()

    private lazy var shellIntegrationLabel: NSTextField = {
        let label = NSTextField(wrappingLabelWithString: "For AI output analysis, add the shell integration to your profile (.bashrc/.zshrc)")
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }()

    private lazy var autoRunCheckbox: NSButton = {
        let button = NSButton(checkboxWithTitle: "Automatically run shell integration on new windows/tabs", target: self, action: #selector(autoRunChanged))
        return button
    }()

    private lazy var providerPopup: NSPopUpButton = {
        let popup = NSPopUpButton()
        popup.target = self
        popup.action = #selector(providerChanged)

        for provider in AIProviderType.allCases {
            popup.addItem(withTitle: provider.displayName)
        }

        return popup
    }()

    private lazy var apiKeyField: NSSecureTextField = {
        let field = NSSecureTextField()
        field.placeholderString = "Enter API key"
        field.target = self
        field.action = #selector(apiKeyChanged)
        return field
    }()

    private lazy var apiKeyLabel: NSTextField = {
        let label = NSTextField(labelWithString: "API Key:")
        return label
    }()

    private lazy var apiKeyRow: NSStackView = {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }()

    private lazy var saveKeyButton: NSButton = {
        let button = NSButton(title: "Save", target: self, action: #selector(saveAPIKey))
        button.bezelStyle = .rounded
        return button
    }()

    private lazy var statusLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }()

    private lazy var testButton: NSButton = {
        let button = NSButton(title: "Test Connection", target: self, action: #selector(testConnection))
        button.bezelStyle = .rounded
        return button
    }()

    // Ollama-specific controls
    private lazy var ollamaURLField: NSTextField = {
        let field = NSTextField()
        field.placeholderString = AIDefaults.ollamaDefaultURL
        field.target = self
        field.action = #selector(ollamaSettingsChanged)
        return field
    }()

    private lazy var ollamaModelField: NSTextField = {
        let field = NSTextField()
        field.placeholderString = AIDefaults.ollamaDefaultModel
        field.target = self
        field.action = #selector(ollamaSettingsChanged)
        return field
    }()

    private lazy var ollamaSection: NSStackView = {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        return stack
    }()

    // Model selection for Claude/OpenAI
    private lazy var modelField: NSTextField = {
        let field = NSTextField()
        field.target = self
        field.action = #selector(modelChanged)
        return field
    }()

    private lazy var modelLabel: NSTextField = {
        let label = NSTextField(labelWithString: "Model:")
        return label
    }()

    private lazy var modelRow: NSStackView = {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }()

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 350))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        loadCurrentSettings()
    }

    // MARK: - Setup

    private func setupUI() {
        let stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = Layout.spacing
        stackView.translatesAutoresizingMaskIntoConstraints = false

        // Provider section
        let providerLabel = createSectionLabel("AI Provider")
        let providerRow = createProviderRow()

        // API Key section (for Claude/OpenAI)
        setupAPIKeyRow()

        // Model section
        setupModelRow()

        // Ollama section
        setupOllamaSection()

        // Status and test
        let statusRow = NSStackView()
        statusRow.orientation = .horizontal
        statusRow.spacing = 12
        statusRow.addArrangedSubview(statusLabel)
        statusRow.addArrangedSubview(testButton)

        stackView.addArrangedSubview(providerLabel)
        stackView.addArrangedSubview(providerRow)
        stackView.addArrangedSubview(createSpacer())
        stackView.addArrangedSubview(apiKeyRow)
        stackView.addArrangedSubview(modelRow)
        stackView.addArrangedSubview(ollamaSection)
        stackView.addArrangedSubview(createSpacer())
        stackView.addArrangedSubview(statusRow)
        stackView.addArrangedSubview(createSpacer())

        // Shell integration section
        let shellIntegrationSection = createSectionLabel("Shell Integration")
        stackView.addArrangedSubview(shellIntegrationSection)
        stackView.addArrangedSubview(shellIntegrationLabel)
        stackView.addArrangedSubview(autoRunCheckbox)
        stackView.addArrangedSubview(shellIntegrationButton)

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

    private func createProviderRow() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8

        let label = NSTextField(labelWithString: "Provider:")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: Layout.labelWidth).isActive = true

        providerPopup.translatesAutoresizingMaskIntoConstraints = false
        providerPopup.widthAnchor.constraint(equalToConstant: 150).isActive = true

        row.addArrangedSubview(label)
        row.addArrangedSubview(providerPopup)

        return row
    }

    private func setupAPIKeyRow() {
        apiKeyLabel.translatesAutoresizingMaskIntoConstraints = false
        apiKeyLabel.widthAnchor.constraint(equalToConstant: Layout.labelWidth).isActive = true

        apiKeyField.translatesAutoresizingMaskIntoConstraints = false
        apiKeyField.widthAnchor.constraint(equalToConstant: 180).isActive = true

        apiKeyRow.addArrangedSubview(apiKeyLabel)
        apiKeyRow.addArrangedSubview(apiKeyField)
        apiKeyRow.addArrangedSubview(saveKeyButton)
    }

    private func setupModelRow() {
        modelLabel.translatesAutoresizingMaskIntoConstraints = false
        modelLabel.widthAnchor.constraint(equalToConstant: Layout.labelWidth).isActive = true

        modelField.translatesAutoresizingMaskIntoConstraints = false
        modelField.widthAnchor.constraint(equalToConstant: Layout.controlWidth).isActive = true

        modelRow.addArrangedSubview(modelLabel)
        modelRow.addArrangedSubview(modelField)
    }

    private func setupOllamaSection() {
        let urlLabel = NSTextField(labelWithString: "Server URL:")
        urlLabel.translatesAutoresizingMaskIntoConstraints = false
        urlLabel.widthAnchor.constraint(equalToConstant: Layout.labelWidth).isActive = true

        ollamaURLField.translatesAutoresizingMaskIntoConstraints = false
        ollamaURLField.widthAnchor.constraint(equalToConstant: Layout.controlWidth).isActive = true

        let urlRow = NSStackView()
        urlRow.orientation = .horizontal
        urlRow.spacing = 8
        urlRow.addArrangedSubview(urlLabel)
        urlRow.addArrangedSubview(ollamaURLField)

        let modelLabel = NSTextField(labelWithString: "Model:")
        modelLabel.translatesAutoresizingMaskIntoConstraints = false
        modelLabel.widthAnchor.constraint(equalToConstant: Layout.labelWidth).isActive = true

        ollamaModelField.translatesAutoresizingMaskIntoConstraints = false
        ollamaModelField.widthAnchor.constraint(equalToConstant: Layout.controlWidth).isActive = true

        let ollamaModelRow = NSStackView()
        ollamaModelRow.orientation = .horizontal
        ollamaModelRow.spacing = 8
        ollamaModelRow.addArrangedSubview(modelLabel)
        ollamaModelRow.addArrangedSubview(ollamaModelField)

        ollamaSection.addArrangedSubview(urlRow)
        ollamaSection.addArrangedSubview(ollamaModelRow)
    }

    private func createSpacer() -> NSView {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.heightAnchor.constraint(equalToConstant: Layout.spacing).isActive = true
        return spacer
    }

    // MARK: - Load Settings

    private func loadCurrentSettings() {
        let settings = self.settings

        // Set provider popup
        if let index = AIProviderType.allCases.firstIndex(of: settings.providerType) {
            providerPopup.selectItem(at: index)
        }

        // Load API key status
        updateAPIKeyStatus()

        // Load model
        updateModelField()

        // Load Ollama settings
        ollamaURLField.stringValue = settings.ollamaURL
        ollamaModelField.stringValue = settings.ollamaModel

        // Load auto-run setting
        autoRunCheckbox.state = settings.autoRunShellIntegration ? .on : .off

        // Update visibility
        updateUIForProvider()
    }

    private func updateAPIKeyStatus() {
        let provider = AIProviderType.allCases[providerPopup.indexOfSelectedItem]

        if let service = KeychainManager.Service(providerType: provider) {
            if KeychainManager.hasKey(for: service) {
                apiKeyField.placeholderString = "••••••••••••"
                statusLabel.stringValue = "API key saved"
                statusLabel.textColor = .systemGreen
            } else {
                apiKeyField.placeholderString = "Enter API key"
                statusLabel.stringValue = "No API key configured"
                statusLabel.textColor = .secondaryLabelColor
            }
        }
        apiKeyField.stringValue = ""
    }

    private func updateModelField() {
        let provider = AIProviderType.allCases[providerPopup.indexOfSelectedItem]

        switch provider {
        case .claude:
            modelField.stringValue = settings.claudeModel
            modelField.placeholderString = AIDefaults.claudeDefaultModel
        case .openai:
            modelField.stringValue = settings.openaiModel
            modelField.placeholderString = AIDefaults.openaiDefaultModel
        case .ollama:
            break
        }
    }

    private func updateUIForProvider() {
        let provider = AIProviderType.allCases[providerPopup.indexOfSelectedItem]

        // Show/hide API key row
        apiKeyRow.isHidden = !provider.requiresAPIKey

        // Show/hide model row (for Claude/OpenAI)
        modelRow.isHidden = provider == .ollama

        // Show/hide Ollama section
        ollamaSection.isHidden = provider != .ollama
    }

    // MARK: - Actions

    @objc private func providerChanged() {
        let provider = AIProviderType.allCases[providerPopup.indexOfSelectedItem]
        var currentSettings = settings
        currentSettings.providerType = provider
        settings = currentSettings

        updateUIForProvider()
        updateAPIKeyStatus()
        updateModelField()
    }

    @objc private func apiKeyChanged() {
        // Only save when Save button is pressed
    }

    @objc private func saveAPIKey() {
        let key = apiKeyField.stringValue
        guard !key.isEmpty else { return }

        let provider = AIProviderType.allCases[providerPopup.indexOfSelectedItem]
        guard let service = KeychainManager.Service(providerType: provider) else { return }

        do {
            try KeychainManager.saveKey(key, for: service)
            updateAPIKeyStatus()
            AIService.shared.reconfigure()

            statusLabel.stringValue = "API key saved successfully"
            statusLabel.textColor = .systemGreen
        } catch {
            statusLabel.stringValue = "Failed to save API key"
            statusLabel.textColor = .systemRed
        }
    }

    @objc private func modelChanged() {
        let provider = AIProviderType.allCases[providerPopup.indexOfSelectedItem]
        var currentSettings = settings

        switch provider {
        case .claude:
            currentSettings.claudeModel = modelField.stringValue.isEmpty ? AIDefaults.claudeDefaultModel : modelField.stringValue
        case .openai:
            currentSettings.openaiModel = modelField.stringValue.isEmpty ? AIDefaults.openaiDefaultModel : modelField.stringValue
        case .ollama:
            break
        }

        settings = currentSettings
    }

    @objc private func ollamaSettingsChanged() {
        var currentSettings = settings
        currentSettings.ollamaURL = ollamaURLField.stringValue.isEmpty ? AIDefaults.ollamaDefaultURL : ollamaURLField.stringValue
        currentSettings.ollamaModel = ollamaModelField.stringValue.isEmpty ? AIDefaults.ollamaDefaultModel : ollamaModelField.stringValue
        settings = currentSettings
    }

    @objc private func autoRunChanged() {
        var currentSettings = settings
        currentSettings.autoRunShellIntegration = autoRunCheckbox.state == .on
        settings = currentSettings
    }

    @objc private func copyShellIntegration() {
        let command = ShellIntegration.sourceCommand
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)

        // Show feedback
        let originalTitle = shellIntegrationButton.title
        shellIntegrationButton.title = "Copied!"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.shellIntegrationButton.title = originalTitle
        }
    }

    @objc private func testConnection() {
        statusLabel.stringValue = "Testing..."
        statusLabel.textColor = .secondaryLabelColor
        testButton.isEnabled = false

        let provider = AIProviderType.allCases[providerPopup.indexOfSelectedItem]

        Task {
            let success: Bool

            switch provider {
            case .ollama:
                let ollama = OllamaProvider(
                    baseURL: ollamaURLField.stringValue.isEmpty ? AIDefaults.ollamaDefaultURL : ollamaURLField.stringValue,
                    model: ollamaModelField.stringValue.isEmpty ? AIDefaults.ollamaDefaultModel : ollamaModelField.stringValue
                )
                success = await ollama.testConnection()

            case .claude, .openai:
                // For API-based providers, just check if the key is set
                if let service = KeychainManager.Service(providerType: provider) {
                    success = KeychainManager.hasKey(for: service)
                } else {
                    success = false
                }
            }

            await MainActor.run {
                testButton.isEnabled = true
                if success {
                    statusLabel.stringValue = "Connection successful"
                    statusLabel.textColor = .systemGreen
                } else {
                    statusLabel.stringValue = "Connection failed"
                    statusLabel.textColor = .systemRed
                }
            }
        }
    }
}

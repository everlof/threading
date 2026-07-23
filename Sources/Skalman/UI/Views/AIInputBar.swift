import AppKit

/// Input bar for AI prompt mode.
final class AIInputBar: NSView {

    // MARK: - Constants

    private enum Layout {
        static let height: CGFloat = 40
        static let padding: CGFloat = 12
        static let spacing: CGFloat = 8
        static let inputFieldMinWidth: CGFloat = 300
    }

    // MARK: - Properties

    var onSubmit: ((String) -> Void)?
    var onCancel: (() -> Void)?

    private var isLoading: Bool = false {
        didSet {
            updateLoadingState()
        }
    }

    // MARK: - UI Elements

    private lazy var providerLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        label.textColor = Design.Text.secondary
        label.setContentHuggingPriority(.required, for: .horizontal)
        return label
    }()

    private lazy var inputField: NSTextField = {
        let field = ThemedTextField()
        field.placeholderString = "Ask AI to generate a command..."
        field.font = NSFont.systemFont(ofSize: 13)
        field.delegate = self
        field.focusRingType = .none
        return field
    }()

    private lazy var submitButton: ThemedButton = {
        let button = ThemedButton(symbol: "arrow.up.circle.fill", accessibility: "Submit", target: self, action: #selector(submit))
        button.isBordered = false
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }()

    private lazy var cancelButton: ThemedButton = {
        let button = ThemedButton(symbol: "xmark.circle", accessibility: "Cancel", target: self, action: #selector(cancel))
        button.isBordered = false
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }()

    private lazy var loadingIndicator: ThemedSpinner = {
        let indicator = ThemedSpinner()
        indicator.isHidden = true
        return indicator
    }()

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    // MARK: - Setup

    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = Design.Surface.elevated.cgColor

        // Add a subtle top border
        let borderLayer = CALayer()
        borderLayer.backgroundColor = Design.Surface.border.cgColor
        borderLayer.frame = CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
        borderLayer.autoresizingMask = [.layerWidthSizable, .layerMinYMargin]
        layer?.addSublayer(borderLayer)

        let stackView = NSStackView()
        stackView.orientation = .horizontal
        stackView.spacing = Layout.spacing
        stackView.alignment = .centerY
        stackView.translatesAutoresizingMaskIntoConstraints = false

        inputField.translatesAutoresizingMaskIntoConstraints = false
        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false

        stackView.addArrangedSubview(providerLabel)
        stackView.addArrangedSubview(inputField)
        stackView.addArrangedSubview(loadingIndicator)
        stackView.addArrangedSubview(submitButton)
        stackView.addArrangedSubview(cancelButton)

        addSubview(stackView)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Layout.height),

            stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Layout.padding),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Layout.padding),
            stackView.centerYAnchor.constraint(equalTo: centerYAnchor),

            inputField.widthAnchor.constraint(greaterThanOrEqualToConstant: Layout.inputFieldMinWidth)
        ])

        updateProviderLabel()
    }

    // MARK: - Public Methods

    func focus() {
        window?.makeFirstResponder(inputField)
    }

    func clear() {
        inputField.stringValue = ""
    }

    func setLoading(_ loading: Bool) {
        isLoading = loading
    }

    func updateProviderLabel() {
        if let name = AIService.shared.providerName {
            providerLabel.stringValue = name
            providerLabel.isHidden = false
        } else {
            providerLabel.stringValue = "Not configured"
            providerLabel.textColor = Design.Status.warning
            providerLabel.isHidden = false
        }
    }

    // MARK: - Private Methods

    private func updateLoadingState() {
        inputField.isEnabled = !isLoading
        submitButton.isHidden = isLoading
        loadingIndicator.isHidden = !isLoading

        if isLoading {
            loadingIndicator.isAnimating = true
        } else {
            loadingIndicator.isAnimating = false
        }
    }

    // MARK: - Actions

    @objc private func submit() {
        let text = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        onSubmit?(text)
    }

    @objc private func cancel() {
        clear()
        onCancel?()
    }
}

// MARK: - NSTextFieldDelegate

extension AIInputBar: NSTextFieldDelegate {

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(insertNewline(_:)) {
            submit()
            return true
        } else if commandSelector == #selector(cancelOperation(_:)) {
            cancel()
            return true
        }
        return false
    }
}

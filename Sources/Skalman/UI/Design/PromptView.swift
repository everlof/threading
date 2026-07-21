import AppKit

/// A primary text input: a rounded container holding the field and its submit control.
///
/// Built as a container rather than a bordered `NSTextField` so the submit affordance can sit
/// inside it, which is what makes the whole thing read as one input rather than a form row.
final class PromptView: NSView {

    // MARK: - Properties

    private let textField = NSTextField()
    private let submitButton = NSButton()

    /// Called when the prompt is submitted, by Return or by the button.
    var onSubmit: ((String) -> Void)?

    /// Placeholder shown while empty. Set before the view is added.
    var placeholder: String = "" {
        didSet { textField.placeholderString = placeholder }
    }

    var stringValue: String {
        get { textField.stringValue }
        set {
            textField.stringValue = newValue
            updateSubmitState()
        }
    }

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setupViews() {
        applySurface(
            fill: Design.Surface.panel,
            radius: Design.Radius.panel,
            border: Design.Surface.border
        )

        // Borderless: the container draws the frame, so the field itself must not.
        textField.isBordered = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.font = Design.Typography.body()
        textField.placeholderString = placeholder
        textField.delegate = self
        textField.target = self
        textField.action = #selector(submit)
        textField.translatesAutoresizingMaskIntoConstraints = false

        submitButton.image = NSImage(
            systemSymbolName: DesignSymbols.submit,
            accessibilityDescription: "Start session"
        )
        submitButton.isBordered = false
        submitButton.bezelStyle = .inline
        submitButton.contentTintColor = .tertiaryLabelColor
        submitButton.target = self
        submitButton.action = #selector(submit)
        submitButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(textField)
        addSubview(submitButton)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Design.Size.inputHeight),

            textField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Design.Spacing.inset),
            textField.centerYAnchor.constraint(equalTo: centerYAnchor),
            textField.trailingAnchor.constraint(
                equalTo: submitButton.leadingAnchor,
                constant: -Design.Spacing.inset
            ),

            submitButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Design.Spacing.inset),
            submitButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            submitButton.widthAnchor.constraint(equalToConstant: PromptViewDefaults.submitSize),
            submitButton.heightAnchor.constraint(equalToConstant: PromptViewDefaults.submitSize)
        ])
    }

    // MARK: - Public Methods

    func focus() {
        window?.makeFirstResponder(textField)
    }

    // MARK: - Actions

    @objc private func submit() {
        onSubmit?(textField.stringValue)
    }

    /// The submit control brightens once there is something to send, which is the only cue
    /// that Return will do anything.
    private func updateSubmitState() {
        let hasText = !textField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty

        submitButton.contentTintColor = hasText ? Design.Surface.accent : .tertiaryLabelColor
    }
}

// MARK: - NSTextFieldDelegate

extension PromptView: NSTextFieldDelegate {

    func controlTextDidChange(_ obj: Notification) {
        updateSubmitState()
    }
}

// MARK: - Prompt View Defaults

enum PromptViewDefaults {
    static let submitSize: CGFloat = 18
}

import AppKit

/// Placeholder shown in the terminal pane when no live terminal is on screen.
///
/// Covers both the empty selection state and a dormant session that has exited and can
/// be resumed.
final class SessionPlaceholderView: NSView {

    // MARK: - Properties

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let actionButton = NSButton()

    /// Invoked when the action button is clicked. The button is hidden when nil.
    var onAction: (() -> Void)? {
        didSet { actionButton.isHidden = onAction == nil }
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
        let stack = NSStackView(views: [iconView, titleLabel, detailLabel, actionButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = PlaceholderDefaults.stackSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.setCustomSpacing(PlaceholderDefaults.iconSpacing, after: iconView)
        stack.setCustomSpacing(PlaceholderDefaults.buttonSpacing, after: detailLabel)

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.contentTintColor = .tertiaryLabelColor

        titleLabel.font = .systemFont(ofSize: PlaceholderDefaults.titleFontSize, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.alignment = .center

        detailLabel.font = .systemFont(ofSize: PlaceholderDefaults.detailFontSize)
        detailLabel.textColor = .tertiaryLabelColor
        detailLabel.alignment = .center

        actionButton.bezelStyle = .rounded
        actionButton.controlSize = .large
        actionButton.target = self
        actionButton.action = #selector(actionButtonClicked)
        actionButton.isHidden = true

        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -PlaceholderDefaults.horizontalInset),
            iconView.widthAnchor.constraint(equalToConstant: PlaceholderDefaults.iconSize),
            iconView.heightAnchor.constraint(equalToConstant: PlaceholderDefaults.iconSize)
        ])
    }

    // MARK: - Public Methods

    /// Configures the placeholder's content. Pass `actionTitle` as nil to hide the button.
    func configure(
        symbolName: String,
        title: String,
        detail: String,
        actionTitle: String? = nil
    ) {
        iconView.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: title
        )
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
        detailLabel.isHidden = detail.isEmpty

        if let actionTitle {
            actionButton.title = actionTitle
        }
    }

    // MARK: - Private Methods

    @objc private func actionButtonClicked() {
        onAction?()
    }
}

// MARK: - Placeholder Defaults

enum PlaceholderDefaults {
    static let stackSpacing: CGFloat = 6
    static let iconSpacing: CGFloat = 16
    static let buttonSpacing: CGFloat = 20
    static let iconSize: CGFloat = 44
    static let titleFontSize: CGFloat = 15
    static let detailFontSize: CGFloat = 12
    static let horizontalInset: CGFloat = 80
}

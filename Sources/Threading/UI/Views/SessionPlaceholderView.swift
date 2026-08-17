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
    private let actionButton = ThemedButton()

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
        // Title and detail as one announcement cluster, so the seam before the button is
        // recorded after a member that is always there — hung on the hideable detail label it
        // left with it, and a detail-less placeholder collapsed the gap to the base spacing.
        // The rhythm is `Design.Placeholder`'s, stated once for every empty-state surface.
        let announcement = NSStackView(views: [titleLabel, detailLabel])
        announcement.orientation = .vertical
        announcement.alignment = .centerX
        announcement.spacing = Design.Placeholder.line

        let stack = NSStackView(views: [iconView, announcement, actionButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = Design.Placeholder.line
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.setCustomSpacing(Design.Placeholder.afterIcon, after: iconView)
        stack.setCustomSpacing(Design.Placeholder.section, after: announcement)

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.contentTintColor = Design.Text.tertiary

        titleLabel.applyFont(.placeholderTitle)
        titleLabel.textColor = Design.Text.secondary
        titleLabel.alignment = .center

        detailLabel.applyFont(.subheading)
        detailLabel.textColor = Design.Text.tertiary
        detailLabel.alignment = .center

        actionButton.isProminent = true
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
    static let iconSize: CGFloat = 44
    static let titleFontSize: CGFloat = 15
    static let detailFontSize: CGFloat = 12
    static let horizontalInset: CGFloat = 80
}

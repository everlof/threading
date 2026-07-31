import AppKit

/// A user bubble long enough to collapse: eight rendered lines behind a fade, with the
/// controls a long message actually needs — show the rest, and copy it whole.
///
/// t3code's long-user-message treatment. The fade is a real mask on the text rather than an
/// overlay painted on top, so it works on any bubble fill; copy always copies the full
/// message, collapsed or not — the visible prefix is a view decision, not the content.
final class UserMessageBubbleView: NSView {

    // MARK: - Properties

    private let text: String

    private lazy var label: NSTextField = {
        let label = NSTextField(wrappingLabelWithString: text)
        label.applyFont(.body, in: .conversation)
        label.textColor = Design.Text.label
        label.isSelectable = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.maximumNumberOfLines = ConversationDefaults.longMessageLineCap
        label.wantsLayer = true
        return label
    }()
    private lazy var toggleButton = ThemedButton(
        title: L10n.string("Show full message"),
        target: self,
        action: #selector(toggleExpansion)
    )
    private lazy var copyButton: ThemedButton = {
        let button = ThemedButton(
            title: L10n.string("Copy"),
            target: self,
            action: #selector(copyMessage)
        )
        button.toolTip = L10n.string("Copy the whole message")
        return button
    }()
    private var fade: CAGradientLayer?

    private var isExpanded = false

    // MARK: - Initialization

    init(text: String) {
        self.text = text
        super.init(frame: .zero)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setupViews() {
        translatesAutoresizingMaskIntoConstraints = false
        applySurface(fill: Design.Chat.bubbleFill, radius: .panel)

        toggleButton.isBordered = false

        copyButton.isBordered = false

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let footer = NSStackView(views: [toggleButton, spacer, copyButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = Design.Spacing.small
        footer.translatesAutoresizingMaskIntoConstraints = false

        addSubview(label)
        addSubview(footer)

        let pad = Design.Spacing.medium
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: pad),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),

            footer.topAnchor.constraint(equalTo: label.bottomAnchor, constant: Design.Spacing.tight),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Design.Spacing.small)
        ])

        installFade()
        setAccessibilityLabel(L10n.string("Long message, collapsed"))
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        fade?.frame = label.bounds
    }

    // MARK: - Private Methods

    /// An alpha mask over the last stretch of the visible text, saying "there is more"
    /// without a single pixel of new ink. Mask colours are alpha only — no theme colour
    /// becomes a layer colour here.
    private func installFade() {
        let gradient = CAGradientLayer()
        gradient.colors = [
            NSColor.white.cgColor,
            NSColor.white.cgColor,
            NSColor.clear.cgColor
        ]
        // Empirically, unit-point y = 0 is the *first* line here and y = 1 the last — the
        // label's backing layer takes the view hierarchy's flipped geometry. The first cut
        // reasoned from unflipped CALayer coordinates and faded the opening line; the render
        // pass is what caught it.
        gradient.locations = UserBubbleDefaults.fadeStops
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
        label.layer?.mask = gradient
        fade = gradient
    }

    @objc private func toggleExpansion() {
        isExpanded.toggle()

        label.maximumNumberOfLines = isExpanded ? 0 : ConversationDefaults.longMessageLineCap
        if isExpanded {
            label.layer?.mask = nil
            fade = nil
        } else {
            installFade()
        }
        toggleButton.title = isExpanded
            ? L10n.string("Show less")
            : L10n.string("Show full message")
        setAccessibilityLabel(
            isExpanded
                ? L10n.string("Long message")
                : L10n.string("Long message, collapsed")
        )

        invalidateIntrinsicContentSize()
        superview?.needsLayout = true
    }

    /// The whole message, not the visible prefix.
    @objc private func copyMessage() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - User Bubble Defaults

enum UserBubbleDefaults {
    /// Where the fade begins and ends, as fractions of the visible text's height — the last
    /// quarter softens, so roughly the final two capped lines say "there is more".
    static let fadeStops: [NSNumber] = [0, 0.75, 1]
}

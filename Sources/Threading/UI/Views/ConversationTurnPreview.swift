import AppKit

// MARK: - Conversation Turn Preview

/// What one exchange was about, shown beside the mark the pointer is on.
///
/// A rail of marks tells you how many turns there are and where you are among them, but not
/// which one you want — so without this the only way to find a turn is to jump to it and read.
/// The card answers that in place: what was asked, and what the agent finally said about it.
///
/// Both lines are truncated hard. This is a glance while the pointer moves, not a reading
/// surface; the conversation itself is one click away and is where the whole answer lives.
final class ConversationTurnPreview: NSView {

    // MARK: - Properties

    private let userLabel = NSTextField(labelWithString: "")
    private let assistantLabel = NSTextField(labelWithString: "")

    // MARK: - Initialization

    init() {
        super.init(frame: .zero)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setupViews() {
        applySurface(fill: Design.Surface.panel, radius: .panel)

        // The card floats over the conversation, so it needs a shadow to read as *over* rather
        // than as another row that has lost its place in the column.
        shadow = NSShadow()
        applyLayerShadow(NSColor.black.withAlphaComponent(0.28))
        layer?.shadowOpacity = 1
        layer?.shadowRadius = 12
        layer?.shadowOffset = .zero

        userLabel.applyFont(.body, in: .conversation)
        userLabel.textColor = Design.Text.label
        userLabel.lineBreakMode = .byTruncatingTail
        userLabel.maximumNumberOfLines = PreviewDefaults.userLines

        assistantLabel.applyFont(.subheading, in: .conversation)
        assistantLabel.textColor = Design.Text.secondary
        assistantLabel.lineBreakMode = .byTruncatingTail
        assistantLabel.maximumNumberOfLines = PreviewDefaults.assistantLines

        let stack = NSStackView(views: [userLabel, assistantLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.tight
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let pad = Design.Spacing.inset
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: pad),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -pad),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            widthAnchor.constraint(equalToConstant: PreviewDefaults.width)
        ])
    }

    // MARK: - Public Methods

    func configure(userText: String, assistantText: String?) {
        userLabel.stringValue = userText

        // A turn still in flight has no conclusion yet, and an empty second line would read as
        // the agent having said nothing rather than as not having finished.
        assistantLabel.stringValue = assistantText ?? PreviewDefaults.pending
        assistantLabel.textColor = assistantText == nil ? Design.Text.tertiary : Design.Text.secondary
    }
}

// MARK: - Preview Defaults

enum PreviewDefaults {
    static let width: CGFloat = 300
    static let userLines = 2
    static let assistantLines = 3
    static var pending: String { L10n.string("Still working…") }
}

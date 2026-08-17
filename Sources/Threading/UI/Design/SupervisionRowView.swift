import AppKit

/// One virtualized row in a manager's Chats surface.
final class SupervisionRowView: ThemedControl {
    struct Model {
        let title: String
        let agentImage: NSImage?
        let activity: String
        let brief: String
        let event: String
        let accessibility: String
    }

    private let hover = HoverTrackingView()
    private let agent = GlyphView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let activityLabel = NSTextField(labelWithString: "")
    private let briefLabel = NSTextField(labelWithString: "")
    private let eventLabel = NSTextField(labelWithString: "")
    private let actions = NSStackView()
    private let openButton = ThemedIconButton(
        symbolName: "arrow.up.forward.app",
        accessibility: L10n.string("Open chat"),
        target: .inline
    )
    private let messageButton = ThemedIconButton(
        symbolName: "bubble.left",
        accessibility: L10n.string("Message chat"),
        target: .inline
    )
    private let archiveButton = ThemedIconButton(
        symbolName: "archivebox",
        accessibility: L10n.string("Archive chat"),
        target: .inline
    )
    private let releaseButton = ThemedIconButton(
        symbolName: "person.badge.minus",
        accessibility: L10n.string("Release chat"),
        target: .inline
    )

    var onOpen: (() -> Void)?
    var onMessage: (() -> Void)?
    var onArchive: (() -> Void)?
    var onRelease: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        build()
    }

    convenience init() { self.init(frame: .zero) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ model: Model) {
        agent.clearSymbol()
        agent.image = model.agentImage
        agent.slot = NSSize(width: 18, height: 18)
        agent.tint = Design.Text.secondary
        titleLabel.stringValue = model.title
        activityLabel.stringValue = model.activity
        briefLabel.stringValue = model.brief
        eventLabel.stringValue = model.event
        setAccessibilityLabel(model.accessibility)
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .button }

    override func accessibilityPerformPress() -> Bool {
        guard let onOpen else { return false }
        onOpen()
        return true
    }

    private func build() {
        titleLabel.applyFont(.subheading)
        titleLabel.textColor = Design.Text.label
        titleLabel.lineBreakMode = .byTruncatingTail
        activityLabel.applyFont(.caption)
        activityLabel.textColor = Design.Text.secondary
        activityLabel.setContentHuggingPriority(.required, for: .horizontal)
        briefLabel.applyFont(.detail())
        briefLabel.textColor = Design.Text.secondary
        briefLabel.lineBreakMode = .byTruncatingTail
        eventLabel.applyFont(.caption)
        eventLabel.textColor = Design.Text.quaternary
        eventLabel.lineBreakMode = .byTruncatingTail

        let titleRow = NSStackView(views: [titleLabel, activityLabel])
        titleRow.orientation = .horizontal
        titleRow.alignment = .firstBaseline
        titleRow.spacing = Design.Spacing.small
        let text = NSStackView(views: [titleRow, briefLabel, eventLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = Design.Spacing.hairline

        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = Design.Spacing.hairline
        [openButton, messageButton, archiveButton, releaseButton].forEach(actions.addArrangedSubview)
        actions.alphaValue = 0

        hover.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hover)
        hover.addSubview(agent)
        hover.addSubview(text)
        hover.addSubview(actions)
        [text, actions].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }

        let inset = Design.Spacing.medium
        NSLayoutConstraint.activate([
            hover.topAnchor.constraint(equalTo: topAnchor),
            hover.bottomAnchor.constraint(equalTo: bottomAnchor),
            hover.leadingAnchor.constraint(equalTo: leadingAnchor),
            hover.trailingAnchor.constraint(equalTo: trailingAnchor),
            agent.leadingAnchor.constraint(equalTo: hover.leadingAnchor, constant: inset),
            agent.centerYAnchor.constraint(equalTo: hover.centerYAnchor),
            agent.widthAnchor.constraint(equalToConstant: 18),
            agent.heightAnchor.constraint(equalToConstant: 18),
            text.leadingAnchor.constraint(equalTo: agent.trailingAnchor, constant: inset),
            text.centerYAnchor.constraint(equalTo: hover.centerYAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -inset),
            actions.trailingAnchor.constraint(equalTo: hover.trailingAnchor, constant: -inset),
            actions.centerYAnchor.constraint(equalTo: hover.centerYAnchor),
        ])

        hover.onHoverChange = { [weak self] inside in
            self?.actions.animator().alphaValue = inside ? 1 : 0
        }
        openButton.onPress = { [weak self] in self?.onOpen?() }
        messageButton.onPress = { [weak self] in self?.onMessage?() }
        archiveButton.onPress = { [weak self] in self?.onArchive?() }
        releaseButton.onPress = { [weak self] in self?.onRelease?() }
    }
}

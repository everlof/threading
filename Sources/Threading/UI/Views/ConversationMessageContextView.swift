import AppKit

/// Adds one quiet action menu and durable context receipts to a conversation message without
/// changing the message renderer itself.
final class ConversationMessageContextView: NSView {

    enum Speaker {
        case user
        case agent

        var actionTitle: String {
            switch self {
            case .user: return L10n.string("Your message actions")
            case .agent: return L10n.string("Agent response actions")
            }
        }

        var referenceTitle: String {
            switch self {
            case .user: return L10n.string("Add message to chat")
            case .agent: return L10n.string("Add response to chat")
            }
        }
    }

    private let speaker: Speaker
    let content: NSView
    private let contextRail = ConversationContextRailView(mode: .transcript)
    private let actionButton: ThemedIconButton
    private var menuSession: AnyObject?

    var onReferenceMessage: (() -> Void)?
    var onCommentMessage: (() -> Void)?
    var onReferenceContext: ((ConversationContextAttachment) -> Void)? {
        didSet { contextRail.onReference = onReferenceContext }
    }
    var onCommentContext: ((ConversationContextAttachment) -> Void)? {
        didSet { contextRail.onComment = onCommentContext }
    }
    var isContextOpenable: ((ConversationContextAttachment) -> Bool)? {
        didSet { contextRail.isOpenable = isContextOpenable }
    }
    var onOpenContext: ((ConversationContextAttachment) -> Void)? {
        didSet { contextRail.onOpen = onOpenContext }
    }

    init(
        content: NSView,
        speaker: Speaker,
        context: [ConversationContextAttachment] = []
    ) {
        self.content = content
        self.speaker = speaker
        actionButton = ThemedIconButton(
            symbolName: "ellipsis",
            accessibility: speaker.actionTitle,
            target: .inline,
            inkSource: .backdrop
        )
        super.init(frame: .zero)
        setup(context: context)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup(context: [ConversationContextAttachment]) {
        translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let actionRow = NSStackView(views: [spacer, actionButton])
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.translatesAutoresizingMaskIntoConstraints = false

        let column = NSStackView(views: [contextRail, content, actionRow])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = Design.Spacing.tight
        column.detachesHiddenViews = true
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)

        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            contextRail.trailingAnchor.constraint(lessThanOrEqualTo: column.trailingAnchor),
            content.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            actionRow.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            actionRow.trailingAnchor.constraint(equalTo: column.trailingAnchor)
        ])

        actionButton.presentsMenu = true
        actionButton.onPress = { [weak self] in self?.presentActions() }
        contextRail.setAttachments(context)
    }

    private func presentActions() {
        guard menuSession == nil else { return }
        let entries: [ThemedMenuEntry] = [
            .item(ThemedMenuItem(
                title: speaker.referenceTitle,
                onChoose: { [weak self] in self?.onReferenceMessage?() }
            )),
            .item(ThemedMenuItem(
                title: L10n.string("Comment…"),
                onChoose: { [weak self] in self?.onCommentMessage?() }
            ))
        ]
        menuSession = ThemedMenuPresenter.present(
            ThemedMenuPresentation(entries: entries, minimumWidth: 180),
            from: actionButton,
            selectedEntryIndex: nil,
            onChoose: { _, item in item.onChoose?() },
            onDismiss: { [weak self] in self?.menuSession = nil }
        )
    }
}

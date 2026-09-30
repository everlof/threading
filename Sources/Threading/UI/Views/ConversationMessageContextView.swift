import AppKit

/// Adds quiet message actions — Copy, and a menu for the rest — and durable context receipts to
/// a conversation message without changing the message renderer itself.
///
/// The actions are **quiet until relevant**: they keep their line under the message, so nothing
/// reflows when they appear, but draw only while the pointer is over the message, a menu from
/// them is open, or a copy is being confirmed. Drawn permanently, an ellipsis under every
/// message was the most repeated mark in the transcript — more of them on screen than
/// paragraphs — and it made the conversation read as a list of records rather than as an
/// exchange. Hidden by alpha, not by `isHidden`, so VoiceOver and a pointer that already knows
/// where they are still reach them.
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
    private let copyButton: ThemedIconButton
    private let actionButton: ThemedIconButton
    private let actionRow = NSStackView()
    private var menuSession: AnyObject? {
        didSet { updateActionPresence() }
    }
    private var hoverTrackingArea: NSTrackingArea?
    private var isPointerOverMessage = false
    private var copyConfirmation: DispatchWorkItem?

    /// What Copy puts on the pasteboard: the message's source, not its rendering. Nil withdraws
    /// the button.
    var copyText: String? {
        didSet { copyButton.isHidden = copyText == nil }
    }

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
        copyButton = ThemedIconButton(
            symbolName: ConversationMessageContextDefaults.copySymbol,
            accessibility: L10n.string("Copy"),
            target: .inline,
            inkSource: .backdrop
        )
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
        for view in [spacer, copyButton, actionButton] { actionRow.addArrangedSubview(view) }
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.spacing = Design.Spacing.hairline
        actionRow.detachesHiddenViews = true
        actionRow.translatesAutoresizingMaskIntoConstraints = false
        actionRow.alphaValue = 0
        copyButton.isHidden = true

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
        copyButton.onPress = { [weak self] in self?.copyMessage() }
        contextRail.setAttachments(context)
    }

    // MARK: - Presence

    /// Whether the actions are drawn — see the type's note on quiet until relevant.
    var showsActions: Bool {
        isPointerOverMessage || menuSession != nil || copyConfirmation != nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerOverMessage = true
        updateActionPresence()
    }

    override func mouseExited(with event: NSEvent) {
        isPointerOverMessage = false
        updateActionPresence()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // A recycled row is not told the pointer left; start every placement quiet.
        if window == nil {
            isPointerOverMessage = false
            updateActionPresence(animated: false)
        }
    }

    private func updateActionPresence(animated: Bool = true) {
        let alpha: CGFloat = showsActions ? 1 : 0
        guard actionRow.alphaValue != alpha else { return }
        guard animated, window != nil else {
            actionRow.alphaValue = alpha
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = showsActions ? Design.Motion.appear : Design.Motion.vanish
            actionRow.animator().alphaValue = alpha
        }
    }

    // MARK: - Actions

    /// Copies the whole message and says so on the button for a beat, the acknowledgement a
    /// copy otherwise lacks: nothing on screen changes when the pasteboard does.
    private func copyMessage() {
        guard let copyText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copyText, forType: .string)

        copyConfirmation?.cancel()
        copyButton.setSymbol(
            ConversationMessageContextDefaults.copiedSymbol,
            accessibility: L10n.string("Copied")
        )
        let restore = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.copyConfirmation = nil
            self.copyButton.setSymbol(
                ConversationMessageContextDefaults.copySymbol,
                accessibility: L10n.string("Copy")
            )
            self.updateActionPresence()
        }
        copyConfirmation = restore
        updateActionPresence()
        DispatchQueue.main.asyncAfter(
            deadline: .now() + ConversationMessageContextDefaults.copiedHold,
            execute: restore
        )
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

// MARK: - Defaults

enum ConversationMessageContextDefaults {
    static let copySymbol = "doc.on.doc"
    static let copiedSymbol = "checkmark"

    /// How long the button says "Copied" before it is Copy again: long enough to be seen by a
    /// reader whose eye went to the button, short enough that a second copy finds it ready.
    static let copiedHold: TimeInterval = 1.4
}

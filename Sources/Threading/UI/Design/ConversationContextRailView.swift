import AppKit

/// Compact receipts for references and review comments.
///
/// The same component appears in the composer and on the sent user message. Its menu provides
/// progressive disclosure, keeping a batch of twenty line comments to two quiet count pills.
final class ConversationContextRailView: NSView {

    enum Mode {
        case composer
        case transcript
    }

    private let stack = NSStackView()
    private let mode: Mode

    private(set) var attachments: [ConversationContextAttachment] = []

    var onRemove: ((ConversationContextAttachment) -> Void)?
    var onReference: ((ConversationContextAttachment) -> Void)?
    var onComment: ((ConversationContextAttachment) -> Void)?

    init(mode: Mode) {
        self.mode = mode
        super.init(frame: .zero)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Design.Spacing.small
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        isHidden = true
    }

    func setAttachments(_ values: [ConversationContextAttachment]) {
        attachments = ConversationContextPolicy.normalized(values)
        rebuild()
    }

    private func rebuild() {
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        for kind in ConversationContextAttachment.Kind.allCases {
            let values = attachments.filter { $0.kind == kind }
            guard !values.isEmpty else { continue }

            let chip = ChipView()
            chip.configure(symbolName: symbol(for: kind), title: title(for: kind, count: values.count))
            chip.itemsProvider = { [weak self] in
                self?.entries(for: values) ?? []
            }
            stack.addArrangedSubview(chip)
        }
        isHidden = attachments.isEmpty
    }

    private func entries(
        for values: [ConversationContextAttachment]
    ) -> [ThemedMenuEntry] {
        values.map { attachment in
            let actions = actions(for: attachment)
            return .item(ThemedMenuItem(
                title: attachment.title,
                subtitle: attachment.presentationDetail,
                isEnabled: !actions.isEmpty,
                submenu: actions.isEmpty ? nil : actions
            ))
        }
    }

    private func actions(for attachment: ConversationContextAttachment) -> [ThemedMenuEntry] {
        switch mode {
        case .composer:
            var actions: [ThemedMenuEntry] = []
            if attachment.kind == .reference, onComment != nil {
                actions.append(.item(ThemedMenuItem(
                    title: L10n.string("Comment…"),
                    onChoose: { [weak self] in self?.onComment?(attachment) }
                )))
            }
            if onRemove != nil {
                actions.append(.item(ThemedMenuItem(
                    title: L10n.string("Remove from prompt"),
                    onChoose: { [weak self] in self?.onRemove?(attachment) }
                )))
            }
            return actions

        case .transcript:
            var actions: [ThemedMenuEntry] = []
            if onReference != nil {
                actions.append(.item(ThemedMenuItem(
                    title: L10n.string("Add to chat"),
                    onChoose: { [weak self] in self?.onReference?(attachment) }
                )))
            }
            if onComment != nil {
                actions.append(.item(ThemedMenuItem(
                    title: L10n.string("Comment…"),
                    onChoose: { [weak self] in self?.onComment?(attachment) }
                )))
            }
            return actions
        }
    }

    private func symbol(for kind: ConversationContextAttachment.Kind) -> String {
        switch kind {
        case .reference: return "quote.bubble"
        case .comment: return "text.bubble"
        }
    }

    private func title(for kind: ConversationContextAttachment.Kind, count: Int) -> String {
        switch (kind, count) {
        case (.reference, 1): return L10n.string("1 reference")
        case (.reference, _): return L10n.format("%lld references", Int64(count))
        case (.comment, 1): return L10n.string("1 comment")
        case (.comment, _): return L10n.format("%lld comments", Int64(count))
        }
    }
}

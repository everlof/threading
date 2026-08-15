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

        // A dropped session is a chip of its own, under the row's own name. The count pills
        // exist to keep twenty line comments to two quiet words; a session reference is one
        // named thing the person just dragged in, and "1 reference" would hide which one.
        // Bounded by `ConversationContextPolicy.maximumAttachments`, like the rest of the rail.
        for attachment in attachments where Self.standsAlone(attachment) {
            let chip = ChipView()
            chip.configure(symbolName: RailDefaults.sessionSymbol, title: attachment.title)
            chip.setAccessibilityIdentifier(RailDefaults.sessionChipIdentifier)
            chip.itemsProvider = { [weak self] in
                self?.standaloneEntries(for: attachment) ?? []
            }
            stack.addArrangedSubview(chip)
        }

        for kind in ConversationContextAttachment.Kind.allCases {
            let values = attachments.filter { $0.kind == kind && !Self.standsAlone($0) }
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

    /// A session *reference* draws as its own chip; a comment on one is a comment like any
    /// other and folds into the count, because what it says matters more than what it is on.
    private static func standsAlone(_ attachment: ConversationContextAttachment) -> Bool {
        attachment.source == .session && attachment.kind == .reference
    }

    /// One press deep: the chip already names the thing, so its menu is the id as a header and
    /// the actions straight under it. The count pills need the extra level because they hold
    /// many; a chip that holds one would only be making the person open a submenu to reach the
    /// two rows they came for.
    private func standaloneEntries(
        for attachment: ConversationContextAttachment
    ) -> [ThemedMenuEntry] {
        let actions = actions(for: attachment)
        guard !actions.isEmpty else { return entries(for: [attachment]) }
        return [.header(attachment.presentationDetail)] + actions
    }

    private func entries(
        for values: [ConversationContextAttachment]
    ) -> [ThemedMenuEntry] {
        values.map { attachment in
            let actions = actions(for: attachment)
            guard !actions.isEmpty else {
                return .item(ThemedMenuItem(
                    title: attachment.title,
                    subtitle: attachment.presentationDetail,
                    isEnabled: false
                ))
            }
            return .item(ThemedMenuItem(
                title: attachment.title,
                subtitle: attachment.presentationDetail,
                submenu: actions
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

private enum RailDefaults {
    /// The "Other sessions" tool group's own mark, so the chip and the setting that governs
    /// what the agent can do with it wear the same glyph.
    static let sessionSymbol = "bubble.left.and.bubble.right"
    static let sessionChipIdentifier = "conversation.context.session-reference"
}

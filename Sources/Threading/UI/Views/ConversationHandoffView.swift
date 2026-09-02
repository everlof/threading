import AppKit

/// The compact path shown at the boundary where one runtime continued another's conversation.
///
/// The durable model may retain more stops than fit in a readable-width conversation column.
/// This projection preserves the origin and the two newest endpoints, and states exactly how
/// many known or previously compacted stops sit between them.
struct ConversationHandoffPresentation: Equatable {
    static let maximumVisibleEndpoints = 3

    let endpoints: [ConversationHandoffEndpoint]
    let omittedEndpointCount: Int

    init(handoff: ConversationHandoff) {
        let hidden = max(0, handoff.endpoints.count - Self.maximumVisibleEndpoints)
        if hidden == 0 {
            endpoints = handoff.endpoints
        } else {
            endpoints = [handoff.endpoints[0]] + handoff.endpoints.suffix(2)
        }
        omittedEndpointCount = handoff.omittedEndpointCount + hidden
    }

    var spokenPath: String {
        let names = endpoints.map(\.displayName)
        guard omittedEndpointCount > 0, names.count >= 2 else {
            return names.joined(separator: " to ")
        }
        return ([names[0], "\(omittedEndpointCount) earlier stops omitted"]
            + Array(names.dropFirst()))
            .joined(separator: " to ")
    }

    var compactPath: String {
        let names = endpoints.map(\.displayName)
        guard omittedEndpointCount > 0, names.count >= 2 else {
            return names.joined(separator: " → ")
        }
        return ([names[0], "+\(omittedEndpointCount)"] + Array(names.dropFirst()))
            .joined(separator: " → ")
    }
}

/// Theme-owned conversation chrome for a cross-runtime handoff.
///
/// The direct source endpoint is an action when its session still exists. All older stops are
/// frozen provenance: their ids remain in the model, but only the direct source is promised as
/// navigation because compacted or deleted ancestors may no longer have a local row.
final class ConversationHandoffView: NSView, ThemedComponent {
    private enum Layout {
        static let minimumRuleWidth: CGFloat = 24
        static let iconSize: CGFloat = 13
        static let maximumEndpointWidth: CGFloat = 132
    }

    private let handoff: ConversationHandoff
    private let presentation: ConversationHandoffPresentation
    private let sourceButton: ThemedButton?
    private let titleLabel = NSTextField(labelWithString: L10n.string("Context handoff"))
    private let handoffGlyph = GlyphView()
    private var endpointLabels: [NSTextField] = []
    private var endpointGlyphs: [GlyphView] = []
    private var onOpenSource: ((SessionID) -> Void)?

    init(
        handoff: ConversationHandoff,
        canOpenSource: Bool,
        onOpenSource: ((SessionID) -> Void)?
    ) {
        self.handoff = handoff
        presentation = ConversationHandoffPresentation(handoff: handoff)
        self.onOpenSource = onOpenSource

        if let source = handoff.source,
           presentation.endpoints.contains(where: { $0.sessionID == source.sessionID }) {
            let button = ThemedButton(title: source.displayName, target: nil, action: nil)
            button.image = source.kind.icon
            button.emphasis = .tertiary
            button.isEnabled = canOpenSource
            button.toolTip = canOpenSource
                ? L10n.string("Open source conversation")
                : L10n.string("Source conversation is no longer available")
            button.setAccessibilityLabel(
                canOpenSource
                    ? L10n.format("Open source conversation, %@", source.displayName)
                    : L10n.format("Source conversation unavailable, %@", source.displayName)
            )
            button.widthAnchor.constraint(lessThanOrEqualToConstant: Layout.maximumEndpointWidth)
                .isActive = true
            sourceButton = button
        } else {
            sourceButton = nil
        }

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityRole(.group)
        setAccessibilityLabel(
            L10n.format("Context handoff, %@", presentation.spokenPath)
        )
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewWillDraw() {
        super.viewWillDraw()
        applyTheme()
    }

    private func setup() {
        handoffGlyph.image = Design.Symbol.image(
            "arrow.left.arrow.right",
            slot: Layout.iconSize,
            pointSize: Layout.iconSize
        )

        titleLabel.applyFont(.caption, in: .conversation)
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let path = NSStackView()
        path.orientation = .horizontal
        path.alignment = .centerY
        path.spacing = Design.Spacing.tight
        path.translatesAutoresizingMaskIntoConstraints = false

        for (index, endpoint) in presentation.endpoints.enumerated() {
            if index > 0 {
                path.addArrangedSubview(arrowView())
            }
            if index == 1, presentation.omittedEndpointCount > 0 {
                path.addArrangedSubview(omittedView())
                path.addArrangedSubview(arrowView())
            }
            path.addArrangedSubview(endpointView(endpoint))
        }

        let content = NSStackView(views: [handoffGlyph, titleLabel, path])
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = Design.Spacing.small
        content.translatesAutoresizingMaskIntoConstraints = false

        let leadingRule = SeparatorView()
        let trailingRule = SeparatorView()
        let row = NSStackView(views: [leadingRule, content, trailingRule])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Design.Spacing.medium
        row.translatesAutoresizingMaskIntoConstraints = false

        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: Design.Spacing.small),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Design.Spacing.small),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            leadingRule.widthAnchor.constraint(greaterThanOrEqualToConstant: Layout.minimumRuleWidth),
            trailingRule.widthAnchor.constraint(greaterThanOrEqualToConstant: Layout.minimumRuleWidth),
            leadingRule.widthAnchor.constraint(equalTo: trailingRule.widthAnchor)
        ])

        sourceButton?.target = self
        sourceButton?.action = #selector(openSource)
        applyTheme()
    }

    private func endpointView(_ endpoint: ConversationHandoffEndpoint) -> NSView {
        if endpoint.sessionID == handoff.source?.sessionID, let sourceButton {
            return sourceButton
        }

        let glyph = GlyphView()
        glyph.image = endpoint.kind.icon
        glyph.slot = NSSize(width: Layout.iconSize, height: Layout.iconSize)
        endpointGlyphs.append(glyph)

        let label = NSTextField(labelWithString: endpoint.displayName)
        label.applyFont(.detail(), in: .conversation)
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = endpoint.displayName
        label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        endpointLabels.append(label)

        let stack = NSStackView(views: [glyph, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Design.Spacing.tight
        stack.widthAnchor.constraint(lessThanOrEqualToConstant: Layout.maximumEndpointWidth)
            .isActive = true
        return stack
    }

    private func arrowView() -> NSView {
        let label = NSTextField(labelWithString: "→")
        label.applyFont(.detail(), in: .conversation)
        label.textColor = Design.Text.tertiary
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        return label
    }

    private func omittedView() -> NSView {
        let label = NSTextField(labelWithString: "+\(presentation.omittedEndpointCount)")
        label.applyFont(.detail(weight: .medium), in: .conversation)
        label.textColor = Design.Text.tertiary
        label.toolTip = L10n.format(
            "%d earlier handoff stops omitted",
            presentation.omittedEndpointCount
        )
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        return label
    }

    private func applyTheme() {
        handoffGlyph.tint = Design.Text.tertiary
        titleLabel.textColor = Design.Text.secondary
        endpointLabels.enumerated().forEach { index, label in
            label.textColor = index == endpointLabels.count - 1
                ? Design.Text.label
                : Design.Text.secondary
        }
        endpointGlyphs.forEach { glyph in
            if glyph.image?.isTemplate == true { glyph.tint = Design.Text.secondary }
        }
    }

    @objc private func openSource() {
        guard let source = handoff.source else { return }
        onOpenSource?(source.sessionID)
    }
}

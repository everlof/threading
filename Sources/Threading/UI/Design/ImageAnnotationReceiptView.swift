import AppKit

/// A persistent annotation receipt shown with the source image outside the inspector.
final class ImageAnnotationReceiptView: NSView, ThemedComponent {

    var onEdit: (() -> Void)?
    var onPrimaryAction: (() -> Void)?

    private let surface = ThemedSurfaceView()
    private let glyph = GlyphView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private lazy var editButton = ThemedButton(
        title: L10n.string("Edit"),
        target: self,
        action: #selector(editPressed)
    )
    private lazy var primaryButton = ThemedButton(
        title: L10n.string("Add to chat"),
        target: self,
        action: #selector(primaryPressed)
    )

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        surface.applySurface(
            fill: Design.Surface.panel,
            radius: .control,
            border: Design.Surface.border
        )
        glyph.setSymbol("mappin.and.ellipse", role: .control)
        glyph.tint = Design.Surface.accent

        titleLabel.applyFont(.subheading)
        titleLabel.textColor = Design.Text.label
        titleLabel.lineBreakMode = .byTruncatingTail
        detailLabel.applyFont(.caption)
        detailLabel.textColor = Design.Text.tertiary
        detailLabel.lineBreakMode = .byTruncatingTail

        editButton.emphasis = .secondary
        primaryButton.emphasis = .primary
        editButton.setAccessibilityIdentifier("annotation.receipt.edit")
        primaryButton.setAccessibilityIdentifier("annotation.receipt.chat-action")

        let text = NSStackView(views: [titleLabel, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = Design.Spacing.hairline
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let actions = NSStackView(views: [editButton, primaryButton])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = Design.Spacing.small

        let row = NSStackView(views: [glyph, text, actions])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Design.Spacing.small
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(surface)
        addSubview(row)

        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.topAnchor.constraint(equalTo: topAnchor, constant: Design.Spacing.small),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Design.Spacing.inset),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Design.Spacing.small),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Design.Spacing.small)
        ])
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        glyph.tint = Design.Surface.accent
        titleLabel.textColor = Design.Text.label
        detailLabel.textColor = Design.Text.tertiary
    }

    func configure(
        count: Int,
        state: ImageAnnotationSharingState,
        canShare: Bool
    ) {
        titleLabel.stringValue = count == 1
            ? L10n.string("1 saved annotation")
            : L10n.format("%lld saved annotations", Int64(count))
        detailLabel.stringValue = detail(for: state, canShare: canShare)
        primaryButton.title = actionTitle(for: state)
        primaryButton.isEnabled = canShare || state == .currentInChat
        setAccessibilityLabel("\(titleLabel.stringValue). \(detailLabel.stringValue)")
    }

    @objc private func editPressed() { onEdit?() }
    @objc private func primaryPressed() { onPrimaryAction?() }

    private func actionTitle(for state: ImageAnnotationSharingState) -> String {
        switch state {
        case .currentInChat: return L10n.string("Remove")
        case .changedInChat: return L10n.string("Update chat")
        case .changedSinceShared: return L10n.string("Add update")
        case .local, .shared: return L10n.string("Add to chat")
        }
    }

    private func detail(for state: ImageAnnotationSharingState, canShare: Bool) -> String {
        switch state {
        case .local: return canShare
            ? L10n.string("Saved to this session")
            : L10n.string("Saved · chat is unavailable")
        case .currentInChat: return L10n.string("Current revision is in chat")
        case .changedInChat: return L10n.string("Changed since it was added")
        case .shared: return L10n.string("Last revision was shared")
        case .changedSinceShared: return L10n.string("Changed since last shared")
        }
    }
}

/// The row-sized annotation marker used in the attachments chronology.
final class ImageAnnotationCountView: NSView {
    private let glyph = GlyphView()
    private let label = NSTextField(labelWithString: "")

    init(count: Int) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        glyph.setSymbol("mappin.and.ellipse", role: .control)
        glyph.tint = Design.Surface.accent
        label.applyFont(.numericDetail())
        label.textColor = Design.Text.tertiary
        label.stringValue = String(count)
        label.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [glyph, label])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Design.Spacing.hairline
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(L10n.format("%lld annotations", Int64(count)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        glyph.tint = Design.Surface.accent
        label.textColor = Design.Text.tertiary
    }
}

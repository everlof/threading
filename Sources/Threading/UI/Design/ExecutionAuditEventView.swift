import AppKit

/// The compact, factual row used by the execution-audit timeline.
///
/// The row owns no interpretation of an event: category, phase, source, fidelity, and summary
/// are already deterministic values in `ExecutionAuditRecord`. Its only work is visual hierarchy.
final class ExecutionAuditEventView: NSView {
    private let ground = ThemedSurfaceView()
    private let categoryGlyph = NSImageView()
    private let operationLabel = NSTextField(labelWithString: "")
    private let summaryLabel = NSTextField(labelWithString: "")
    private let metadataLabel = NSTextField(labelWithString: "")
    private let phaseGlyph = NSImageView()
    private let phaseLabel = NSTextField(labelWithString: "")

    private(set) var recordID: UUID?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(record: ExecutionAuditRecord, isSelected: Bool) {
        recordID = record.id
        // The row inks its own labels, so it may paint the theme's selection at full strength —
        // and must take the ink that comes with it. It used to fill with the selection role and
        // ink with `Design.Text.selected`, which is measured against the *opaque accent*: under a
        // theme whose selection is that accent at 20%, the row wrote white on a pale wash.
        let selection = SelectionSurface.stated(over: Design.Surface.ground)
        ground.applySurface(
            fill: isSelected ? selection.fill : Design.Surface.ground,
            radius: .fixed(Design.Radius.control)
        )

        categoryGlyph.image = NSImage(
            systemSymbolName: record.category.symbolName,
            accessibilityDescription: record.category.displayName
        )?.withSymbolConfiguration(Design.Symbol.configuration(Design.Symbol.control))
        categoryGlyph.contentTintColor = isSelected ? selection.ink.secondary : Design.Text.secondary

        operationLabel.stringValue = record.operation
        summaryLabel.stringValue = record.summary == record.operation ? "" : record.summary
        summaryLabel.isHidden = summaryLabel.stringValue.isEmpty

        let source = record.provider.map { "\(record.source.compactDisplayName) · \($0)" }
            ?? record.source.compactDisplayName
        metadataLabel.stringValue = "\(Self.time.string(from: record.timestamp))  ·  \(source)  ·  \(record.fidelity.displayName)"

        phaseGlyph.image = NSImage(
            systemSymbolName: "circle.fill",
            accessibilityDescription: record.phase.rawValue
        )?.withSymbolConfiguration(Design.Symbol.configuration(6))
        phaseGlyph.contentTintColor = Self.phaseColor(record.phase)
        phaseLabel.stringValue = record.phase.displayName

        // The tiers come from the ink rather than from alphas of one colour: `Design.Ink` already
        // states how far apart the tiers sit on a given ground, and it is not the same distance on
        // a dark ground as on a light one — black fades to nothing on paper long before white does
        // on ink. Two hand-written alphas could not know which ground they had landed on.
        let primary = isSelected ? selection.ink.label : Design.Text.label
        let secondary = isSelected ? selection.ink.secondary : Design.Text.secondary
        operationLabel.textColor = primary
        summaryLabel.textColor = secondary
        metadataLabel.textColor = isSelected ? selection.ink.tertiary : Design.Text.tertiary
        phaseLabel.textColor = secondary

        setAccessibilityLabel(
            "\(record.category.displayName), \(record.operation), \(record.phase.rawValue), \(record.summary)"
        )
    }

    private func setupViews() {
        ground.translatesAutoresizingMaskIntoConstraints = false
        ground.applySurface(fill: Design.Surface.ground, radius: .fixed(Design.Radius.control))
        addSubview(ground)

        categoryGlyph.imageScaling = .scaleProportionallyDown
        categoryGlyph.translatesAutoresizingMaskIntoConstraints = false

        operationLabel.applyFont(.strongBody)
        operationLabel.lineBreakMode = .byTruncatingMiddle
        operationLabel.translatesAutoresizingMaskIntoConstraints = false

        summaryLabel.applyFont(.body)
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false

        metadataLabel.applyFont(.caption)
        metadataLabel.lineBreakMode = .byTruncatingTail
        metadataLabel.translatesAutoresizingMaskIntoConstraints = false

        phaseGlyph.imageScaling = .scaleProportionallyDown
        phaseGlyph.translatesAutoresizingMaskIntoConstraints = false

        phaseLabel.applyFont(.caption)
        phaseLabel.translatesAutoresizingMaskIntoConstraints = false

        let phase = NSStackView(views: [phaseGlyph, phaseLabel])
        phase.orientation = .horizontal
        phase.alignment = .centerY
        phase.spacing = Design.Spacing.tight
        phase.translatesAutoresizingMaskIntoConstraints = false

        let firstLine = NSStackView(views: [operationLabel, NSView(), phase])
        firstLine.orientation = .horizontal
        firstLine.alignment = .firstBaseline
        firstLine.spacing = Design.Spacing.small
        firstLine.translatesAutoresizingMaskIntoConstraints = false

        let text = NSStackView(views: [firstLine, summaryLabel, metadataLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = Design.Spacing.tight
        text.translatesAutoresizingMaskIntoConstraints = false

        ground.addSubview(categoryGlyph)
        ground.addSubview(text)

        NSLayoutConstraint.activate([
            ground.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Design.Spacing.tight),
            ground.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Design.Spacing.tight),
            ground.topAnchor.constraint(equalTo: topAnchor, constant: Design.Spacing.tight),
            ground.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Design.Spacing.tight),

            categoryGlyph.leadingAnchor.constraint(equalTo: ground.leadingAnchor, constant: Design.Spacing.medium),
            categoryGlyph.topAnchor.constraint(equalTo: ground.topAnchor, constant: Design.Spacing.medium),
            categoryGlyph.widthAnchor.constraint(equalToConstant: Design.Symbol.control),
            categoryGlyph.heightAnchor.constraint(equalToConstant: Design.Symbol.control),

            text.leadingAnchor.constraint(equalTo: categoryGlyph.trailingAnchor, constant: Design.Spacing.medium),
            text.trailingAnchor.constraint(equalTo: ground.trailingAnchor, constant: -Design.Spacing.medium),
            text.topAnchor.constraint(equalTo: ground.topAnchor, constant: Design.Spacing.small),
            text.bottomAnchor.constraint(lessThanOrEqualTo: ground.bottomAnchor, constant: -Design.Spacing.small),
            firstLine.widthAnchor.constraint(equalTo: text.widthAnchor),
            phaseGlyph.widthAnchor.constraint(equalToConstant: 6),
            phaseGlyph.heightAnchor.constraint(equalToConstant: 6)
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.row)
    }

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        // Milliseconds remain in the exact JSON inspector. The rail uses whole seconds so the
        // source and fidelity guarantee never disappear behind truncation at its intended width.
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static func phaseColor(_ phase: ExecutionAuditRecord.Phase) -> NSColor {
        switch phase {
        case .completed, .allowed: return Design.Status.positive
        case .failed, .denied, .interrupted: return Design.Status.negative
        case .requested, .progressed: return Design.Status.warning
        }
    }
}

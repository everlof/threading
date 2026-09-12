import AppKit

/// One answer choice: its complete title and explanation share one target. Radio semantics
/// reflect the single answer the provider accepts; selection alone never submits the form.
final class ConversationChoiceRow: ThemedControl {
    var isSelected = false { didSet { needsDisplay = true } }
    var onSelect: (() -> Void)?
    var onMove: ((Int) -> Void)?
    private let titleLabel: NSTextField
    private let detailLabel: NSTextField
    private let glyph = GlyphView()
    private var isPressed = false { didSet { needsDisplay = true } }

    init(title: String, detail: String) {
        titleLabel = NSTextField(wrappingLabelWithString: title)
        detailLabel = NSTextField(wrappingLabelWithString: detail)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        titleLabel.applyFont(.body, in: .conversation)
        detailLabel.applyFont(.caption, in: .conversation)
        let text = NSStackView(views: detail.isEmpty ? [titleLabel] : [titleLabel, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = Design.Spacing.tight
        for view in [text, glyph] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        let inset = Design.Spacing.medium
        NSLayoutConstraint.activate([
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            glyph.topAnchor.constraint(equalTo: text.topAnchor),
            glyph.widthAnchor.constraint(equalToConstant: Design.Symbol.control),
            glyph.heightAnchor.constraint(equalToConstant: Design.Symbol.control),
            text.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: inset),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            text.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
            titleLabel.widthAnchor.constraint(equalTo: text.widthAnchor)
        ])
        if !detail.isEmpty { detailLabel.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true }
        setAccessibilityLabel(title)
        setAccessibilityHelp(detail)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        titleLabel.textColor = Design.Text.label
        detailLabel.textColor = Design.Text.secondary
        glyph.tint = isSelected ? Design.Surface.accent : Design.Text.tertiary
        glyph.setSymbol(isSelected ? "checkmark.circle.fill" : "circle", slot: Design.Symbol.control, role: .control)
        let shape = ThemedSurface.draw(
            bounds,
            fill: isPressed || isHovered || isSelected ? Design.Surface.controlResting : .clear,
            border: isSelected ? Design.Surface.accent : Design.Surface.border,
            radius: Design.Radius.control
        )
        drawKeyboardFocus(around: shape)
    }

    override var restingPointer: NSCursor? { .pointingHand }
    override func performPrimaryAction() -> Bool {
        guard isEnabled else { return false }
        onSelect?()
        return true
    }
    override func mouseDown(with event: NSEvent) { if isEnabled { isPressed = true } }
    override func mouseDragged(with event: NSEvent) {
        if isEnabled { isPressed = bounds.contains(convert(event.locationInWindow, from: nil)) }
    }
    override func mouseUp(with event: NSEvent) {
        let activate = isPressed && bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        if activate { _ = performPrimaryAction() }
    }
    override func keyDown(with event: NSEvent) {
        guard isEnabled else { return }
        switch event.keyCode {
        case 123, 126: onMove?(-1)
        case 124, 125: onMove?(1)
        default: super.keyDown(with: event)
        }
    }
    override func accessibilityRole() -> NSAccessibility.Role? { .radioButton }
    override func accessibilityValue() -> Any? { isSelected }
    override func accessibilityPerformPress() -> Bool { performPrimaryAction() }
}

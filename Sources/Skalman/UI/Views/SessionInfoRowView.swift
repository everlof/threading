import AppKit

/// One line in the info panel: a glyph, what the line is about, and a value on the right.
///
/// It follows the tool row's rule rather than the table's — **no fill at rest**, raised on
/// hover — because a panel is mostly rows, and a stack of filled slabs reads as the content
/// rather than as a list of facts about it. Only a row that *does* something takes a hover at
/// all; on the rest the absence of one is the honest signal that there is nothing to click.
final class SessionInfoRowView: NSView {

    // MARK: - Properties

    private let glyphView = NSImageView()
    private let primaryLabel = NSTextField(labelWithString: "")
    private let secondaryLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")

    private var isHovered = false

    /// What clicking the row does. Nil leaves the row inert, and with no action there is no
    /// hover either.
    private var action: (() -> Void)?

    /// The right-hand value, updated in place between polls so a changing number does not cost
    /// the row its hover or the panel its scroll position.
    var value: String {
        get { valueLabel.stringValue }
        set { valueLabel.stringValue = newValue }
    }

    // MARK: - Initialization

    init(
        symbolName: String,
        symbolColor: NSColor,
        primary: String,
        secondary: String,
        value: String,
        action: (() -> Void)? = nil
    ) {
        self.action = action
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        applySurface(fill: Design.Chat.toolRowResting, radius: .control)

        glyphView.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: SessionInfoLayout.glyphPointSize, weight: .regular))
        glyphView.contentTintColor = symbolColor
        glyphView.imageScaling = .scaleNone

        primaryLabel.font = Design.Typography.compactCode()
        primaryLabel.textColor = Design.Text.label
        primaryLabel.stringValue = primary
        primaryLabel.lineBreakMode = .byTruncatingTail

        secondaryLabel.font = Design.Typography.compactCode()
        secondaryLabel.textColor = Design.Text.tertiary
        secondaryLabel.stringValue = secondary
        secondaryLabel.lineBreakMode = .byTruncatingTail

        valueLabel.font = Design.Typography.compactCode()
        valueLabel.textColor = Design.Text.tertiary
        valueLabel.stringValue = value
        valueLabel.alignment = .right
        valueLabel.lineBreakMode = .byTruncatingTail

        // The value is the row's answer, so it keeps its width; the two descriptions give way.
        // High rather than required: required would make the widest row a hard floor under the
        // whole panel, and a panel that cannot be dragged narrower than one process name is worse
        // than a truncated megabyte count.
        valueLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        valueLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        secondaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        primaryLabel.setContentCompressionResistancePriority(.defaultLow + 1, for: .horizontal)

        [glyphView, primaryLabel, secondaryLabel, valueLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: SessionInfoLayout.rowHeight),

            glyphView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Design.Spacing.small),
            glyphView.centerYAnchor.constraint(equalTo: centerYAnchor),
            glyphView.widthAnchor.constraint(equalToConstant: Design.Chat.toolIconWidth),

            primaryLabel.leadingAnchor.constraint(equalTo: glyphView.trailingAnchor, constant: Design.Spacing.small),
            primaryLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            secondaryLabel.leadingAnchor.constraint(equalTo: primaryLabel.trailingAnchor, constant: Design.Spacing.small),
            secondaryLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            valueLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: secondaryLabel.trailingAnchor,
                constant: Design.Spacing.small
            ),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Design.Spacing.small),
            valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Interaction

    override func mouseDown(with event: NSEvent) {
        guard let action else {
            super.mouseDown(with: event)
            return
        }
        action()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard action != nil else { return }
        addCursorRect(bounds, cursor: .pointingHand)
    }

    // MARK: - Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)

        guard action != nil else { return }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateSurface()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateSurface()
    }

    private func updateSurface() {
        applyLayerBackground(isHovered ? Design.Chat.toolRowActive : Design.Chat.toolRowResting)
    }
}

// MARK: - Layout

enum SessionInfoLayout {
    static let rowHeight: CGFloat = 22
    static let glyphPointSize: CGFloat = 11
}

import AppKit

/// One selectable destination in either a horizontal tab strip or a sidebar.
///
/// The orientation changes only geometry. Selection, hover, keyboard access, close affordance,
/// and theme treatment stay identical, so a page in the sidebar and a document in a pane read as
/// the same navigation concept rather than two unrelated kinds of highlighted row.
final class ThemedTabItemView: ThemedControl {

    enum Placement {
        case horizontal
        case sidebar

        var height: CGFloat {
            switch self {
            case .horizontal: Design.Size.tabHeight
            case .sidebar: Design.Size.sidebarTabHeight
            }
        }
    }

    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?

    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            titleLabel.font = Design.Typography.controlRegular()
            needsDisplay = true
        }
    }

    private let placement: Placement
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let closeButton = ThemedButton()
    private var trackingArea: NSTrackingArea?
    private var isHovered = false { didSet { needsDisplay = true } }
    private var isPressed = false { didSet { needsDisplay = true } }

    init(
        title: String,
        symbolName: String,
        placement: Placement,
        showsClose: Bool = false
    ) {
        self.placement = placement
        super.init(frame: .zero)
        setup(title: title, symbolName: symbolName, showsClose: showsClose)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup(title: String, symbolName: String, showsClose: Bool) {
        translatesAutoresizingMaskIntoConstraints = false

        iconView.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: nil
        )
        iconView.symbolConfiguration = Design.Symbol.configuration(Design.Symbol.control)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.stringValue = title
        titleLabel.font = Design.Typography.controlRegular()
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        closeButton.image = NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: "Close \(title)"
        )?.withSymbolConfiguration(Design.Symbol.configuration(Design.Symbol.chevron, weight: .semibold))
        closeButton.isBordered = false
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.isHidden = !showsClose
        closeButton.setContentHuggingPriority(.required, for: .horizontal)

        let content = NSStackView(views: [iconView, titleLabel, closeButton])
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = Design.Spacing.small
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        let horizontalInset = placement == .sidebar
            ? Design.Spacing.medium
            : Design.Spacing.inset

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: placement.height),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: horizontalInset),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -horizontalInset),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: Design.Size.tabIconSlot),
            closeButton.widthAnchor.constraint(equalToConstant: Design.Size.tabCloseTarget),
            closeButton.heightAnchor.constraint(equalToConstant: Design.Size.tabCloseTarget)
        ])
    }

    override var intrinsicContentSize: NSSize {
        let titleWidth = ceil(
            titleLabel.stringValue.size(withAttributes: [.font: titleLabel.font as Any]).width
        )
        let closeWidth = closeButton.isHidden
            ? 0
            : Design.Spacing.small + Design.Size.tabCloseTarget
        let inset = placement == .sidebar ? Design.Spacing.medium : Design.Spacing.inset
        return NSSize(
            width: inset * 2 + Design.Size.tabIconSlot + Design.Spacing.small + titleWidth + closeWidth,
            height: placement.height
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        let foreground: NSColor
        let fill: NSColor
        let border: NSColor?

        if isSelected {
            foreground = Design.Text.label
            fill = Design.Surface.controlHover
            border = Design.Surface.border
        } else if isPressed || isHovered || hasKeyboardFocus {
            foreground = Design.Text.label
            fill = Design.Surface.controlResting
            border = nil
        } else {
            foreground = Design.Text.secondary
            fill = .clear
            border = nil
        }

        let path = ThemedSurface.draw(bounds, fill: fill, border: border)
        drawKeyboardFocus(around: path)

        titleLabel.textColor = foreground
        iconView.contentTintColor = isSelected ? Design.Surface.accent : foreground
        closeButton.contentTintColor = foreground
        closeButton.alphaValue = isSelected || isHovered ? 1 : 0
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = true
        window?.makeFirstResponder(self)
        onSelect?()
    }

    override func mouseUp(with event: NSEvent) {
        isPressed = false
    }

    override func performPrimaryAction() -> Bool {
        guard isEnabled else { return false }
        onSelect?()
        return true
    }

    /// Labels make no claim on the pointer; the close button is the one intentional child target.
    override func hitTest(_ point: NSPoint) -> NSView? {
        // AppKit supplies `point` in the superview's coordinate space. The tab can sit anywhere
        // in a stack or toolbar, so comparing that point directly with our zero-based bounds
        // makes every offset tab miss.
        let localPoint = convert(point, from: superview)
        guard bounds.contains(localPoint) else { return nil }

        let closePoint = closeButton.convert(localPoint, from: self)
        if !closeButton.isHidden, closeButton.bounds.contains(closePoint) {
            return closeButton
        }
        return self
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .radioButton }
    override func accessibilityTitle() -> String? { titleLabel.stringValue }
    override func accessibilityValue() -> Any? { isSelected }
    override func accessibilityPerformPress() -> Bool { performPrimaryAction() }

    @objc private func closeClicked() {
        onClose?()
    }
}

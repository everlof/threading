import AppKit

/// A compact app-owned toolbar action that stays legible over the active terminal backdrop.
///
/// Unlike `ThemedButton`, this cannot read the chrome palette: the transparent title bar is
/// painted by the selected terminal. `BackdropOverlay` supplies ink measured against that actual
/// colour, while this view supplies the interaction semantics of an icon button.
final class ToolbarButtonView: BackdropThemedControl {

    var onPress: (() -> Void)?

    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            needsDisplay = true
            setAccessibilityValue(isSelected)
        }
    }

    private let iconView = NSImageView()
    private let accessibilityName: String
    private let isEmphasized: Bool
    private let buttonSize: NSSize
    private var trackingArea: NSTrackingArea?
    private var isHovered = false { didSet { needsDisplay = true } }
    private var isPressed = false { didSet { needsDisplay = true } }

    init(
        symbolName: String,
        accessibility: String,
        isEmphasized: Bool = false,
        buttonSize: NSSize = NSSize(
            width: Design.Size.toolbarButtonWidth,
            height: Design.Size.toolbarButtonHeight
        )
    ) {
        self.accessibilityName = accessibility
        self.isEmphasized = isEmphasized
        self.buttonSize = buttonSize
        super.init(frame: .zero)
        setup(symbolName: symbolName)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup(symbolName: String) {
        translatesAutoresizingMaskIntoConstraints = false

        iconView.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: nil
        )
        iconView.symbolConfiguration = Design.Symbol.configuration(Design.Symbol.control)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: buttonSize.width),
            heightAnchor.constraint(equalToConstant: buttonSize.height),
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(
                equalToConstant: min(Design.Size.tabIconSlot, buttonSize.width)
            ),
            iconView.heightAnchor.constraint(
                equalToConstant: min(Design.Size.tabIconSlot, buttonSize.height)
            )
        ])
    }

    override func applyInk(_ ink: Design.Ink) {
        iconView.contentTintColor = isEnabled ? ink.secondary : ink.quaternary
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let active = isSelected || isEmphasized
        let fill: NSColor
        if isPressed {
            fill = ink.surfaceHover
        } else if active {
            fill = isHovered ? ink.surfaceHover : ink.surface
        } else {
            fill = isHovered ? ink.surface : .clear
        }

        let border = active ? ink.border : nil
        let path = ThemedSurface.draw(
            bounds,
            fill: fill,
            border: border,
            radius: Design.Radius.pill(height: bounds.height)
        )

        if window?.firstResponder === self {
            ink.label.setStroke()
            path.lineWidth = Design.Accessibility.focusRingWidth
            path.stroke()
        }

        iconView.contentTintColor = isEnabled
            ? (isSelected || isHovered ? ink.label : ink.secondary)
            : ink.quaternary
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
    }

    override func mouseUp(with event: NSEvent) {
        let shouldFire = isPressed && bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        if shouldFire { performPress() }
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityTitle() -> String? { accessibilityName }
    override func accessibilityPerformPress() -> Bool {
        performPress()
    }

    override func performPrimaryAction() -> Bool {
        performPress()
    }

    @discardableResult
    private func performPress() -> Bool {
        guard isEnabled else { return false }
        onPress?()
        return true
    }
}

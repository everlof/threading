import AppKit

/// A semantic selectable cell used when a navigator collection asks for a grid.
///
/// Feature code supplies ordinary host-rendered content and an activation closure. This control
/// owns the hover, selected, focus, pointer, keyboard, and accessibility behavior so extension
/// UI cannot introduce its own chrome.
final class NavigatorGridItemView: ThemedControl {
    var isSelected = false {
        didSet {
            setAccessibilitySelected(isSelected)
            needsDisplay = true
        }
    }

    var onActivate: (() -> Void)? {
        didSet {
            setAccessibilityRole(onActivate == nil ? .group : .button)
        }
    }

    private var contentView: NSView?
    private var isPressed = false {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityRole(.group)
    }

    convenience init(content: NSView) {
        self.init(frame: .zero)
        install(content)
    }

    func install(_ content: NSView) {
        contentView?.removeFromSuperview()
        contentView = content
        addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: Design.Spacing.small),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Design.Spacing.small),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Design.Spacing.small),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Design.Spacing.small)
        ])
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        for view in sequence(first: hit, next: { $0.superview }) {
            if view === self { break }
            if view is ThemedControl || view is NSButton {
                return hit
            }
            if let field = view as? NSTextField, field.isEditable {
                return hit
            }
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, onActivate != nil else { return }
        isPressed = true
        window?.makeFirstResponder(self)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isPressed else { return }
        isPressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        let activates = isPressed && bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        if activates { _ = performPrimaryAction() }
    }

    override func performPrimaryAction() -> Bool {
        guard isEnabled, let onActivate else { return false }
        onActivate()
        return true
    }

    override func accessibilityPerformPress() -> Bool {
        performPrimaryAction()
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        onActivate == nil ? .group : .button
    }

    override func draw(_ dirtyRect: NSRect) {
        let emphasized = isSelected || isHovered || isPressed || hasKeyboardFocus
        let fill: NSColor = isSelected
            ? Design.Surface.accent.withAlphaComponent(0.24)
            : Design.Surface.controlResting.withAlphaComponent(emphasized ? 0.9 : 0.55)
        let border = emphasized ? Design.Surface.accent : Design.Surface.border
        let shape = ThemedSurface.draw(bounds, fill: fill, border: border)
        drawKeyboardFocus(around: shape)
    }
}

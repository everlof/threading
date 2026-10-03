import AppKit

// The installed preview has a fixed diagnostic palette. These two font roles and the primary
// button are the narrow host leaves needed by the production idle placeholder; they do not
// replace the Mac theme engine or change the placeholder's layout and action ownership.
extension Design.Spacing {
    static let pane: CGFloat = 32
}

extension Design {
    enum Placeholder {
        static let afterIcon = Spacing.inset
        static let line = Spacing.small
        static let section = Spacing.pane
    }
}

enum SessionPlaceholderFontRole {
    case placeholderTitle, subheading
}

extension NSTextField {
    func applyFont(_ role: SessionPlaceholderFontRole) {
        switch role {
        case .placeholderTitle: font = NSFont.systemFont(ofSize: 15, weight: .medium)
        case .subheading: font = NSFont.systemFont(ofSize: 12, weight: .regular)
        }
    }
}

/// The production ThemedButton also owns period materials and animation. This bounded Linux
/// leaf implements the primary placeholder action over the same fixed accent as selection.
@MainActor
final class ThemedButton: ThemedControl {
    private static let accent = NSColor(red: 0.16, green: 0.42, blue: 0.78, alpha: 1)
    private static let titleFont = NSFont.systemFont(ofSize: 12, weight: .semibold)

    var title = "" {
        didSet { invalidateIntrinsicContentSize(); needsDisplay = true }
    }
    var isProminent = false { didSet { needsDisplay = true } }
    private var isPressed = false { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize {
        let text = (title as NSString).size(withAttributes: [.font: Self.titleFont])
        return NSSize(width: ceil(text.width) + 24, height: 26)
    }

    override func draw(_ dirtyRect: NSRect) {
        let fill = isProminent ? Self.accent : Specimen.bodyGround
        let ground = isPressed ? fill.blended(withFraction: 0.2, of: .black)! : fill
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                 xRadius: Design.Radius.control,
                                 yRadius: Design.Radius.control)
        ground.setFill()
        shape.fill()
        (isProminent ? Self.accent : Design.Text.tertiary).setStroke()
        shape.lineWidth = 1
        shape.stroke()

        let ink = isProminent ? Design.Ink(on: fill).label : Design.Text.label
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.titleFont,
                                                          .foregroundColor: ink]
        let measured = (title as NSString).size(withAttributes: attributes)
        let label = NSRect(x: max(8, (bounds.width - measured.width) / 2),
                           y: (bounds.height - measured.height) / 2,
                           width: max(0, bounds.width - 16), height: measured.height)
        (title as NSString).draw(in: label, withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = true
        window?.makeFirstResponder(self)
    }

    override func mouseUp(with event: NSEvent) {
        let wasPressed = isPressed
        isPressed = false
        guard wasPressed, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        _ = performPrimaryAction()
    }

    override func performPrimaryAction() -> Bool {
        sendAction(action, to: target)
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityTitle() -> String? { title }
    override func accessibilityPerformPress() -> Bool { performPrimaryAction() }
}

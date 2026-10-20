import AppKit

// The Linux host links the production ThemedTextView unchanged. Its theme vocabulary is
// resolved from the checked Threading snapshot; the generic AppKit shim has no palette.
extension Design.Surface {
    static var background: NSColor { LinuxTheme.color("surface") }
    static var ground: NSColor { LinuxTheme.color("ground") }
}

extension SelectionSurface {
    static func dynamic(_ ground: @escaping () -> NSColor) -> SelectionSurface {
        // Text selection uses the theme's selection role; list selection uses its accent.
        // The production component still owns the selected-text attributes.
        let fill = LinuxTheme.color("selection")
        return SelectionSurface(fill: fill, ink: Design.Ink(on: fill))
    }
}

@MainActor
public class ThemedScrollView: NSScrollView {
    var contentBreathing = NSEdgeInsets() {
        didSet { contentInsets = contentBreathing }
    }
    var fittedDocumentHeight: CGFloat? {
        didSet { invalidateIntrinsicContentSize() }
    }
    // This preview uses overlay scrolling; no reserved track consumes document height.
    func heightToFitContent(_ height: CGFloat, overflowsHorizontally: Bool? = nil) -> CGFloat { height }
    public override var intrinsicContentSize: NSSize {
        guard let fittedDocumentHeight else { return super.intrinsicContentSize }
        return NSSize(width: NSView.noIntrinsicMetric, height: fittedDocumentHeight)
    }
    var forwardsVerticalScroll = false
    public override func scrollWheel(with event: NSEvent) {
        if forwardsVerticalScroll, abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) {
            superview?.scrollWheel(with: event)
        } else { super.scrollWheel(with: event) }
    }
}

/// The editable field under the production component's name. It draws the production well
/// through `ThemedSurface` — the field fill, an accent border and inner focus ring while
/// editing — and insets its text the same 8 points, centred in the 32-point field height.
/// Bevel materials, the outlined search style and hover presentation are not themed here yet.
@MainActor
class ThemedTextField: NSTextField {
    fileprivate enum Layout {
        static let inset: CGFloat = Design.Spacing.small + 2
        static let height: CGFloat = 32
    }

    override class var cellClass: NSTextFieldCell.Type { ThemedTextFieldCell.self }

    override var placeholderString: String? {
        didSet {
            guard let placeholderString else { return }
            placeholderAttributedString = NSAttributedString(
                string: placeholderString,
                attributes: [.font: font ?? Design.Typography.body(),
                             .foregroundColor: Design.Text.tertiary]
            )
        }
    }

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.height = max(size.height, Layout.height)
        return size
    }

    override func draw(_ dirtyRect: NSRect) {
        let editing = currentEditor() != nil
        let shape = ThemedSurface.draw(bounds, fill: isEditable ? Design.Surface.field : Design.Surface.controlResting,
                                       border: editing ? Design.Surface.accent : Design.Surface.border)
        if editing {
            let width = Design.Accessibility.focusRingWidth
            let ring = shape.inset(by: width / 2).path
            Design.Surface.accent.setStroke()
            ring.lineWidth = width
            ring.stroke()
        }
        super.draw(dirtyRect)
    }

    func textSelectionGround() -> NSColor { isEditable ? Design.Surface.field : Design.Surface.controlResting }
}

/// The production field's text rect: inset from the border and one line centred vertically.
@MainActor
private final class ThemedTextFieldCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        let font = owner?.font ?? .systemFont(ofSize: 13)
        let line = ceil(font.boundingRectForFont.height)
        let inset = ThemedTextField.Layout.inset
        return NSRect(x: rect.minX + inset, y: rect.minY + max(0, (rect.height - line) / 2),
                      width: max(0, rect.width - 2 * inset), height: min(rect.height, line))
    }
}

@MainActor
class ThemedSecureField: ThemedTextField {}

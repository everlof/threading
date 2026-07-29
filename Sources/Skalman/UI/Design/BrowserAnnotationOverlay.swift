import AppKit

/// A user-owned annotation layer that sits above live browser content without entering its DOM.
///
/// The page can neither inspect nor alter the notes. Outside annotation mode the overlay declines
/// hit testing entirely, so the visible pins do not interfere with links or browser automation.
struct BrowserAnnotationMarker: Equatable {
    let id: Int
    let point: CGPoint
}

final class BrowserAnnotationOverlay: ThemedControl {

    private enum Layout {
        static let markerDiameter: CGFloat = Design.Size.chipHeight
        static let markerBorderWidth: CGFloat = Design.Radius.border
        static let markerHitInset: CGFloat = Design.Spacing.tight
    }

    var markers: [BrowserAnnotationMarker] = [] {
        didSet {
            setAccessibilityValue(
                L10n.format("%lld annotations", Int64(markers.count))
            )
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }
    }

    var isAnnotating = false {
        didSet {
            guard isAnnotating != oldValue else { return }
            setAccessibilityEnabled(isAnnotating)
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }
    }

    var onAdd: ((CGPoint) -> Void)?
    var onSelect: ((Int) -> Void)?
    var onDismiss: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityRole(.button)
        setAccessibilityLabel(L10n.string("Browser Annotation Canvas"))
        setAccessibilityHelp(
            L10n.string("Click the page to place an annotation for the agent")
        )
        setAccessibilityEnabled(false)
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { isAnnotating }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isAnnotating, bounds.contains(point) else { return nil }
        return self
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard isAnnotating else { return }
        addCursorRect(bounds, cursor: .crosshair)
        for marker in markers {
            addCursorRect(
                markerRect(for: marker)
                    .insetBy(dx: -Layout.markerHitInset, dy: -Layout.markerHitInset),
                cursor: .pointingHand
            )
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isAnnotating else { return }
        let point = convert(event.locationInWindow, from: nil)
        window?.makeFirstResponder(self)
        if let marker = marker(at: point) {
            onSelect?(marker.id)
        } else {
            onAdd?(point)
        }
    }

    override func performPrimaryAction() -> Bool {
        guard isAnnotating else { return false }
        onAdd?(CGPoint(x: bounds.midX, y: bounds.midY))
        return true
    }

    override func keyDown(with event: NSEvent) {
        if isAnnotating, event.keyCode == 53 {
            onDismiss?()
            return
        }
        super.keyDown(with: event)
    }

    override func accessibilityPerformPress() -> Bool {
        performPrimaryAction()
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? {
        L10n.string("Browser Annotation Canvas")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        for marker in markers where markerRect(for: marker).intersects(dirtyRect) {
            draw(marker)
        }
        if isAnnotating {
            drawKeyboardFocus(
                around: ThemedSurface.Shape(rect: bounds, radius: 0)
            )
        }
    }

    private func marker(at point: CGPoint) -> BrowserAnnotationMarker? {
        markers.last {
            markerRect(for: $0)
                .insetBy(dx: -Layout.markerHitInset, dy: -Layout.markerHitInset)
                .contains(point)
        }
    }

    private func markerRect(for marker: BrowserAnnotationMarker) -> CGRect {
        CGRect(
            x: marker.point.x - Layout.markerDiameter / 2,
            y: marker.point.y - Layout.markerDiameter / 2,
            width: Layout.markerDiameter,
            height: Layout.markerDiameter
        )
    }

    private func draw(_ marker: BrowserAnnotationMarker) {
        let rect = markerRect(for: marker)
        let path = NSBezierPath(ovalIn: rect)
        Design.Surface.accent.setFill()
        path.fill()
        Design.Surface.ground.setStroke()
        path.lineWidth = Layout.markerBorderWidth
        path.stroke()

        let value = "\(marker.id)"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Design.Typography.numericDetail(weight: .semibold),
            .foregroundColor: Design.Text.selected
        ]
        let size = value.size(withAttributes: attributes)
        value.draw(
            at: CGPoint(
                x: floor(rect.midX - size.width / 2),
                y: floor(rect.midY - size.height / 2)
            ),
            withAttributes: attributes
        )
    }
}

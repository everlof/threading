import AppKit

/// The outer browser canvas may pan only while showing an explicit responsive viewport.
/// WebKit owns document scrolling inside it. Enforce that distinction when AppKit scrolls,
/// not on a later controller layout: a clip-origin change need not request another layout.
final class BrowserViewportClipView: ThemedClipView {
    var allowsPanning = false {
        didSet {
            guard allowsPanning != oldValue else { return }
            scroll(to: bounds.origin)
        }
    }

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var constrained = super.constrainBoundsRect(proposedBounds)
        if !allowsPanning { constrained.origin = .zero }
        return constrained
    }

    override func scroll(to newOrigin: NSPoint) {
        // NSClipView's scroll(to:) bypasses setBoundsOrigin and does not constrain the input.
        super.scroll(to: constrainedOrigin(newOrigin))
    }

    override func setBoundsOrigin(_ newOrigin: NSPoint) {
        super.setBoundsOrigin(constrainedOrigin(newOrigin))
    }

    private func constrainedOrigin(_ origin: NSPoint) -> NSPoint {
        constrainBoundsRect(NSRect(origin: origin, size: bounds.size)).origin
    }
}

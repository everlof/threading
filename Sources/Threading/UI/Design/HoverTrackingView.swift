import AppKit

/// A container that reports pointer enter and exit without drawing or acting as a control.
///
/// Hover-presented surfaces use it as their root so the scheduler that opened them can count the
/// pointer crossing from the anchor onto the surface as staying. Keeping the tracking primitive
/// in the design system avoids each popover inventing another subtly different tracking area.
final class HoverTrackingView: NSView {

    var onHoverChange: ((Bool) -> Void)?
    /// Menus and popovers are presented outside this view's subtree. This callback lets a
    /// hover-owned container count them as part of the interaction that began inside it.
    var onThemedPresentationChange: ((Bool) -> Void)?

    /// An edge sensor observes geometry but must leave every click and drag to the content
    /// underneath it. Surface roots keep ordinary hit testing.
    var passesHitTestingThrough = false

    /// A window-edge affordance belongs only to the front window. Popover surface roots use
    /// `.activeAlways`, because an actionable child panel may temporarily become key.
    var tracksOnlyInKeyWindow = false {
        didSet { updateTrackingAreas() }
    }

    private var hoverTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [
                .mouseEnteredAndExited,
                tracksOnlyInKeyWindow ? .activeInKeyWindow : .activeAlways,
                .inVisibleRect
            ],
            owner: self
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }

    override func hitTest(_ point: NSPoint) -> NSView? {
        passesHitTestingThrough ? nil : super.hitTest(point)
    }
}

extension HoverTrackingView: ThemedMenuPresentationObserving {
    func themedMenuPresentationDidChange(isPresented: Bool) {
        onThemedPresentationChange?(isPresented)
    }
}

extension HoverTrackingView: ThemedPopoverPresentationObserving {
    func themedPopoverPresentationDidChange(isPresented: Bool) {
        onThemedPresentationChange?(isPresented)
    }
}

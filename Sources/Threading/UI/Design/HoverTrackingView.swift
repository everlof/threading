import AppKit

/// A container that reports pointer enter and exit without drawing or acting as a control.
///
/// Hover-presented surfaces use it as their root so the scheduler that opened them can count the
/// pointer crossing from the anchor onto the surface as staying. Keeping the tracking primitive
/// in the design system avoids each popover inventing another subtly different tracking area.
final class HoverTrackingView: NSView {

    var onHoverChange: ((Bool) -> Void)?

    private var hoverTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }
}

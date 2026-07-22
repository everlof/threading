import AppKit

// MARK: - Sidebar Hover Row View

/// Row container that paints a soft highlight while the pointer is over it.
///
/// Selection is drawn by the outline view itself; this fills the gap between "nothing" and
/// "selected", so rows read as clickable before they are clicked. Group headings do not get
/// one — they only expand from their disclosure, and a highlight would promise more.
final class SidebarHoverRowView: NSTableRowView {

    // MARK: - Properties

    private var trackingArea: NSTrackingArea?

    private var isMouseInside = false {
        didSet { needsDisplay = true }
    }

    // MARK: - Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isMouseInside = true
    }

    override func mouseExited(with event: NSEvent) {
        isMouseInside = false
    }

    // MARK: - Drawing

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)

        guard isMouseInside, !isSelected else { return }

        // Inset to match the rounded shape the source list draws for selection, so hover
        // and selection read as two strengths of the same affordance.
        let shape = bounds.insetBy(
            dx: SidebarRowDefaults.hoverHighlightInsetX,
            dy: SidebarRowDefaults.hoverHighlightInsetY
        )
        Design.Text.label
            .withAlphaComponent(SidebarRowDefaults.hoverHighlightAlpha)
            .setFill()
        NSBezierPath(
            roundedRect: shape,
            xRadius: SidebarRowDefaults.hoverHighlightRadius,
            yRadius: SidebarRowDefaults.hoverHighlightRadius
        ).fill()
    }
}

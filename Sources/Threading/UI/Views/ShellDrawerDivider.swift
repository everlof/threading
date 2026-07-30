import AppKit

/// The grab strip above the shell drawer.
///
/// A hand-rolled divider rather than an `NSSplitView`, because the pane is not a split: the
/// conversation fills it and the drawer is a strip taken off the bottom. A split view would
/// bring its own collapse behaviour, its own delegate and its own idea of priorities, all of
/// which would have to be argued out of the way.
///
/// It is a `BackdropOverlay` for the same reason the toolbar is: both surfaces it separates are
/// painted with the *terminal* palette, so a seam drawn in `Design.Surface.border` was measured
/// against the chrome's ground and disappeared into a dark terminal — one hairline that could
/// not be seen between two terminals that could.
final class ShellDrawerDivider: BackdropOverlay {

    /// Positive as the pointer moves down, which is the direction that *shrinks* the drawer.
    var onDrag: ((CGFloat) -> Void)?

    private var trackingArea: NSTrackingArea?
    private var isHovered = false { didSet { needsDisplay = true } }

    /// Nothing here is coloured outside `draw(_:)`; the redraw is what the ink change costs.
    override func applyInk(_ ink: Design.Ink) {
        needsDisplay = true
    }

    /// A seam at rest, the full grab strip under the pointer — with no content of its own, hover
    /// is the only thing that can say the strip is draggable before it is dragged.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        if isHovered {
            ink.surface.setFill()
            bounds.fill()
        }

        ink.border.setFill()
        let width = Design.Radius.border
        NSRect(x: 0, y: bounds.maxY - width, width: bounds.width, height: width).fill()
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

        // The divider moves whenever the drawer is resized, which is exactly when the pointer is
        // holding still — see `NSView.hoverIsStale`.
        if hoverIsStale(isHovered) { isHovered = false }
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func mouseDragged(with event: NSEvent) {
        onDrag?(event.deltaY)
    }
}

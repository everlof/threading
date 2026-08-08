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

    /// The release. The height constraint clamps at the drawer's floor while the hand keeps
    /// going, so only the owner's running total knows how far past it the drag went — this is
    /// the moment that overshoot becomes an answer, exactly as a split divider's release does
    /// (see `ThemedSplitView.dividerDragDidEnd`).
    var onDragEnded: (() -> Void)?

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

        // The *rule* ink: this strip is a rule between two panes, the same decision the pane
        // headers' separators and the split's seam take, and the one place the ink budget is
        // enforced. Over a backdrop the two inks coincide; the name is the point.
        //
        // Drawn at the *bottom* edge — the strip overlaps the surface above, so its bottom is
        // where the drawer actually begins. At the top edge the line floated its own height
        // above the tab strip, with a band of the conversation showing between rule and tabs.
        ink.rule.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: Design.Radius.border).fill()
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

    override func mouseUp(with event: NSEvent) {
        onDragEnded?()
    }
}

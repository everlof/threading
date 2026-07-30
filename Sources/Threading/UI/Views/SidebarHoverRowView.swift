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

    /// Fills a selected row with the theme's accent.
    ///
    /// This is the single most identity-carrying surface in the window, and the first pass left
    /// it to AppKit — so a Swiss Minimalist app whose whole identity is "one red accent" showed
    /// a grey selection, and Cyberpunk's neon appeared nowhere at all. A style that recolours
    /// the backdrop and leaves every foreground cue neutral reads as the same app in a
    /// different tint, which is exactly what it was.
    ///
    /// Under **System** this defers to `super` entirely, so the stock source-list selection —
    /// the user's own accent, its vibrancy, its unemphasised grey — is untouched.
    override func drawSelection(in dirtyRect: NSRect) {
        guard !AppThemeLibrary.current.isSystem else {
            return super.drawSelection(in: dirtyRect)
        }
        guard isSelected else { return }

        // Full accent while the sidebar has focus, muted when it does not — the same two
        // strengths AppKit distinguishes, so a background window does not shout.
        let fill = isEmphasized ? Design.Surface.accent : AppThemePalette.color(.accentMuted)
        fill.setFill()
        highlightPath.fill()
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)

        guard isMouseInside, !isSelected else { return }

        Design.Text.label
            .withAlphaComponent(SidebarRowDefaults.hoverHighlightAlpha)
            .setFill()
        highlightPath.fill()
    }

    /// The one silhouette hover and selection are both painted into.
    ///
    /// Both used to build their own, which was the same rectangle and *two different corners*:
    /// hover took a fixed radius and selection took the theme's. They agreed under the themes
    /// this was written against and parted company as soon as one shipped with square controls
    /// — a hovered row rounded, the selected row directly under it a hard-edged block of accent,
    /// on identical geometry. Two strengths of one affordance cannot be two shapes.
    private var highlightPath: NSBezierPath {
        let shape = bounds.insetBy(
            dx: SidebarRowDefaults.hoverHighlightInsetX,
            dy: SidebarRowDefaults.hoverHighlightInsetY
        )
        let radius = highlightRadius
        return NSBezierPath(roundedRect: shape, xRadius: radius, yRadius: radius)
    }

    /// The theme's control corner, because that is what the selection above is drawn with and
    /// what every other small surface in the window takes.
    ///
    /// Under **System** the selection is AppKit's own and never reaches `highlightPath`, so
    /// there is no theme silhouette for hover to agree with — it keeps the fixed corner that
    /// was measured against the stock source list.
    private var highlightRadius: CGFloat {
        AppThemeLibrary.current.isSystem
            ? SidebarRowDefaults.systemHoverHighlightRadius
            : Design.Radius.control
    }
}

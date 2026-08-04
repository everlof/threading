import AppKit

/// The border a chrome-takeover theme draws around the window's edges — the app-drawn half of
/// the frame the borderless mask gave up.
///
/// The host insets the band and the content by the theme's frame width, and this view paints
/// what shows in that margin: the theme's own ground, seated by a one-point line of its border
/// role at the very edge. Under a native frame it draws nothing at all — the window's rounded
/// corners and the terminal-palette backdrop showing through the titlebar strip are load-bearing
/// there (`TerminalContainerViewController.applyPaneBackground`), and an opaque fill here would
/// paint over both.
final class WindowChromeFrameView: NSView, ThemedComponent {

    init() {
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// A style stated by a fixture instead of resolved from the active theme.
    var fixtureStyle: WindowChromeAppearance.Resolved? {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let resolved = fixtureStyle ?? WindowChromeAppearance.resolve(),
              resolved.frameWidth > 0 else {
            return
        }

        let frameRect: NSRect
        switch resolved.shape {
        case .fullWidth:
            frameRect = bounds
        case .leadingTab:
            // The title tab is the only thing above the application body. Clear the rest with
            // copy compositing so a live full-width → tab theme switch cannot leave stale
            // pixels in the window's newly transparent shoulders.
            NSColor.clear.setFill()
            bounds.fill(using: .copy)
            frameRect = NSRect(
                x: bounds.minX,
                y: bounds.minY,
                width: bounds.width,
                height: max(0, bounds.height - resolved.bandHeight)
            )
        }

        Design.Surface.ground.setFill()
        frameRect.fill()

        // The window's edge wears the raised construction, not a hairline: measured off a
        // real 98 screenshot, a window's bottom-right runs #808080 then pure black to the
        // very edge, the same build as its buttons. Under a bevel material the theme's own
        // edge colours draw it; without one the border role seats a plain single ring, so a
        // future takeover theme without bevels still gets an edge.
        guard AppThemePalette.current.material.bevel != nil else {
            let seat = NSBezierPath(rect: frameRect.insetBy(dx: 0.5, dy: 0.5))
            seat.lineWidth = 1
            Design.Surface.border.setStroke()
            seat.stroke()
            return
        }

        let colors = BevelArtwork.edgeColors(
            highlight: Design.Surface.bevelHighlight,
            shadow: Design.Surface.bevelShadow,
            sunken: false
        )

        // Hard lines, never smoothed — the rule for every bevelled edge; see
        // `ThemedSurface.drawBevelled`.
        NSGraphicsContext.current?.saveGraphicsState()
        defer { NSGraphicsContext.current?.restoreGraphicsState() }
        NSGraphicsContext.current?.shouldAntialias = false

        func ring(_ rect: NSRect, topLeft: NSColor, bottomRight: NSColor) {
            bottomRight.setFill()
            NSRect(x: rect.maxX - 1, y: rect.minY, width: 1, height: rect.height).fill()
            NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 1).fill()
            topLeft.setFill()
            NSRect(x: rect.minX, y: rect.maxY - 1, width: rect.width - 1, height: 1).fill()
            NSRect(x: rect.minX, y: rect.minY + 1, width: 1, height: rect.height - 1).fill()
        }

        ring(frameRect, topLeft: colors.topLeftOuter, bottomRight: colors.bottomRightOuter)
        ring(frameRect.insetBy(dx: 1, dy: 1),
             topLeft: colors.topLeftInner, bottomRight: colors.bottomRightInner)
    }
}

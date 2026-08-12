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

        let cornerRadius = resolved.shape == .fullWidth
            ? resolved.frameCornerRadius
            : 0
        let framePath = NSBezierPath(
            roundedRect: frameRect,
            xRadius: cornerRadius,
            yRadius: cornerRadius
        )
        if cornerRadius > 0 {
            // The untitled window mask is rectangular. Clear the four outer corner pixels so
            // the nonopaque window and its shadow follow the authored Aqua curve.
            NSColor.clear.setFill()
            bounds.fill(using: .copy)
        }
        Design.Surface.ground.setFill()
        framePath.fill()

        // The window's edge wears the raised construction, not a hairline: measured off a
        // real 98 screenshot, a window's bottom-right runs #808080 then pure black to the
        // very edge, the same build as its buttons. Under a bevel material the theme's own
        // edge colours draw it; without one a stronger structural ring seats the window. The
        // ordinary border role is intentionally as quiet as an in-panel separator under System
        // and was effectively invisible at the outermost window edge in both appearances.
        guard AppThemePalette.current.material.bevel != nil else {
            let seatRect = frameRect.insetBy(dx: 0.5, dy: 0.5)
            let seat = NSBezierPath(
                roundedRect: seatRect,
                xRadius: max(0, cornerRadius - 0.5),
                yRadius: max(0, cornerRadius - 0.5)
            )
            seat.lineWidth = 1
            Design.Text.tertiary.setStroke()
            seat.stroke()
            return
        }

        if cornerRadius > 0 {
            ThemedSurface.draw(
                frameRect,
                fill: Design.Surface.ground,
                border: Design.Surface.border,
                radius: cornerRadius,
                bevel: .automatic
            )
            return
        }

        // Hard lines, never smoothed — the rule for every bevelled edge; see
        // `ThemedSurface.drawBevelled`. The construction itself is the shared
        // `WindowChromeBevelEdge`, the same rings the BeOS tab wears.
        NSGraphicsContext.current?.saveGraphicsState()
        defer { NSGraphicsContext.current?.restoreGraphicsState() }
        NSGraphicsContext.current?.shouldAntialias = false

        WindowChromeBevelEdge.drawRaisedRings(around: frameRect)
    }
}

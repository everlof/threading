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
///
/// The margin is the same width the whole way round, corners included: under a rounded frame
/// the host clips the content to the frame's *inner* curve (`WindowChromeHostViewController`),
/// so the seat drawn here stays visible where the outline turns. Before that clip the band and
/// workspace, inset only on their four sides, reached square into every corner and covered the
/// curved run of the seat — the outline read as two straight lines that stopped short of each
/// other, with the content's own rounded edge between them.
final class WindowChromeFrameView: NSView, ThemedComponent {

    /// The faintest an outer edge may be before it stops separating the window from its
    /// surround. Unlike an in-pane rule, this line has no known ground on its far side, so the
    /// floor is held slightly above `ThemedSplitView`'s internal-seam threshold.
    private static let minimumPlainEdgeContrast: CGFloat = 1.35

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

        let cornerRadius = resolved.frameSilhouetteCornerRadius
        let framePath = NSBezierPath(
            roundedRect: frameRect,
            xRadius: cornerRadius,
            yRadius: cornerRadius
        )

        // A pixel grammar still needs the transparent silhouette supplied by a radius, but its
        // pen has no partial coverage. Keep fill and seat under one rasterization rule: hardening
        // only the stroke leaves the ground fill's antialiased skirt visible as a dark halo.
        NSGraphicsContext.current?.saveGraphicsState()
        defer { NSGraphicsContext.current?.restoreGraphicsState() }
        NSGraphicsContext.current?.shouldAntialias = resolved.frameAntialiasesCorners

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
        // edge colours draw it; without one the theme's own border seats the window wherever it
        // already reads on the ground. This is load-bearing for flat authored chrome such as
        // TUI, whose title seam, control rules, and frame are one continuous drawing. A quiet
        // derived border under System still takes the stronger measured fallback that originally
        // made the outer edge visible.
        guard AppThemePalette.current.material.bevel != nil else {
            let seatRect = frameRect.insetBy(dx: 0.5, dy: 0.5)
            let seat = NSBezierPath(
                roundedRect: seatRect,
                xRadius: max(0, cornerRadius - 0.5),
                yRadius: max(0, cornerRadius - 0.5)
            )
            seat.lineWidth = 1
            plainEdgeInk().setStroke()
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
        NSGraphicsContext.current?.shouldAntialias = false

        WindowChromeBevelEdge.drawRaisedRings(around: frameRect)
    }

    /// Prefers the authored structural ink and raises it only when that ink would disappear.
    /// Contrast is measured after compositing because a theme role may be translucent; asking
    /// the stored colour would measure a pixel nobody actually sees.
    private func plainEdgeInk() -> NSColor {
        // Resolve concrete values for the measurement. `Design.Surface` roles are dynamic
        // colours; resolving one through another here can lose the drawing appearance inside
        // the nested provider and classify a fixed dark theme against System's light values.
        let theme = AppThemePalette.current
        let appearance = NSAppearance.currentDrawing()
        let ground = theme.resolved(.ground, appearance: appearance)
        let border = theme.resolved(.border, appearance: appearance)
        let effectiveBorder = ground.composited(under: border)
        guard ThemeContrast.ratio(effectiveBorder, ground)
                < Self.minimumPlainEdgeContrast else {
            // Draw through the semantic role so Increase Contrast is still applied live.
            return Design.Surface.border
        }
        return Design.Text.tertiary
    }
}

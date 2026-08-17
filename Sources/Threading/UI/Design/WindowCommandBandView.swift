import AppKit

/// The command row directly below an app-drawn title bar.
///
/// A native toolbar disappears while a chrome theme owns the frame, but its application
/// commands do not become title-bar furniture as a consequence. Classic desktop chrome makes
/// that distinction especially visible: the title band contains only window identity and
/// caption buttons; navigation lives on the button-face row below it. This component preserves
/// that structure for every takeover theme and gives those controls the ordinary chrome ink
/// they sit on.
///
/// The row is a pane band like the ones heading the panes below it, and it is laid out by the
/// same component: `PaneHeaderView` states the band height, the edge-to-edge rule, the
/// ink-aligned margin and the spacing between siblings. It used to re-derive that geometry
/// with a raw stack at its own inset, and got it subtly wrong the way each pane once did —
/// the sidebar toggle's active box sat four points off the window's corner while every band
/// below started its ink twelve points in. This view adds only what the chrome needs on top
/// of the band: the button-face fill behind the row.
final class WindowCommandBandView: NSView, ThemedComponent {

    /// `PaneHeaderView`'s measure, not one of this view's own: the chrome host reads it to
    /// size the strip, and the theme's authored rule weight is part of it, so it is a value
    /// that must be re-read on a theme change rather than a constant.
    static var bandHeight: CGFloat { PaneHeaderView.bandHeight }

    private var band: PaneHeaderView?
    private var themeRedraw: ThemeRedraw?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        installBand(leading: [])
        themeRedraw = ThemeRedraw(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setLeadingControls(_ views: [NSView]) {
        installBand(leading: views)
    }

    /// `PaneHeaderView` takes its controls at construction, so new controls are a new band.
    /// The flip that hands them over is rare and the band is a handful of views.
    private func installBand(leading: [NSView]) {
        band?.removeFromSuperview()

        // The band's own edges, not the corner-adapted region: this strip sits below the
        // title band where the frame has finished curving, and its ink heads the same column
        // the sidebar's bands start at the pane's edge.
        let band = PaneHeaderView(leading: leading, margin: .paneEdge)
        addSubview(band)

        // In native dress the chrome host holds this strip at zero height while the band
        // keeps its own stated measure, so the bottom pin yields instead of fighting the
        // collapse.
        let bottom = band.bottomAnchor.constraint(equalTo: bottomAnchor)
        bottom.priority = NSLayoutConstraint.Priority(999)

        NSLayoutConstraint.activate([
            band.topAnchor.constraint(equalTo: topAnchor),
            band.leadingAnchor.constraint(equalTo: leadingAnchor),
            band.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottom
        ])
        self.band = band
    }

    override func draw(_ dirtyRect: NSRect) {
        ThemedSurface.draw(
            bounds,
            fill: Design.Surface.background,
            radius: 0,
            bevel: .none
        )
    }

    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
}

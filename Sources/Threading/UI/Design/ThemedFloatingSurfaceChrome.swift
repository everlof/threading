import AppKit

/// Resolves the shared material grammar for an app-owned surface floating above live content.
///
/// A popover and the session corner card differ in placement, not in visual ownership: both
/// need an opaque semantic fill, the theme's corner/edge construction, and exactly one depth
/// treatment. Keeping that interpretation here prevents an overlay from rebuilding a second,
/// almost-the-same version of `Material.PopoverStyle`.
@MainActor
struct ThemedFloatingSurfaceChrome {
    let style: AppTheme.Material.PopoverStyle
    let material: AppTheme.Material
    let fill: NSColor
    let ink: Design.Ink

    static func current(for appearance: NSAppearance) -> ThemedFloatingSurfaceChrome {
        let theme = AppThemePalette.current
        let material = theme.material(for: appearance)
        let style = material.popoverStyle
        let fill = theme.resolved(style.surfaceRole, appearance: appearance)
            .composited(over: theme.resolved(.ground, appearance: appearance))
        return ThemedFloatingSurfaceChrome(
            style: style,
            material: material,
            fill: fill,
            ink: .chrome
        )
    }

    /// Applies the layer-backed form of the grammar. The popover owns its joined arrow path;
    /// ordinary floating cards use the material's corner, while a compact semantic shape such
    /// as the scroll-to-end target supplies its own. The override changes only geometry: fill,
    /// edge construction and depth remain the one floating-surface contract.
    func apply(to view: NSView, radius radiusOverride: SurfaceRadius? = nil) {
        let materialEdge = style.edge == .material && material.bevel != nil
        let flatEdge = style.edge == .flat || (style.edge == .material && !materialEdge)
        let materialShadow = material.glow != nil
            && (style.shadow == .material || style.shadow == .automatic)
        let systemShadow = style.shadow == .system
            || (style.shadow == .automatic && !materialShadow)
        let radius = radiusOverride
            ?? style.cornerRadius.map(SurfaceRadius.fixed)
            ?? .panel

        view.applySurface(
            fill: fill,
            radius: radius,
            border: flatEdge ? Design.Surface.border.composited(over: fill) : nil,
            glow: materialShadow,
            bevel: materialEdge ? .automatic : .none
        )

        // A child-window popover receives the platform's window shadow. An embedded floating
        // card does not, so the same `.system`/`.automatic` material otherwise loses the depth
        // that separates it from the pane it covers. The neutral shadow is intentional: every
        // themed colour follows that pane, while depth has to remain visible over all of them.
        guard systemShadow else { return }
        view.layer?.masksToBounds = false
        view.applyLayerShadow(.black)
        view.layer?.shadowOpacity = Metrics.systemShadowOpacity
        view.layer?.shadowRadius = Metrics.systemShadowRadius
        view.layer?.shadowOffset = .zero
    }

    private enum Metrics {
        static let systemShadowOpacity: Float = 0.24
        static let systemShadowRadius: CGFloat = 12
    }
}

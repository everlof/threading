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

    /// Applies the rectangular form of the grammar. The popover owns its joined arrow path;
    /// ordinary floating cards use this shared layer-backed surface interpreter.
    func apply(to view: NSView) {
        let materialEdge = style.edge == .material && material.bevel != nil
        let flatEdge = style.edge == .flat || (style.edge == .material && !materialEdge)
        let materialShadow = material.glow != nil
            && (style.shadow == .material || style.shadow == .automatic)

        view.applySurface(
            fill: fill,
            radius: .panel,
            border: flatEdge ? Design.Surface.border.composited(over: fill) : nil,
            glow: materialShadow,
            bevel: materialEdge ? .automatic : .none
        )
    }
}

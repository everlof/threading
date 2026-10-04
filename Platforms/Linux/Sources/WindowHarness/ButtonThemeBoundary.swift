import AppKit

// The Linux theme export currently carries the modern, flat button material. Keep the
// production button's material vocabulary here so its drawing and interaction stay shared.
@MainActor
enum ButtonThemeRole: Equatable {
    case accent, controlResting, controlHover
}

extension AppTheme {
    public struct Glow {}
}

extension AppTheme.Material {
    var buttonStyle: ButtonStyle { .init() }
    var controlGlow: AppTheme.Glow? { nil }
    var glow: AppTheme.Glow? { nil }

    struct ButtonStyle {
        enum TextTransform { case none, uppercase }
        enum TitleRendering { case font, pixel5x6 }
        enum PrimaryTreatment { case filled, outlined, raised }
        enum SecondaryShadow { case control, panel, none }

        var textTransform: TextTransform = .none
        var titleRendering: TitleRendering = .font
        var fontWeight: NSFont.Weight = .medium
        var tracking: CGFloat = 0
        var fontScale: CGFloat = 1
        var minimumWidth: CGFloat?
        var minimumHeight: CGFloat?
        var embossesDisabledTitle = false
        var antialiasesTitle = true
        var primaryTreatment: PrimaryTreatment = .filled
        var primaryRole: ButtonThemeRole = .accent
        var secondaryRole: ButtonThemeRole = .controlResting
        var secondaryHoverRole: ButtonThemeRole = .controlHover
        var secondaryShadow: SecondaryShadow = .none
        var primaryBorderRole: ButtonThemeRole?
        var hoverOffsetX: CGFloat = 0
        var hoverOffsetY: CGFloat = 0
        var pressedOffsetX: CGFloat = 0
        var pressedOffsetY: CGFloat = 0
        var collapseShadowOnHover = false
    }
}

extension AppThemePalette.Material {
    var buttonStyle: AppTheme.Material.ButtonStyle { .init() }
    var controlGlow: AppTheme.Glow? { nil }
    var glow: AppTheme.Glow? { nil }
}

extension AppThemePalette {
    static func color(_ role: ButtonThemeRole) -> NSColor {
        switch role {
        case .accent: LinuxTheme.color("accent")
        case .controlResting: LinuxTheme.color("controlResting")
        case .controlHover: LinuxTheme.color("controlHover")
        }
    }
}

extension Design.Ink {
    static var primaryAction: Design.Ink {
        let accent = LinuxTheme.color("accent")
        return Design.Ink(on: accent, surface: accent.withAlphaComponent(0.18))
    }
}

extension Design.Typography {
    static func button(style: AppTheme.Material.ButtonStyle) -> NSFont {
        NSFont.systemFont(ofSize: 12 * style.fontScale, weight: style.fontWeight)
    }
}

extension Design.Size {
    static let floatingNavigationTarget: CGFloat = 40
}

extension Design.Motion {
    static let floatingTargetArrive: TimeInterval = 0.22
    static let vanish: TimeInterval = 0.12
    static let immediate: TimeInterval = 0
    static let drop = CAMediaTimingFunction(controlPoints: 0.55, 0, 1, 0.45)
    static let lift = CAMediaTimingFunction(controlPoints: 0, 0, 0.58, 1)
}

struct WindowBackdropDidChange {}

@MainActor
enum WindowBackdrop {
    static var color: NSColor { InkSource.backdropGround }
}

extension SurfaceRadius {
    var current: CGFloat { value }
}

@MainActor
enum ThemedFloatingSurfaceChrome {
    static func current(for appearance: NSAppearance) -> ThemedFloatingSurfaceChrome.Type {
        self
    }

    static func apply(to view: ThemedButton, radius: SurfaceRadius) {
        view.setAppliedSurface(fill: LinuxTheme.color("controlResting"), radius: radius.current)
    }
}

extension ThemedControl {
    func applyThemeControlGlow(_ glow: AppTheme.Glow?, radius: CGFloat) {
        precondition(glow == nil, "The checked Linux theme has no control glow")
    }
}

import AppKit

/// Region colors exported from AppThemeStyles.threading, verified with their supported
/// static-gradient/flat-well shape by LinuxThemeSnapshotTests on the production platform.
@MainActor enum SidebarAppearance {
    struct NavigatorWell {
        let fill: NSColor
        let bevel: SurfaceBevel
        let edgeWidth: CGFloat
    }
    static func navigatorWell(for appearance: NSAppearance) -> NavigatorWell? { nil }
    static var bandGround: NSColor { LinuxTheme.color("sidebar.gradientStart") }
    static var bandInk: Design.Ink { Design.Ink(on: bandGround) }
    static var brandMark: NSColor { LinuxTheme.color("sidebar.brandMark") }
    static var brandFont: NSFont { .systemFont(ofSize: 13, weight: .semibold) }
    static let backgroundColors = [LinuxTheme.color("sidebar.gradientStart"),
                                   LinuxTheme.color("sidebar.gradientEnd")]
    static var navigatorFill: NSColor { LinuxTheme.color("sidebar.navigatorWell") }
}

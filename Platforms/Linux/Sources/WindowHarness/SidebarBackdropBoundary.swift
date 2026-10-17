import AppKit

/// Region colors exported from AppThemeStyles.threading, verified with their supported
/// static-gradient/flat-well shape by LinuxThemeSnapshotTests on the production platform.
enum SidebarAppearance {
    static var brandMark: NSColor { LinuxTheme.color("sidebar.brandMark") }
    static var brandFont: NSFont { .systemFont(ofSize: 13, weight: .semibold) }
    static let backgroundColors = [LinuxTheme.color("sidebar.gradientStart"),
                                   LinuxTheme.color("sidebar.gradientEnd")]
    static var navigatorFill: NSColor { LinuxTheme.color("sidebar.navigatorWell") }
}

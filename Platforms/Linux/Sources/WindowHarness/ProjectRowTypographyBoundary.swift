import AppKit

enum L10n {
    static func string(_ value: String) -> String { value }
}

/// The native project row is shared with macOS. Linux supplies the platform font leaf while
/// retaining the same production role sizes; theme-wide typography remains to be mounted.
@MainActor
enum ProjectRowLinuxTypography {
    static func titleFont(for role: NavigatorProjectRowPresentation.TitleRole) -> NSFont {
        switch role {
        case .emphasizedBody:
            return NSFont.systemFont(ofSize: SidebarRowDefaults.projectFontSize, weight: .semibold)
        case .caption:
            return NSFont.systemFont(ofSize: SidebarRowDefaults.headingFontSize, weight: .regular)
        }
    }

    static var pathFont: NSFont {
        NSFont.systemFont(ofSize: SidebarRowDefaults.projectFontSize)
    }

    static var countFont: NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: SidebarRowDefaults.countFontSize, weight: .regular)
    }
}

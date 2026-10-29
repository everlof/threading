import AppKit

/// Shared status-slot geometry for session and standalone-terminal rows.
enum StatusIndicatorDefaults {
    static let size: CGFloat = SidebarRowDefaults.sessionStatusSize
    static let spinnerSize: CGFloat = 12
    static let dotSize: CGFloat = 6
    static let backgroundDotSize: CGFloat = SidebarRowDefaults.sessionBackgroundDotSize
    static let finishedDotSize: CGFloat = 7
}

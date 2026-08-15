import Foundation

struct ThemesDidChange: AppEvent {
    static let name = Notification.Name("themesDidChange")
}

struct ThemeAssignmentsDidChange: AppEvent {
    static let name = Notification.Name("themeAssignmentsDidChange")
}

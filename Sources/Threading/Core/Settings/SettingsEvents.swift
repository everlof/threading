import Foundation

public struct AppSettingsDidChange: AppEvent {
    public static let name = Notification.Name("appSettingsDidChange")
}

public struct AccountPreferencesDidChange: AppEvent {
    public static let name = Notification.Name("accountPreferencesDidChange")
}

public struct ProfileDidChange: AppEvent {
    public static let name = Notification.Name("profileDidChange")
    public let profile: TerminalProfile
}

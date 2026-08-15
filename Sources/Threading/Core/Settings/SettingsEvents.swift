import Foundation

struct AppSettingsDidChange: AppEvent {
    static let name = Notification.Name("appSettingsDidChange")
}

struct AccountPreferencesDidChange: AppEvent {
    static let name = Notification.Name("accountPreferencesDidChange")
}

struct ProfileDidChange: AppEvent {
    static let name = Notification.Name("profileDidChange")
    let profile: TerminalProfile
}

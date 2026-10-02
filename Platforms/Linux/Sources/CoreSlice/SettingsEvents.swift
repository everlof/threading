import Foundation

public struct AppSettingsDidChange: AppEvent {
    public static let name = Notification.Name("appSettingsDidChange")

    /// Nil means the publisher cannot name the setting and consumers must conservatively
    /// re-read everything they depend on. Descriptor-backed writes always carry one identity.
    public let changedSettings: Set<String>?

    public init(changedSettings: Set<String>? = nil) {
        self.changedSettings = changedSettings
    }

    public init(changedSetting: String) {
        changedSettings = [changedSetting]
    }

    public func affects(_ settings: String...) -> Bool {
        guard let changedSettings else { return true }
        return !changedSettings.isDisjoint(with: settings)
    }
}

public struct AccountPreferencesDidChange: AppEvent {
    public static let name = Notification.Name("accountPreferencesDidChange")
}

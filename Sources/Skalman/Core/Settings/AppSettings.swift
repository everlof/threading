import Foundation

/// Application-wide preferences backed by `UserDefaults`.
///
/// Terminal appearance lives in `TerminalProfile` and per-account customisation in
/// `AccountPreferencesStore`; this covers the behavioural settings shown on the General tab.
final class AppSettings {

    // MARK: - Singleton

    static let shared = AppSettings()

    private let defaults: UserDefaults

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        registerDefaults()
    }

    // MARK: - Settings

    /// Agent used when creating a session without naming one explicitly.
    var defaultAgentKind: AgentKind {
        get {
            guard let raw = defaults.string(forKey: Keys.defaultAgentKind),
                  let kind = AgentKind(rawValue: raw) else { return AgentDefaults.defaultKind }
            return kind
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.defaultAgentKind)
            notifyChanged()
        }
    }

    /// Whether the previously selected session is reopened at launch.
    var restoresLastSession: Bool {
        get { defaults.bool(forKey: Keys.restoresLastSession) }
        set {
            defaults.set(newValue, forKey: Keys.restoresLastSession)
            notifyChanged()
        }
    }

    /// Whether closing a session with a running agent asks for confirmation first.
    var confirmsBeforeClosingRunningSession: Bool {
        get { defaults.bool(forKey: Keys.confirmsBeforeClosingRunningSession) }
        set {
            defaults.set(newValue, forKey: Keys.confirmsBeforeClosingRunningSession)
            notifyChanged()
        }
    }

    /// Whether the sidebar follows the title reported by the terminal.
    var usesTerminalTitleInSidebar: Bool {
        get { defaults.bool(forKey: Keys.usesTerminalTitleInSidebar) }
        set {
            defaults.set(newValue, forKey: Keys.usesTerminalTitleInSidebar)
            notifyChanged()
        }
    }

    // MARK: - Private Methods

    /// Opt-in settings default to off; the rest are seeded so first launch behaves sensibly.
    private func registerDefaults() {
        defaults.register(defaults: [
            Keys.defaultAgentKind: AgentDefaults.defaultKind.rawValue,
            Keys.restoresLastSession: true,
            Keys.confirmsBeforeClosingRunningSession: true,
            Keys.usesTerminalTitleInSidebar: true
        ])
    }

    private func notifyChanged() {
        NotificationCenter.default.post(name: .appSettingsDidChange, object: self)
    }

    // MARK: - Keys

    private enum Keys {
        static let defaultAgentKind = "defaultAgentKind"
        static let restoresLastSession = "restoresLastSession"
        static let confirmsBeforeClosingRunningSession = "confirmsBeforeClosingRunningSession"
        static let usesTerminalTitleInSidebar = "usesTerminalTitleInSidebar"
    }
}

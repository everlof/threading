import Foundation

/// Application-wide preferences backed by `UserDefaults`.
///
/// Terminal appearance lives in `TerminalProfile` and per-account customisation in
/// `AccountPreferencesStore`; this covers the behavioural settings shown on the General tab.
@MainActor
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
        get { Self.usesTerminalTitleInSidebar }
        set {
            defaults.set(newValue, forKey: Keys.usesTerminalTitleInSidebar)
            notifyChanged()
        }
    }

    /// The same flag, readable off the main actor.
    ///
    /// `AgentSession.displayTitle` is a plain computed property on a value type, read wherever
    /// a session is — including from the transcript scan and the importer, neither of which is
    /// main-actor isolated. `UserDefaults` is thread-safe, so the isolation buys nothing for a
    /// read; only the setter needs it, because it posts a notification the UI observes.
    nonisolated static var usesTerminalTitleInSidebar: Bool {
        UserDefaults.standard.bool(forKey: Keys.usesTerminalTitleInSidebar)
    }

    /// Likewise for the sidebar's branch grouping, which `SidebarTreeBuilder` consults while
    /// building nodes from plain model values.
    nonisolated static var groupsSessionsByBranch: Bool {
        UserDefaults.standard.bool(forKey: Keys.groupsSessionsByBranch)
    }

    /// Whether the sidebar gathers a project's sessions under the branch they ran on,
    /// where a branch has more than one.
    var groupsSessionsByBranch: Bool {
        get { Self.groupsSessionsByBranch }
        set {
            defaults.set(newValue, forKey: Keys.groupsSessionsByBranch)
            notifyChanged()
        }
    }

    /// Whether projects without an icon look for one automatically — the checkout's own
    /// favicon or app icon, then the repository's GitHub avatar or homepage favicon.
    /// The network sources only ever contact hosts the project itself points at.
    var discoversProjectIcons: Bool {
        get { defaults.bool(forKey: Keys.discoversProjectIcons) }
        set {
            defaults.set(newValue, forKey: Keys.discoversProjectIcons)
            notifyChanged()
        }
    }

    /// Whether sessions show their account's avatar, looked up from its login email via
    /// Gravatar or GitHub's public-email search. Off sends nothing anywhere.
    var discoversAccountAvatars: Bool {
        get { defaults.bool(forKey: Keys.discoversAccountAvatars) }
        set {
            defaults.set(newValue, forKey: Keys.discoversAccountAvatars)
            notifyChanged()
        }
    }

    // MARK: - MCP Tool Groups

    /// The tool groups the user has switched *off* on the Tools page. Stored as the disabled set,
    /// not the enabled one, so a group added in a future release is on by default rather than
    /// absent — an omitted id reads as enabled.
    var disabledToolGroupIDs: Set<String> {
        get { Set(defaults.stringArray(forKey: Keys.disabledToolGroupIDs) ?? []) }
        set {
            defaults.set(Array(newValue), forKey: Keys.disabledToolGroupIDs)
            notifyChanged()
        }
    }

    func isToolGroupEnabled(_ id: String) -> Bool {
        !disabledToolGroupIDs.contains(id)
    }

    func setToolGroup(_ id: String, enabled: Bool) {
        var disabled = disabledToolGroupIDs
        if enabled { disabled.remove(id) } else { disabled.insert(id) }
        disabledToolGroupIDs = disabled
    }

    // MARK: - Private Methods

    /// Opt-in settings default to off; the rest are seeded so first launch behaves sensibly.
    private func registerDefaults() {
        defaults.register(defaults: [
            Keys.defaultAgentKind: AgentDefaults.defaultKind.rawValue,
            Keys.restoresLastSession: true,
            Keys.confirmsBeforeClosingRunningSession: true,
            Keys.usesTerminalTitleInSidebar: true,
            Keys.groupsSessionsByBranch: true,
            Keys.discoversProjectIcons: true,
            Keys.discoversAccountAvatars: true
        ])
    }

    private func notifyChanged() {
        NotificationCenter.default.post(AppSettingsDidChange())
    }

    // MARK: - Keys

    private enum Keys {
        static let defaultAgentKind = "defaultAgentKind"
        static let restoresLastSession = "restoresLastSession"
        static let confirmsBeforeClosingRunningSession = "confirmsBeforeClosingRunningSession"
        static let usesTerminalTitleInSidebar = "usesTerminalTitleInSidebar"
        static let groupsSessionsByBranch = "groupsSessionsByBranch"
        static let discoversProjectIcons = "discoversProjectIcons"
        static let discoversAccountAvatars = "discoversAccountAvatars"
        static let disabledToolGroupIDs = "disabledToolGroupIDs"
    }
}

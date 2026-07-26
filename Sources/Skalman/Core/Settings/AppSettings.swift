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

    init(defaults: UserDefaults = .standard) {
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

    /// Whether the sidebar follows the agent's own name for the conversation — the terminal
    /// title while a PTY is attached, the transcript's title records otherwise.
    var usesAgentTitleInSidebar: Bool {
        get { Self.usesAgentTitleInSidebar }
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
    ///
    /// The defaults key keeps its old name — the terminal was once the only transport, and
    /// renaming the key would silently reset the user's choice.
    nonisolated static var usesAgentTitleInSidebar: Bool {
        _ = registerStandardDefaults
        return UserDefaults.standard.bool(forKey: Keys.usesTerminalTitleInSidebar)
    }

    /// Likewise for the sidebar's branch grouping, which `SidebarTreeBuilder` consults while
    /// building nodes from plain model values.
    nonisolated static var groupsSessionsByBranch: Bool {
        _ = registerStandardDefaults
        return UserDefaults.standard.bool(forKey: Keys.groupsSessionsByBranch)
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

    /// The working indicator shown for each newly-started conversation turn.
    var workingOrbStyle: WorkingOrbStyle {
        get {
            defaults.string(forKey: Keys.workingOrbStyle)
                .flatMap(WorkingOrbStyle.init(rawValue:))
                ?? MotionPreferencesDefaults.workingOrbStyle
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.workingOrbStyle)
            notifyChanged()
        }
    }

    /// The character animation used when the active chat's visible name changes.
    var chatNameMorphStyle: ChatNameMorphStyle {
        get {
            defaults.string(forKey: Keys.chatNameMorphStyle)
                .flatMap(ChatNameMorphStyle.init(rawValue:))
                ?? MotionPreferencesDefaults.chatNameMorphStyle
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.chatNameMorphStyle)
            notifyChanged()
        }
    }

    // MARK: - Attachment Detection

    /// Agent kinds whose prose and terminal output should not be scanned for visual files.
    ///
    /// Stored as the disabled set so detection is an opt-out: both current agents, and any
    /// future agent kind, start enabled without requiring a defaults migration.
    private var disabledAttachmentDetectionAgentKinds: Set<AgentKind> {
        get {
            Set(
                (defaults.stringArray(forKey: Keys.disabledAttachmentDetectionAgentKinds) ?? [])
                    .compactMap(AgentKind.init(rawValue:))
            )
        }
        set {
            defaults.set(
                newValue.map(\.rawValue).sorted(),
                forKey: Keys.disabledAttachmentDetectionAgentKinds
            )
            notifyChanged()
        }
    }

    /// Whether automatic path detection is enabled for this agent's terminal and Native output.
    func detectsAttachmentReferences(for kind: AgentKind) -> Bool {
        !disabledAttachmentDetectionAgentKinds.contains(kind)
    }

    func setAttachmentReferenceDetection(for kind: AgentKind, enabled: Bool) {
        var disabled = disabledAttachmentDetectionAgentKinds
        if enabled {
            disabled.remove(kind)
        } else {
            disabled.insert(kind)
        }
        disabledAttachmentDetectionAgentKinds = disabled
    }

    // MARK: - Extensions

    /// Legacy developer default retained only so existing preferences decode unchanged.
    ///
    /// `ExtensionManager` deliberately ignores it: App Sandbox permits legacy login-Keychain
    /// ACL authorization UI, while the generated Seatbelt product policy denies the securityd
    /// boundary itself. The helper remains a focused containment test harness, not a product
    /// launch option.
    ///
    /// See `docs/extensions/SANDBOX_RUNNER.md`.
    var usesContainedExtensionLauncher: Bool {
        get { defaults.bool(forKey: Keys.usesContainedExtensionLauncher) }
        set {
            defaults.set(newValue, forKey: Keys.usesContainedExtensionLauncher)
            notifyChanged()
        }
    }

    // MARK: - Agent Hooks

    /// Whether Skalman installs its lifecycle hooks into each Codex account's `hooks.json`.
    ///
    /// Off by default because it writes to a file the user owns and may already be using —
    /// this machine's own `~/.codex/hooks.json` was written by another tool. Installation
    /// merges rather than replaces, but the honest default for touching someone else's config
    /// is to ask first.
    var installsCodexHooks: Bool {
        get { defaults.bool(forKey: Keys.installsCodexHooks) }
        set {
            defaults.set(newValue, forKey: Keys.installsCodexHooks)
            notifyChanged()
        }
    }

    /// Whether Codex sessions launch with `--dangerously-bypass-hook-trust`.
    ///
    /// Codex refuses to run a hook until its exact text has been reviewed, and review happens
    /// in the interactive TUI — which a session Skalman launches never shows. The flag skips
    /// that gate.
    ///
    /// Off by default, and the wording on the settings page says why rather than leaving it to
    /// the name: the flag un-gates **every** hook in that config directory, not only Skalman's.
    /// Since an agent can write to `hooks.json`, turning this on means an agent could arrange
    /// for its own code to run unreviewed on the next launch. Trusting once in the TUI costs a
    /// single step and keeps the gate.
    ///
    /// Skalman's own entries are built to survive that one review: the port and session token
    /// reach the hook through the environment, so the text in `hooks.json` never changes and a
    /// trust decision is not invalidated by the next app launch.
    var bypassesCodexHookTrust: Bool {
        get { defaults.bool(forKey: Keys.bypassesCodexHookTrust) }
        set {
            defaults.set(newValue, forKey: Keys.bypassesCodexHookTrust)
            notifyChanged()
        }
    }

    // MARK: - Remote Access

    /// Whether the remote-access server runs (and, once implemented, its tunnel). Off by
    /// default: even the loopback-only first milestone exposes interactive terminal access to
    /// any process holding its private link, so it exists only when the user turns it on.
    var remoteAccessEnabled: Bool {
        get { defaults.bool(forKey: Keys.remoteAccessEnabled) }
        set {
            defaults.set(newValue, forKey: Keys.remoteAccessEnabled)
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
        defaults.register(defaults: Self.seeds)
    }

    /// The seeded values, and the one place they are registered on the standard defaults.
    ///
    /// This used to happen only in `init`, while the `nonisolated static` readers below go
    /// straight to `UserDefaults.standard` — so a read that happened before anything touched
    /// `AppSettings.shared` saw an *unregistered* key and `bool(forKey:)` answered `false`,
    /// which for every seeded setting here is the opposite of its documented default. The
    /// sidebar's branch grouping is the one that showed it: documented as on, and off in any
    /// process that built a tree before instantiating the singleton. Registration is idempotent
    /// and cheap, so the readers do it themselves rather than depending on an order.
    private static let registerStandardDefaults: Void = {
        UserDefaults.standard.register(defaults: seeds)
    }()

    private static var seeds: [String: Any] {
        [
            Keys.defaultAgentKind: AgentDefaults.defaultKind.rawValue,
            Keys.restoresLastSession: true,
            Keys.confirmsBeforeClosingRunningSession: true,
            Keys.usesTerminalTitleInSidebar: true,
            Keys.groupsSessionsByBranch: true,
            Keys.discoversProjectIcons: true,
            Keys.discoversAccountAvatars: true,
            Keys.workingOrbStyle: MotionPreferencesDefaults.workingOrbStyle.rawValue,
            Keys.chatNameMorphStyle: MotionPreferencesDefaults.chatNameMorphStyle.rawValue
        ]
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
        static let disabledAttachmentDetectionAgentKinds = "disabledAttachmentDetectionAgentKinds"
        static let disabledToolGroupIDs = "disabledToolGroupIDs"
        static let usesContainedExtensionLauncher = "usesContainedExtensionLauncher"
        static let installsCodexHooks = "installsCodexHooks"
        static let bypassesCodexHookTrust = "bypassesCodexHookTrust"
        static let remoteAccessEnabled = "remoteAccessEnabled"
        static let workingOrbStyle = "workingOrbStyle"
        static let chatNameMorphStyle = "chatNameMorphStyle"
    }
}

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

    /// Whether 24-bit backgrounds a program paints are brought into the palette's own register.
    ///
    /// On by default. It only ever *reduces* how far a background departs from the theme, and
    /// it holds lightness exactly, so the program's own text stays as legible as it drew it —
    /// see `TerminalBackgroundHarmony`. Off is for anyone who wants the raw bytes.
    var harmonizesTerminalBackgrounds: Bool {
        get { Self.harmonizesTerminalBackgrounds }
        set {
            defaults.set(newValue, forKey: Keys.harmonizesTerminalBackgrounds)
            notifyChanged()
        }
    }

    /// Read where a terminal is being configured, which is not always on the main actor.
    nonisolated static var harmonizesTerminalBackgrounds: Bool {
        _ = registerStandardDefaults
        return UserDefaults.standard.bool(forKey: Keys.harmonizesTerminalBackgrounds)
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

    /// Same access pattern as `groupsSessionsByBranch`, for the same reader.
    nonisolated static var groupsLoneBranches: Bool {
        _ = registerStandardDefaults
        return UserDefaults.standard.bool(forKey: Keys.groupsLoneBranches)
    }

    /// Whether a branch with a single session still earns a heading, once the project shows
    /// any branch heading at all.
    ///
    /// The base rule groups only where a branch has more than one session, which leaves a
    /// mixed tree: a heading over the shared branch, and beside it a bare row whose branch is
    /// invisible without the hover popover. With this on, the first real group pulls every
    /// session with a recorded branch under its own heading — the tree is either fully flat
    /// or fully labelled, never mixed. A project with no shared branch stays flat either way,
    /// so the common one-branch project never pays an extra level for a heading that would
    /// only repeat itself.
    var groupsLoneBranches: Bool {
        get { Self.groupsLoneBranches }
        set {
            defaults.set(newValue, forKey: Keys.groupsLoneBranches)
            notifyChanged()
        }
    }

    /// Same access pattern again; no seeding needed — an absent or unknown raw value reads
    /// as `.manual`, which is the documented default.
    nonisolated static var sidebarSessionOrder: SidebarSessionOrder {
        let raw = UserDefaults.standard.string(forKey: Keys.sidebarSessionOrder)
        return raw.flatMap(SidebarSessionOrder.init(rawValue:)) ?? .manual
    }

    /// How a project's sessions are arranged in the sidebar. Pinned sessions are hoisted
    /// first under every order; this decides the order among equals.
    var sidebarSessionOrder: SidebarSessionOrder {
        get { Self.sidebarSessionOrder }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.sidebarSessionOrder)
            notifyChanged()
        }
    }

    // MARK: - Fonts

    /// The family the whole chrome is set in, overriding whatever the theme states.
    /// `nil` follows the theme.
    ///
    /// `nonisolated` because `Design.Typography` is: the transform runs from nonisolated call
    /// sites (`PreferencesFormBuilder` builds its labels from one), and the font factory cannot
    /// hop actors to answer. Unlike the seeded booleans above there is no registration trap
    /// here — an absent key reads as `nil`, which *is* the documented default, so the seeding
    /// the `Bool` readers need would only restate it.
    nonisolated static var chromeFontFamily: String? {
        UserDefaults.standard.string(forKey: Keys.chromeFontFamily)
    }

    var chromeFontFamily: String? {
        get { Self.chromeFontFamily }
        set {
            setOrRemove(newValue, forKey: Keys.chromeFontFamily)
            notifyChanged()
        }
    }

    /// The family the **conversation** is set in, for a reader who wants the thread in something
    /// other than the app around it. `nil` falls back to `chromeFontFamily`, then to the theme.
    ///
    /// The terminal has had exactly this for as long as it has had a profile — its font is the
    /// user's, not the theme's. A natively rendered conversation is the same surface by a
    /// different transport, so it gets the same say. Three layers, no special cases: surface,
    /// then app, then theme.
    nonisolated static var conversationFontFamily: String? {
        UserDefaults.standard.string(forKey: Keys.conversationFontFamily)
    }

    var conversationFontFamily: String? {
        get { Self.conversationFontFamily }
        set {
            setOrRemove(newValue, forKey: Keys.conversationFontFamily)
            notifyChanged()
        }
    }

    /// The semantic scale applied to every font vended by `Design.Typography`.
    ///
    /// The terminal remains independent because its profile stores an explicit family and point
    /// size. Host-rendered extension UI does use the design system and therefore follows this
    /// setting automatically.
    nonisolated static var appTextSize: AppTextSize {
        _ = registerStandardDefaults
        let raw = UserDefaults.standard.string(forKey: Keys.appTextSize)
        return raw.flatMap(AppTextSize.init(rawValue:)) ?? .standard
    }

    var appTextSize: AppTextSize {
        get {
            let raw = defaults.string(forKey: Keys.appTextSize)
            return raw.flatMap(AppTextSize.init(rawValue:)) ?? .standard
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.appTextSize)
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

    // MARK: - Claude Remote Control

    /// What new Claude sessions do about **Claude's own** Remote Control bridge — the built-in
    /// feature that lets claude.ai and the Claude mobile app drive a session. Unrelated to
    /// Skalman's Remote Access below, which is this app's own server; the two can be set
    /// independently and a session may be reachable through either, both, or neither.
    ///
    /// Defaults to `.followClaude`, which writes nothing and leaves the decision to the user's
    /// `claude /config`. That is why the setting is three-state rather than a switch: writing
    /// `false` to mean "we have no opinion" would silently override a `/config` the user set
    /// deliberately, and installing a Skalman update must not change how their agent connects.
    ///
    /// A session that has chosen for itself (`AgentSession.remoteControl`) ignores this.
    var claudeRemoteControl: ClaudeRemoteControl {
        get {
            guard let raw = defaults.string(forKey: Keys.claudeRemoteControl),
                  let value = ClaudeRemoteControl(rawValue: raw) else { return .followClaude }
            return value
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.claudeRemoteControl)
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
            Keys.groupsLoneBranches: true,
            Keys.discoversProjectIcons: true,
            Keys.discoversAccountAvatars: true,
            Keys.harmonizesTerminalBackgrounds: true,
            Keys.workingOrbStyle: MotionPreferencesDefaults.workingOrbStyle.rawValue,
            Keys.chatNameMorphStyle: MotionPreferencesDefaults.chatNameMorphStyle.rawValue,
            Keys.appTextSize: AppTextSize.standard.rawValue
        ]
    }

    private func notifyChanged() {
        NotificationCenter.default.post(AppSettingsDidChange())
    }

    /// Stores a value, or removes the key when there is none.
    ///
    /// "No override" has to be the *absence* of the key rather than an empty string, because the
    /// readers are `string(forKey:)` and an empty family name would resolve no font — which is
    /// the fallback path, reached by a route that says something went wrong rather than that
    /// nothing was chosen.
    private func setOrRemove(_ value: String?, forKey key: String) {
        if let value, !value.isEmpty {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: - Keys

    private enum Keys {
        static let defaultAgentKind = "defaultAgentKind"
        static let restoresLastSession = "restoresLastSession"
        static let confirmsBeforeClosingRunningSession = "confirmsBeforeClosingRunningSession"
        static let usesTerminalTitleInSidebar = "usesTerminalTitleInSidebar"
        static let groupsSessionsByBranch = "groupsSessionsByBranch"
        static let groupsLoneBranches = "groupsLoneBranches"
        static let sidebarSessionOrder = "sidebarSessionOrder"
        static let discoversProjectIcons = "discoversProjectIcons"
        static let discoversAccountAvatars = "discoversAccountAvatars"
        static let harmonizesTerminalBackgrounds = "harmonizesTerminalBackgrounds"
        static let disabledAttachmentDetectionAgentKinds = "disabledAttachmentDetectionAgentKinds"
        static let disabledToolGroupIDs = "disabledToolGroupIDs"
        static let usesContainedExtensionLauncher = "usesContainedExtensionLauncher"
        static let installsCodexHooks = "installsCodexHooks"
        static let bypassesCodexHookTrust = "bypassesCodexHookTrust"
        static let claudeRemoteControl = "claudeRemoteControl"
        static let remoteAccessEnabled = "remoteAccessEnabled"
        static let workingOrbStyle = "workingOrbStyle"
        static let chatNameMorphStyle = "chatNameMorphStyle"
        static let chromeFontFamily = "chromeFontFamily"
        static let conversationFontFamily = "conversationFontFamily"
        static let appTextSize = "appTextSize"
    }
}

// MARK: - App Text Size

/// A deliberately small, named scale instead of a free point-size field.
///
/// Font roles keep their hierarchy at every step, layout can be exercised at a bounded largest
/// size, and the user can still move from compact to accessibility-sized chrome without
/// knowing what point size each role started at.
enum AppTextSize: String, CaseIterable {
    case compact
    case standard
    case large
    case extraLarge

    var scale: CGFloat {
        switch self {
        case .compact: 0.90
        case .standard: 1
        case .large: 1.15
        case .extraLarge: 1.30
        }
    }

    var title: String {
        switch self {
        case .compact: L10n.string("Compact")
        case .standard: L10n.string("Default")
        case .large: L10n.string("Large")
        case .extraLarge: L10n.string("Extra Large")
        }
    }
}

// MARK: - Claude Remote Control

/// What a Claude session does about Claude's own Remote Control bridge.
///
/// Three states rather than a switch, because "no opinion" and "off" are different
/// instructions to the CLI: the first writes no `remoteControlAtStartup` key at all and lets
/// the user's `claude /config` decide, while the second writes `false` and overrides it. Only
/// the first can be the default without changing behaviour for anyone who already chose.
///
/// Raw values are stored in defaults, so a case rename is a silent reset to `followClaude`.
enum ClaudeRemoteControl: String, CaseIterable {
    case followClaude
    case enabled
    case disabled

    /// The value written into the session's settings file, or nil to write nothing.
    var startupValue: Bool? {
        switch self {
        case .followClaude: nil
        case .enabled: true
        case .disabled: false
        }
    }

    /// The settings pop-up's wording. "Follow Claude's setting" names where the decision goes
    /// rather than what it is, because Skalman cannot read it: the value lives in the account's
    /// own config, and an unset one resolves server-side.
    var settingsTitle: String {
        switch self {
        case .followClaude: L10n.string("Follow Claude's setting")
        case .enabled: L10n.string("Always on")
        case .disabled: L10n.string("Always off")
        }
    }

    /// What a session's "inherit" menu item says, given this as the app-wide default. It names
    /// the inherited answer where there is one and defers where there is not, so the row never
    /// claims to know a value it cannot see.
    var inheritedMenuTitle: String {
        switch self {
        case .followClaude: L10n.string("Use Claude's Setting")
        case .enabled: L10n.string("Use Default (On)")
        case .disabled: L10n.string("Use Default (Off)")
        }
    }
}

// MARK: - Sidebar Session Order

/// How a project's sessions are arranged in the sidebar.
///
/// `manual` is the store's own order — the order sessions were created in, which is also the
/// only order the user can influence directly. The others are derived orders, re-applied on
/// every rebuild. Raw values are stored in defaults, so a case rename is a silent reset.
enum SidebarSessionOrder: String, CaseIterable {
    case manual
    case recentActivity
    case name

    /// The menu wording: what the order sorts by, since "manual" describes a mechanism and
    /// "order added" describes what the list actually shows.
    var menuTitle: String {
        switch self {
        case .manual: L10n.string("Sort by Order Added")
        case .recentActivity: L10n.string("Sort by Recent Activity")
        case .name: L10n.string("Sort by Name")
        }
    }
}

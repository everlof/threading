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
        migrateClosingConfirmation()
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

    /// The client ID of the user's registered GitHub App, used by the device-flow sign-in.
    ///
    /// Configuration rather than a secret — a client ID identifies the app, it grants
    /// nothing — so it lives beside the other behavioural settings, not in the Keychain.
    var githubAppClientID: String {
        get { defaults.string(forKey: Keys.githubAppClientID) ?? "" }
        set {
            defaults.set(newValue, forKey: Keys.githubAppClientID)
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

    /// Whether the sessions that were running at the last quit are relaunched at startup.
    ///
    /// The relaunch happens in the background, one session at a time: rows come back live
    /// without being selected, so opening one later attaches an agent that is already up
    /// instead of paying the resume on the click. See `StartupSessionRelaunch`.
    var restoresRunningSessions: Bool {
        get { defaults.bool(forKey: Keys.restoresRunningSessions) }
        set {
            defaults.set(newValue, forKey: Keys.restoresRunningSessions)
            notifyChanged()
        }
    }

    /// Extra context appended to the first message of every new chat.
    ///
    /// Empty means no extra message. It is deliberately app-wide rather than copied into the
    /// session record: the value is consumed once when the chat is created, and the combined
    /// opening is what the provider persists in its own transcript. Resuming an existing chat
    /// never reads it.
    var newChatOpeningMessage: String {
        get { defaults.string(forKey: Keys.newChatOpeningMessage) ?? "" }
        set {
            setOrRemove(newValue, forKey: Keys.newChatOpeningMessage)
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

    /// Whether a session that wants the user posts a macOS notification — blocked on an
    /// approval, finished off screen, or finished while the app was in the background.
    ///
    /// On by default; the system's own notification permission still gates delivery, and it
    /// is requested on the first alert rather than at launch. Banners appear only while the
    /// app is inactive — in the app, the sidebar mark and the permission card are the cues.
    var notifiesOnAttention: Bool {
        get { Self.notifiesOnAttention }
        set {
            defaults.set(newValue, forKey: Keys.notifiesOnAttention)
            notifyChanged()
        }
    }

    /// Read by the alert center off the settings-change event, same pattern as its neighbours.
    nonisolated static var notifiesOnAttention: Bool {
        _ = registerStandardDefaults
        return UserDefaults.standard.bool(forKey: Keys.notifiesOnAttention)
    }

    /// The alert kinds switched *off*, stored that way for the same reason attachment
    /// detection is: every kind — including one added later — starts on, with no defaults
    /// migration and no seed per case.
    private var disabledAttentionAlerts: Set<AttentionAlert> {
        get {
            Set(
                (defaults.stringArray(forKey: Keys.disabledAttentionAlerts) ?? [])
                    .compactMap(AttentionAlert.init(rawValue:))
            )
        }
        set {
            defaults.set(newValue.map(\.rawValue).sorted(), forKey: Keys.disabledAttentionAlerts)
            notifyChanged()
        }
    }

    /// Whether this kind of alert is posted at all. Under `notifiesOnAttention`, which stays
    /// the master switch — these choose *which* of the three arrive when notifications are on.
    func notifies(on alert: AttentionAlert) -> Bool {
        !disabledAttentionAlerts.contains(alert)
    }

    func setNotifies(_ enabled: Bool, on alert: AttentionAlert) {
        var disabled = disabledAttentionAlerts
        if enabled {
            disabled.remove(alert)
        } else {
            disabled.insert(alert)
        }
        disabledAttentionAlerts = disabled
    }

    // MARK: - Confirmations

    /// The confirmations switched *off*, stored that way for the same reason the attention
    /// alerts are: a prompt added in a later release starts on, with no defaults migration and
    /// no seed per case. An absent raw value asks.
    private var suppressedConfirmations: Set<ConfirmationPrompt> {
        get {
            Set(
                (defaults.stringArray(forKey: Keys.suppressedConfirmations) ?? [])
                    .compactMap(ConfirmationPrompt.init(rawValue:))
            )
        }
        set {
            defaults.set(newValue.map(\.rawValue).sorted(), forKey: Keys.suppressedConfirmations)
            notifyChanged()
        }
    }

    /// Whether this confirmation is still asked for.
    ///
    /// The policy is consulted first and the stored set only under it. The set is raw strings
    /// on disk, so a prompt that was suppressible in one release and became `.alwaysAsks` in
    /// the next would otherwise stay silent for precisely the users who had switched it off —
    /// the population least able to notice that a destructive action stopped asking. The
    /// defaults are an opt-out under the register, never a way around it.
    func asks(before prompt: ConfirmationPrompt) -> Bool {
        guard prompt.suppression != nil else { return true }
        return !suppressedConfirmations.contains(prompt)
    }

    /// Written from the alert's own "Don't ask again" box and from the Settings row that turns
    /// it back on. They are the same state deliberately: a checkbox with a private store beside
    /// a switch with another is how one of them goes stale.
    func setAsks(_ asks: Bool, before prompt: ConfirmationPrompt) {
        guard prompt.suppression != nil else {
            assertionFailure("\(prompt.rawValue) always asks; there is no switch to write")
            return
        }
        var suppressed = suppressedConfirmations
        if asks {
            suppressed.remove(prompt)
        } else {
            suppressed.insert(prompt)
        }
        suppressedConfirmations = suppressed
    }

    // MARK: - Notices

    /// The notices hidden by their alert's "Don't show this message again" box, stored as the
    /// negation for the same reason the confirmations are: any notice — including one minted
    /// by an extension installed later — starts visible, with no defaults migration and no
    /// seed per key. Raw strings rather than an enum's raw values, because notice keys are
    /// dynamic (`AppNotice`).
    private var hiddenNotices: Set<String> {
        get { Set(defaults.stringArray(forKey: Keys.hiddenNotices) ?? []) }
        set {
            defaults.set(newValue.sorted(), forKey: Keys.hiddenNotices)
            notifyChanged()
        }
    }

    /// Whether this notice is still shown.
    func shows(_ notice: AppNotice) -> Bool {
        !hiddenNotices.contains(notice.storageKey)
    }

    /// Written from the alert's own box and from the Settings control that brings everything
    /// back. Same state deliberately — a checkbox with a private store beside a switch with
    /// another is how one of them goes stale.
    func setShows(_ shows: Bool, for notice: AppNotice) {
        var hidden = hiddenNotices
        if shows {
            hidden.remove(notice.storageKey)
        } else {
            hidden.insert(notice.storageKey)
        }
        hiddenNotices = hidden
    }

    /// What the Settings row can honestly display for dynamic keys: how many, not which — a
    /// stored key whose extension is gone has no title left to print.
    var hiddenNoticeCount: Int {
        hiddenNotices.count
    }

    /// The one un-hide control. All-or-nothing rather than per-key, because a per-key list
    /// would have to name keys whose extensions may no longer exist.
    func showAllNoticesAgain() {
        guard !hiddenNotices.isEmpty else { return }
        hiddenNotices = []
    }

    /// Whether the one alert that sounds is heard.
    ///
    /// Separate from the alert itself: someone who wants to see that a turn is blocked without
    /// being pinged has no way to say so if the sound rides along with the banner. On by
    /// default, since the blocked alert is the one holding work up.
    var playsAttentionAlertSound: Bool {
        get { defaults.bool(forKey: Keys.playsAttentionAlertSound) }
        set {
            defaults.set(newValue, forKey: Keys.playsAttentionAlertSound)
            notifyChanged()
        }
    }

    /// Whether an image dropped on an agent's terminal is rewritten when the agent cannot read
    /// the format it arrived in — a HEIC out of Finder, a scanned TIFF.
    ///
    /// On by default, because the alternative is a drop that looks like it worked and left a
    /// path in the prompt. Off is for working *on* the file rather than looking at it: someone
    /// debugging HEIC handling needs the agent to be given their HEIC, not a PNG of it. The
    /// shell drawer never converts either way — see `TerminalDropImage`.
    var convertsDroppedImages: Bool {
        get { Self.convertsDroppedImages }
        set {
            defaults.set(newValue, forKey: Keys.convertsDroppedImages)
            notifyChanged()
        }
    }

    /// Read inside the drop itself, which is a view's main-thread work rather than the actor's.
    nonisolated static var convertsDroppedImages: Bool {
        _ = registerStandardDefaults
        return UserDefaults.standard.bool(forKey: Keys.convertsDroppedImages)
    }

    /// Whether selecting text in a terminal with the mouse also puts it on the clipboard.
    ///
    /// Off unless asked for, and unlike most of the defaults here that is not caution about
    /// surprise: macOS has one pasteboard where X11 has two, so there is no separate primary
    /// selection for this to land in and every stray drag overwrites whatever the user last
    /// pressed ⌘C on. Someone who wants it wants it badly — it is how selection works in every
    /// Linux terminal — and someone who does not would lose a copied URL to a mis-click.
    var copiesTerminalSelection: Bool {
        get { Self.copiesTerminalSelection }
        set {
            defaults.set(newValue, forKey: Keys.copiesTerminalSelection)
            notifyChanged()
        }
    }

    /// Read at the end of the selection gesture, which is a view's main-thread work.
    nonisolated static var copiesTerminalSelection: Bool {
        _ = registerStandardDefaults
        return UserDefaults.standard.bool(forKey: Keys.copiesTerminalSelection)
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

    /// Whether the sidebar's tree drops horizontal indentation and starts every row at one
    /// shared edge, saying where a group begins with vertical spacing and a rule instead.
    ///
    /// Opt-in, so it defaults to `false` and needs no seed. Read only where the outline draws,
    /// which is main-actor code throughout — `SidebarTreeBuilder` never consults it, because
    /// the compact tree is the same tree presented differently.
    var compactsSidebarTree: Bool {
        get { defaults.bool(forKey: Keys.compactsSidebarTree) }
        set {
            defaults.set(newValue, forKey: Keys.compactsSidebarTree)
            notifyChanged()
        }
    }

    /// Whether a session's recorded branch follows its checkout while the session is not
    /// running.
    ///
    /// On, switching the checkout's branch — from another session, the shell drawer, or a
    /// terminal outside Threading entirely — updates every session standing in it, because a
    /// dormant session resumes onto whatever the checkout is on *now*
    /// (`CheckoutBranchFollower`). Off restores the frozen record: a session keeps the
    /// branch it last ran on until it next stops working, preserving what the conversation
    /// actually happened on.
    var followsCheckoutBranch: Bool {
        get { defaults.bool(forKey: Keys.followsCheckoutBranch) }
        set {
            defaults.set(newValue, forKey: Keys.followsCheckoutBranch)
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

    // MARK: - Composer

    /// Read at the keystroke rather than at setup: the Settings window sits *beside* the
    /// composer being configured, and a value cached when the pane was built would keep
    /// answering with whatever was true then. `UserDefaults` reads are cheap enough to do per
    /// Return, and no observation has to be wired into a design-system component.
    ///
    /// An absent or unknown raw value reads as `.matchesComposer`, which is the documented
    /// default, so nothing needs seeding.
    nonisolated static var promptReturnKey: PromptReturnKey {
        let raw = UserDefaults.standard.string(forKey: Keys.promptReturnKey)
        return raw.flatMap(PromptReturnKey.init(rawValue:)) ?? .matchesComposer
    }

    /// What Return does in a prompt composer.
    var promptReturnKey: PromptReturnKey {
        get { Self.promptReturnKey }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.promptReturnKey)
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

    /// Whether a *scanned* path may be listed when the file lives outside the project.
    ///
    /// Off by default, and the default is the safety measure rather than a preference: the
    /// attachment list is the allowlist the paired phone fetches against, so one `find ~ -name
    /// '*.png'` printed in a terminal would otherwise enumerate the user's pictures into it.
    /// Stored as the opt-*in* so the narrow answer survives a defaults reset, an unreadable
    /// value, and a machine the user has never opened this page on. Declared handoffs are not
    /// governed by it — see `SessionAttachmentStore`.
    var includesAttachmentsOutsideProject: Bool {
        get { defaults.bool(forKey: Keys.includesAttachmentsOutsideProject) }
        set {
            defaults.set(newValue, forKey: Keys.includesAttachmentsOutsideProject)
            notifyChanged()
        }
    }

    /// Whether a before-shot of the page is kept in front of each agent mutation, so a comparison
    /// can answer "what did that click change?".
    ///
    /// Off by default, and the default is a cost decision rather than a safety one: every
    /// mutating browser tool would otherwise pay for a screenshot on the main actor, in the hot
    /// path, for an answer nobody may ask for. Stored as the opt-*in* so an unreadable value and a
    /// machine the user has never opened this page on both mean off. The captures are runtime-only
    /// and separately bounded — see `BrowserAutoCaptureRing`, which is deliberately not the
    /// approved baseline library.
    var capturesPageBeforeAgentActions: Bool {
        get { defaults.bool(forKey: Keys.capturesPageBeforeAgentActions) }
        set {
            defaults.set(newValue, forKey: Keys.capturesPageBeforeAgentActions)
            notifyChanged()
        }
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

    /// Which complete leading navigator the user chose. An absent or unreadable value is Native.
    var workspaceNavigatorSelection: WorkspaceNavigatorSelection {
        get {
            guard let data = defaults.data(forKey: Keys.workspaceNavigatorSelection),
                  let selection = try? JSONDecoder().decode(
                      WorkspaceNavigatorSelection.self,
                      from: data
                  ) else {
                return .native
            }
            return selection
        }
        set {
            if newValue == .native {
                defaults.removeObject(forKey: Keys.workspaceNavigatorSelection)
            } else if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Keys.workspaceNavigatorSelection)
            }
            notifyChanged()
        }
    }

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

    /// Whether Claude sessions report turn boundaries and subagent lifecycle back to Threading.
    ///
    /// On by default because Claude receives these hooks in a per-session `--settings` file;
    /// Threading never edits the user's Claude configuration. The switch still exists because a
    /// hook can conflict with a CLI release or a user's setup. Turning it off removes every
    /// observational hook on the next launch while leaving Native's required permission hook
    /// independent.
    var reportsClaudeLifecycleEvents: Bool {
        get { defaults.bool(forKey: Keys.reportsClaudeLifecycleEvents) }
        set {
            defaults.set(newValue, forKey: Keys.reportsClaudeLifecycleEvents)
            notifyChanged()
        }
    }

    /// Whether Threading installs its lifecycle hooks into each Codex account's `hooks.json`.
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

    /// Whether Claude terminal sessions launched by Threading silence the account's own
    /// status line.
    ///
    /// The line duplicates what Threading's own chrome already shows — the status card carries
    /// model, effort and branch; the toolbar pill carries usage — and a user's script can
    /// drift from the truth (the one this was built against printed a hard-coded effort).
    /// Suppression rides the per-session `--settings` file, which was verified to outrank the
    /// account's configuration for this key, so the user's own terminals keep their line
    /// untouched. The account's command still *runs* with its output discarded, because these
    /// commands are commonly bridges whose side effects matter — Claudex's cache is a usage
    /// source — and "hide the line" must not quietly mean "starve the pill". Off by default:
    /// the line is the user's own configuration, and hiding it is a choice.
    var suppressesClaudeStatusLine: Bool {
        get { defaults.bool(forKey: Keys.suppressesClaudeStatusLine) }
        set {
            defaults.set(newValue, forKey: Keys.suppressesClaudeStatusLine)
            notifyChanged()
        }
    }

    /// Whether Threading may read the Claude CLI's saved login from the macOS keychain to
    /// fetch live usage.
    ///
    /// Off by default: the token is a credential Threading does not own, and reading someone
    /// else's credential is opt-in however good the reason. Turning it on triggers the
    /// keychain grant flow right there in the Privacy page, so the macOS prompt is a direct
    /// consequence of an action the user just took — background refreshes never prompt,
    /// whatever this is set to (`ClaudeKeychainCredentials` fails closed instead). With it
    /// off, usage falls back to the local caches the CLI leaves behind, which can be hours
    /// old or absent.
    var readsClaudeLoginFromKeychain: Bool {
        get { defaults.bool(forKey: Keys.readsClaudeLoginFromKeychain) }
        set {
            defaults.set(newValue, forKey: Keys.readsClaudeLoginFromKeychain)
            notifyChanged()
        }
    }

    /// Whether Codex sessions launch with `--dangerously-bypass-hook-trust`.
    ///
    /// Codex refuses to run a hook until its exact text has been reviewed, and review happens
    /// in the interactive TUI — which a session Threading launches never shows. The flag skips
    /// that gate.
    ///
    /// Off by default, and the wording on the settings page says why rather than leaving it to
    /// the name: the flag un-gates **every** hook in that config directory, not only Threading's.
    /// Since an agent can write to `hooks.json`, turning this on means an agent could arrange
    /// for its own code to run unreviewed on the next launch. Trusting once in the TUI costs a
    /// single step and keeps the gate.
    ///
    /// Threading's own entries are built to survive that one review: the port and session token
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
    /// Threading's Remote Access below, which is this app's own server; the two can be set
    /// independently and a session may be reachable through either, both, or neither.
    ///
    /// Defaults to `.followClaude`, which writes nothing and leaves the decision to the user's
    /// `claude /config`. That is why the setting is three-state rather than a switch: writing
    /// `false` to mean "we have no opinion" would silently override a `/config` the user set
    /// deliberately, and installing a Threading update must not change how their agent connects.
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

    // MARK: - Permission Mode

    /// How much a **new** session may do before it has to ask.
    ///
    /// Nil — the default — writes no flag at all and leaves the decision where it already is:
    /// Claude's `permissions.defaultMode`, Codex's `config.toml`. That is the same reasoning as
    /// `claudeRemoteControl` above, and the same reason it cannot collapse to a plain value:
    /// picking any mode as the shipped default would silently override a config the user set
    /// deliberately, on an axis where the wrong answer either nags them or stops asking.
    ///
    /// A session that has chosen for itself (`AgentSession.permissionMode`) ignores this.
    /// An unrecognised stored value reads as nil, so a mode a future CLI drops degrades to
    /// "leave it alone" rather than to someone else's idea of a safe default.
    var defaultPermissionMode: AgentPermissionMode? {
        get {
            guard let raw = defaults.string(forKey: Keys.defaultPermissionMode) else { return nil }
            return AgentPermissionMode(rawValue: raw)
        }
        set {
            if let newValue {
                defaults.set(newValue.rawValue, forKey: Keys.defaultPermissionMode)
            } else {
                defaults.removeObject(forKey: Keys.defaultPermissionMode)
            }
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

    /// Which network doors publish the dedicated remote-access listener. An absent or unknown
    /// value stays on the relay for compatibility with installations that predate private
    /// tailnet access; an unknown future value must not silently enable an additional endpoint.
    var remoteAccessConnectionMode: RemoteAccessConnectionMode {
        get {
            guard let raw = defaults.string(forKey: Keys.remoteAccessConnectionMode) else {
                return .relay
            }
            return RemoteAccessConnectionMode(rawValue: raw) ?? .relay
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.remoteAccessConnectionMode)
            notifyChanged()
        }
    }

    /// Whether an owner's paired device may use the public relay when private Tailscale access
    /// is unavailable in Private + Sharing mode. Off is deliberately fail-closed: enabling a
    /// public sharing door must not silently make private owner traffic use it too.
    var remoteAccessAllowsOwnerRelayFallback: Bool {
        get { defaults.bool(forKey: Keys.remoteAccessAllowsOwnerRelayFallback) }
        set {
            defaults.set(newValue, forKey: Keys.remoteAccessAllowsOwnerRelayFallback)
            notifyChanged()
        }
    }

    /// Keeps the public relay warm in Private + Sharing mode even when no share exists. Off is
    /// the privacy-preserving default; the coordinator otherwise starts it on the first public
    /// share and stops it after the final share is revoked or expires.
    var remoteAccessKeepsRelayReady: Bool {
        get { defaults.bool(forKey: Keys.remoteAccessKeepsRelayReady) }
        set {
            defaults.set(newValue, forKey: Keys.remoteAccessKeepsRelayReady)
            notifyChanged()
        }
    }

    /// How a newly shared session starts. The choice is only a default: the owner can switch
    /// the live session between collaborative and focused control at any time.
    var remoteInputControlDefault: RemoteInputControlDefault {
        get {
            guard let raw = defaults.string(forKey: Keys.remoteInputControlDefault),
                  let value = RemoteInputControlDefault(rawValue: raw) else {
                return .collaborative
            }
            return value
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.remoteInputControlDefault)
            notifyChanged()
        }
    }

    /// Whether Threading may ask its release feed whether a newer version exists.
    ///
    /// Defaults to **on**, and `defaults.bool` cannot express that — an unset key reads `false`,
    /// which would ship the feature switched off for everyone who never opened Settings. The
    /// registered default is `true` and this reads through it, so "never touched" and
    /// "deliberately off" stay distinguishable in the stored domain.
    var automaticUpdateChecksEnabled: Bool {
        get { defaults.bool(forKey: Keys.automaticUpdateChecksEnabled) }
        set {
            defaults.set(newValue, forKey: Keys.automaticUpdateChecksEnabled)
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

    /// `confirmsBeforeClosingRunningSession` was one switch over four prompts: close, archive,
    /// move to another account, and the surface switch. Those are four entries in the
    /// suppressed set now, so the switch hands its value over rather than being dropped — a
    /// stored `false` is a choice somebody made, and losing it starts interrupting the one user
    /// who had asked not to be.
    ///
    /// Two details are load-bearing. The old key **keeps its seed** (`true`) even though
    /// nothing reads it any more: `bool(forKey:)` answers `false` for an unregistered key, so
    /// dropping the seed would read as "switched off" for every user alive and silence all four
    /// prompts on first launch. And the marker is written **last** and never seeded, so an
    /// interrupted migration re-runs — which is safe because the carry is a union, and because
    /// a user who later switches a prompt back on is not undone by the next launch.
    ///
    /// Writes `defaults` directly rather than through `suppressedConfirmations`: that setter
    /// posts `AppSettingsDidChange`, and this runs while the singleton is still being built.
    private func migrateClosingConfirmation() {
        guard defaults.object(forKey: Keys.didMigrateClosingConfirmation) == nil else { return }

        // Seeded `true`, so a `false` here can only have been written by the old settings row.
        if !defaults.bool(forKey: Keys.confirmsBeforeClosingRunningSession) {
            let carried = suppressedConfirmations
                .union(ConfirmationPrompt.closingConfirmationSuccessors)
            defaults.set(carried.map(\.rawValue).sorted(), forKey: Keys.suppressedConfirmations)
        }
        defaults.removeObject(forKey: Keys.confirmsBeforeClosingRunningSession)
        defaults.set(true, forKey: Keys.didMigrateClosingConfirmation)
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
    private nonisolated static let registerStandardDefaults: Void = {
        UserDefaults.standard.register(defaults: seeds)
    }()

    private nonisolated static var seeds: [String: Any] {
        [
            Keys.defaultAgentKind: AgentDefaults.defaultKind.rawValue,
            Keys.restoresLastSession: true,
            Keys.restoresRunningSessions: true,
            Keys.confirmsBeforeClosingRunningSession: true,
            Keys.usesTerminalTitleInSidebar: true,
            Keys.groupsSessionsByBranch: true,
            Keys.groupsLoneBranches: true,
            Keys.followsCheckoutBranch: true,
            Keys.discoversProjectIcons: true,
            Keys.discoversAccountAvatars: true,
            Keys.harmonizesTerminalBackgrounds: true,
            Keys.convertsDroppedImages: true,
            Keys.notifiesOnAttention: true,
            Keys.automaticUpdateChecksEnabled: true,
            Keys.playsAttentionAlertSound: true,
            Keys.reportsClaudeLifecycleEvents: true,
            Keys.remoteAccessAllowsOwnerRelayFallback: false,
            Keys.remoteAccessKeepsRelayReady: false,
            Keys.remoteInputControlDefault: RemoteInputControlDefault.collaborative.rawValue,
            Keys.workingOrbStyle: MotionPreferencesDefaults.workingOrbStyle.rawValue,
            Keys.chatNameMorphStyle: MotionPreferencesDefaults.chatNameMorphStyle.rawValue,
            Keys.appTextSize: AppTextSize.standard.rawValue
        ]
    }

    private func notifyChanged() {
        NotificationCenter.default.post(AppSettingsDidChange())
    }

    /// Stores a string-backed choice, or removes the key when its empty value means "none".
    ///
    /// Absence is the honest stored form for both optional font overrides and the optional
    /// reusable opening message. It keeps `string(forKey:)` from returning a present-but-empty
    /// value whose only meaning would have to be reinterpreted at every read.
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
        static let restoresRunningSessions = "restoresRunningSessions"
        static let newChatOpeningMessage = "newChatOpeningMessage"
        /// Read only by `migrateClosingConfirmation`; the setting itself is four prompts now.
        static let confirmsBeforeClosingRunningSession = "confirmsBeforeClosingRunningSession"
        static let suppressedConfirmations = "suppressedConfirmations"
        static let hiddenNotices = "hiddenNotices"
        static let didMigrateClosingConfirmation = "didMigrateClosingConfirmation"
        static let usesTerminalTitleInSidebar = "usesTerminalTitleInSidebar"
        static let groupsSessionsByBranch = "groupsSessionsByBranch"
        static let groupsLoneBranches = "groupsLoneBranches"
        static let compactsSidebarTree = "compactsSidebarTree"
        static let followsCheckoutBranch = "followsCheckoutBranch"
        static let sidebarSessionOrder = "sidebarSessionOrder"
        static let promptReturnKey = "promptReturnKey"
        static let discoversProjectIcons = "discoversProjectIcons"
        static let discoversAccountAvatars = "discoversAccountAvatars"
        static let harmonizesTerminalBackgrounds = "harmonizesTerminalBackgrounds"
        static let convertsDroppedImages = "convertsDroppedImages"
        /// Unseeded on purpose: `bool(forKey:)` answering `false` for an absent key is exactly
        /// the documented default, and copy-on-select is opt-in.
        static let copiesTerminalSelection = "copiesTerminalSelection"
        static let notifiesOnAttention = "notifiesOnAttention"
        static let disabledAttentionAlerts = "disabledAttentionAlerts"
        static let playsAttentionAlertSound = "playsAttentionAlertSound"
        static let disabledAttachmentDetectionAgentKinds = "disabledAttachmentDetectionAgentKinds"
        static let includesAttachmentsOutsideProject = "includesAttachmentsOutsideProject"
        static let capturesPageBeforeAgentActions = "capturesPageBeforeAgentActions"
        static let disabledToolGroupIDs = "disabledToolGroupIDs"
        static let usesContainedExtensionLauncher = "usesContainedExtensionLauncher"
        static let workspaceNavigatorSelection = "workspaceNavigatorSelection"
        static let reportsClaudeLifecycleEvents = "reportsClaudeLifecycleEvents"
        static let installsCodexHooks = "installsCodexHooks"
        static let readsClaudeLoginFromKeychain = "readsClaudeLoginFromKeychain"
        static let suppressesClaudeStatusLine = "suppressesClaudeStatusLine"
        static let bypassesCodexHookTrust = "bypassesCodexHookTrust"
        static let claudeRemoteControl = "claudeRemoteControl"
        static let defaultPermissionMode = "defaultPermissionMode"
        static let remoteAccessEnabled = "remoteAccessEnabled"
        static let remoteAccessConnectionMode = "remoteAccessConnectionMode"
        static let remoteAccessAllowsOwnerRelayFallback =
            "remoteAccessAllowsOwnerRelayFallback"
        static let remoteAccessKeepsRelayReady = "remoteAccessKeepsRelayReady"
        static let remoteInputControlDefault = "remoteInputControlDefault"
        static let automaticUpdateChecksEnabled = "automaticUpdateChecksEnabled"
        static let githubAppClientID = "githubAppClientID"
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
    /// rather than what it is, because Threading cannot read it: the value lives in the account's
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

// MARK: - Prompt Return Key

/// What the Return key does in a prompt composer.
///
/// The most personal keystroke in the app, and the one every chat product has ended up making
/// configurable — Slack, Zulip, Teams, Discord and (as of early 2026) Cursor all ship the same
/// two-option preference, because the two camps are drawn by *what people write*, not by taste:
/// a one-line reply wants Return to send it, and a paragraph of context wants Return to be a
/// line break.
///
/// This app has both surfaces at once, which is why there is a third case rather than a
/// two-value toggle. The default keeps each composer's own answer — a brief that launches a
/// process treats Return as a line break, a reply into a live thread sends — and the option
/// exists so a user who wants **one** answer everywhere can say so. Naming the split in the
/// settings is itself the point: what people report hating is not either behaviour but
/// discovering, mid-sentence, that this box disagreed with the last one.
///
/// Two rules hold under every case, so there is always a key that cannot surprise anyone:
/// ⌘Return sends, and Shift- or Option-Return breaks the line. Zulip's is the version worth
/// copying — Shift-Return is a newline whatever the setting says.
///
/// Raw values are stored in defaults, so a case rename is a silent reset to `matchesComposer`.
enum PromptReturnKey: String, CaseIterable {

    /// Each composer keeps the meaning that suits what it holds. The default.
    case matchesComposer

    /// Return sends everywhere, including the session brief.
    case sends

    /// Return is a line break everywhere; ⌘Return is the only send from the keyboard.
    case startsNewLine

    /// The settings wording, phrased to complete "When writing a prompt, press Return to…" —
    /// Slack's framing, which reads as a sentence rather than as a flag.
    var settingsTitle: String {
        switch self {
        case .matchesComposer: L10n.string("Do What the Composer Expects")
        case .sends: L10n.string("Send")
        case .startsNewLine: L10n.string("Start a New Line")
        }
    }

    /// What the choice costs, said where it is made. The alternate chord is the whole content
    /// of the answer: a setting that changes a key without naming its replacement is how people
    /// end up unable to type a second line at all.
    var settingsDetail: String {
        switch self {
        case .matchesComposer:
            L10n.string("A box with a send control in it sends; a note attached to a report takes a line break.")
        case .sends:
            L10n.string("Shift-Return starts a new line.")
        case .startsNewLine:
            L10n.string("Command-Return sends.")
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

import Foundation

/// Application-wide preferences backed by `UserDefaults`.
///
/// Terminal appearance lives in `TerminalProfile` and per-account customisation in
/// `AccountPreferencesStore`; this covers the behavioural settings shown on the General tab.
@MainActor
final class AppSettings {

    // MARK: - Singleton

    static let shared = AppSettings(
        legacyPreferences: legacyPreferencesForSharedProcess
    )

    /// A hosted XCTest bundle runs inside the shipping app and sees the developer's real
    /// defaults domains. Reading is necessary for behavioural-setting tests, but a one-time
    /// migration is a write on the developer's behalf, so only the real app process imports.
    private static var legacyPreferencesForSharedProcess: [String: Any] {
        guard importsLegacyPreferencesForSharedProcess else { return [:] }
        return UserDefaults.standard.persistentDomain(
            forName: LegacyAppPreferenceDefaults.domainName
        ) ?? [:]
    }

    static var importsLegacyPreferencesForSharedProcess: Bool {
        NSClassFromString("XCTestCase") == nil
    }

    private let defaults: UserDefaults
    /// A distributed channel currently withholds Remote Access. Keep that policy beside the
    /// persisted master switch as well as in Settings: a developer may install a release over a
    /// dev build whose switch was already on, and hiding the page cannot make that stored `true`
    /// safe. Injected so the shipping case is testable from a hosted dev test bundle.
    private let remoteAccessIsOffered: Bool
    private let workspaceNavigatorPersistence:
        RecoverableDefaultsStore<WorkspaceNavigatorSelection>
    private var cachedWorkspaceNavigatorSelection: WorkspaceNavigatorSelection

    init(
        defaults: UserDefaults = .standard,
        legacyPreferences: [String: Any] = [:],
        remoteAccessIsOffered: Bool = AppInfo.buildChannel.offersRemoteAccess
    ) {
        let workspaceNavigatorPersistence =
            RecoverableDefaultsStore<WorkspaceNavigatorSelection>(
                defaults: defaults,
                key: AppSettingDefinitions.workspaceNavigatorSelection.persistenceKey,
                criticality: .preference,
                sizePolicy: .compactMetadata
            )
        self.defaults = defaults
        self.remoteAccessIsOffered = remoteAccessIsOffered
        self.workspaceNavigatorPersistence = workspaceNavigatorPersistence
        self.cachedWorkspaceNavigatorSelection = workspaceNavigatorPersistence.load(
            defaultValue: .native,
            validate: Self.validateWorkspaceNavigatorSelection
        ).value
        registerDefaults()
        migrateLegacyCodexHookPreferences(from: legacyPreferences)
        migrateClosingConfirmation()
        migrateAttentionAlertSoundSwitch()
        migrateRemoteAccessConnectionMode()
        disableRemoteAccessWhenUnavailable()
    }

    // MARK: - Settings

    /// Agent used when creating a session without naming one explicitly.
    var defaultAgentKind: AgentKind {
        get {
            guard let raw = AppSettingDefinitions.defaultAgentKind.read(from: defaults),
                  let kind = AgentKind(rawValue: raw) else { return AgentDefaults.defaultKind }
            return kind
        }
        set {
            AppSettingDefinitions.defaultAgentKind.write(newValue.rawValue, to: defaults)
        }
    }

    /// The client ID of the user's registered GitHub App, used by the device-flow sign-in.
    ///
    /// Configuration rather than a secret — a client ID identifies the app, it grants
    /// nothing — so it lives beside the other behavioural settings, not in the Keychain.
    var githubAppClientID: String {
        get { AppSettingDefinitions.githubAppClientID.read(from: defaults) ?? "" }
        set {
            AppSettingDefinitions.githubAppClientID.write(newValue, to: defaults)
        }
    }

    /// Whether the previously selected session is reopened at launch.
    var restoresLastSession: Bool {
        get { AppSettingDefinitions.restoresLastSession.read(from: defaults) ?? true }
        set {
            AppSettingDefinitions.restoresLastSession.write(newValue, to: defaults)
        }
    }

    /// Whether the sessions that were running at the last quit are relaunched at startup.
    ///
    /// **Superseded by `sessionRestorePolicy`, and kept as the value it migrates from.** A choice
    /// somebody already made must survive the setting growing a third answer, and the policy has
    /// no registered default precisely so that an absent policy key can read this one instead.
    /// Nothing should write it any more.
    var restoresRunningSessions: Bool {
        get { AppSettingDefinitions.restoresRunningSessions.read(from: defaults) ?? true }
        set {
            AppSettingDefinitions.restoresRunningSessions.write(newValue, to: defaults)
        }
    }

    /// Which sessions a launch brings back live.
    ///
    /// The relaunch happens in the background, one session at a time: rows come back live
    /// without being selected, so opening one later attaches an agent that is already up
    /// instead of paying the resume on the click. See `StartupSessionRelaunch`.
    ///
    /// Unset reads the toggle this replaced, so an existing choice carries over untouched and
    /// nothing is written on a mere read.
    var sessionRestorePolicy: SessionRestorePolicy {
        get {
            SessionRestorePolicy.resolved(
                stored: AppSettingDefinitions.sessionRestorePolicy.read(from: defaults),
                legacyRestoresRunningSessions: restoresRunningSessions
            )
        }
        set {
            AppSettingDefinitions.sessionRestorePolicy.write(newValue.rawValue, to: defaults)
        }
    }

    /// How far back `.recentlyUsed` looks, in days.
    ///
    /// Clamped on the way in and on the way out: this is read on the launch path, where a value
    /// somebody typed into `defaults write` must not decide how many agents boot.
    var sessionRestoreWindowDays: Int {
        get { AppSettingDefinitions.sessionRestoreWindowDays.read(from: defaults)
            ?? SessionRestoreDefaults.windowDays }
        set {
            AppSettingDefinitions.sessionRestoreWindowDays.write(newValue, to: defaults)
        }
    }

    /// The most sessions `.recentlyUsed` may bring back.
    ///
    /// A window is unbounded by construction — a heavy week is a heavy launch — so the cap is
    /// what turns the policy into a promise the launch can keep. See
    /// `docs/architecture/performance.md`'s scaling gate.
    var sessionRestoreLimit: Int {
        get { AppSettingDefinitions.sessionRestoreLimit.read(from: defaults)
            ?? SessionRestoreDefaults.limit }
        set {
            AppSettingDefinitions.sessionRestoreLimit.write(newValue, to: defaults)
        }
    }

    /// Whether launch brings anything back at all, which is what the window-restoration
    /// observers ask before arming themselves.
    var restoresSessionsAtLaunch: Bool {
        sessionRestorePolicy != .nothing
    }

    /// Standing context put *before* the task in the first message of every new chat.
    ///
    /// Empty means nothing is added. Same lifetime as the suffix below: consumed once when the
    /// chat is created, never re-read on a resume.
    var newChatOpeningPrefix: String {
        get { AppSettingDefinitions.newChatOpeningPrefix.read(from: defaults) ?? "" }
        set {
            AppSettingDefinitions.newChatOpeningPrefix.write(newValue, to: defaults)
        }
    }

    /// Extra context appended after the task in the first message of every new chat.
    ///
    /// Empty means no extra message. It is deliberately app-wide rather than copied into the
    /// session record: the value is consumed once when the chat is created, and the combined
    /// opening is what the provider persists in its own transcript. Resuming an existing chat
    /// never reads it.
    var newChatOpeningSuffix: String {
        get { AppSettingDefinitions.newChatOpeningSuffix.read(from: defaults) ?? "" }
        set {
            AppSettingDefinitions.newChatOpeningSuffix.write(newValue, to: defaults)
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
            AppSettingDefinitions.harmonizesTerminalBackgrounds.write(newValue, to: defaults)
        }
    }

    /// Read where a terminal is being configured, which is not always on the main actor.
    nonisolated static var harmonizesTerminalBackgrounds: Bool {
        _ = registerStandardDefaults
        return AppSettingDefinitions.harmonizesTerminalBackgrounds.read(from: .standard) ?? true
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
            AppSettingDefinitions.notifiesOnAttention.write(newValue, to: defaults)
        }
    }

    /// Read by the alert center off the settings-change event, same pattern as its neighbours.
    nonisolated static var notifiesOnAttention: Bool {
        _ = registerStandardDefaults
        return AppSettingDefinitions.notifiesOnAttention.read(from: .standard) ?? true
    }

    /// The alert kinds switched *off*, stored that way for the same reason attachment
    /// detection is: every kind — including one added later — starts on, with no defaults
    /// migration and no seed per case.
    private var disabledAttentionAlerts: Set<AttentionAlert> {
        get {
            Set(
                (AppSettingDefinitions.disabledAttentionAlerts.read(from: defaults) ?? [])
                    .compactMap(AttentionAlert.init(rawValue:))
            )
        }
        set {
            AppSettingDefinitions.disabledAttentionAlerts.write(
                newValue.map(\.rawValue).sorted(),
                to: defaults
            )
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
                (AppSettingDefinitions.suppressedConfirmations.read(from: defaults) ?? [])
                    .compactMap(ConfirmationPrompt.init(rawValue:))
            )
        }
        set {
            AppSettingDefinitions.suppressedConfirmations.write(
                newValue.map(\.rawValue).sorted(),
                to: defaults
            )
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
        get { Set(AppSettingDefinitions.hiddenNotices.read(from: defaults) ?? []) }
        set {
            AppSettingDefinitions.hiddenNotices.write(newValue.sorted(), to: defaults)
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

    /// What a program's `BEL` sounds like, including not at all.
    ///
    /// Deliberately *not* under any of the notification switches: a bell is the program in
    /// front of you asking for attention, not Threading noticing something on your behalf, so
    /// muting a project's notifications does not gag its terminal. Unseeded, and an absent key
    /// is the system alert sound — which is what every install heard before this setting
    /// existed.
    var terminalBellSound: SoundChoice {
        get {
            SoundChoice(storedValue: AppSettingDefinitions.terminalBellSound.read(from: defaults))
                ?? TerminalBellDefaults.sound
        }
        set {
            AppSettingDefinitions.terminalBellSound.write(newValue.storedValue, to: defaults)
        }
    }

    /// Which sound an alert that sounds carries, including none.
    ///
    /// Unseeded, because the default is the *absence* of a choice: no key means macOS's own
    /// notification tone, which is what every install has heard until it says otherwise. A
    /// stored name is a file name resolved at delivery time, never a path — see `SoundChoice`.
    /// `silent` is what the retired "Play a sound" checkbox became.
    var attentionAlertSound: SoundChoice {
        get {
            SoundChoice(storedValue: AppSettingDefinitions.attentionAlertSound.read(from: defaults))
                ?? AttentionAlertDefaults.sound
        }
        set {
            AppSettingDefinitions.attentionAlertSound.write(newValue.storedValue, to: defaults)
        }
    }

    /// Sounds chosen for one event rather than for a whole kind, keyed by `SoundEvent` raw
    /// value and holding `SoundChoice` stored strings.
    ///
    /// Typed `[String: String]` at the boundary on purpose, and read and written whole: a key
    /// written by a **later** build, naming an event this one has never heard of, has to survive
    /// being read and written here. Decoding to the typed form for use and writing back through
    /// it would delete exactly those entries, which is how a downgrade-then-upgrade silently
    /// discards someone's configuration.
    ///
    /// Unseeded. An absent key is not "no sound" but "no entry": resolution widens to the kind
    /// level and then to the built-in answer — see `SoundResolution`.
    var soundEventChoices: [String: String] {
        AppSettingDefinitions.soundEventChoices.read(from: defaults) ?? [:]
    }

    /// The entry for one event, or nil when this scope has nothing to say about it.
    func soundChoice(for event: SoundEvent) -> SoundChoice? {
        SoundChoice(storedValue: soundEventChoices[event.rawValue])
    }

    /// Writes one entry, or removes it. `nil` means *inherit* and is stored as absence — a
    /// stored value equal to what would have been inherited is what stops a later change to a
    /// broader level from reaching this event.
    func setSoundChoice(_ choice: SoundChoice?, for event: SoundEvent) {
        var raw = soundEventChoices
        raw[event.rawValue] = choice?.storedValue
        AppSettingDefinitions.soundEventChoices.write(raw, to: defaults)
    }

    /// Clears every sound the app scope has been given — both pickers and the per-event map —
    /// so each falls back to the built-in answer it had before anybody chose anything.
    ///
    /// What the Customize sheet's *Reset All* does at this scope. The keys are **removed**
    /// rather than written back with their defaults, so an install that has reset reads exactly
    /// like one that never chose: absence is the default's own encoding here, and writing the
    /// value would leave a preference behind claiming somebody picked it.
    func resetSoundChoices() {
        AppSettingDefinitions.soundEventChoices.remove(from: defaults, notifying: false)
        AppSettingDefinitions.terminalBellSound.remove(from: defaults, notifying: false)
        AppSettingDefinitions.attentionAlertSound.remove(from: defaults)
    }

    /// Whether every sound the app can make is held — the global silence gate.
    ///
    /// **A gate, not a scope.** It sits *ahead* of the resolution chain rather than at the front
    /// of it, and it writes to no override map: toggling it off restores every scope's answer
    /// untouched, for the same reason the mute writer stores `nil` for a matching value —
    /// transient state must not rewrite configuration. The shape is `AttentionAlertScope`'s,
    /// which explains why an app-wide switch is deliberately not one more fallback but a gate no
    /// per-scope exception may outlive.
    ///
    /// It silences **audio** and nothing else. Banners still post, the sidebar still raises its
    /// hand, a bell still ends the inferred turn: Mute answers "don't tell me", this answers
    /// "tell me quietly", at app width. Settings auditions are deliberately outside it — see
    /// `TerminalBell.play` and `NotificationSoundPreview`.
    ///
    /// It persists across relaunch, which a hidden state could not honestly do: the speaker at
    /// the sidebar's foot is worn while it holds, so a quiet app is explicable from the window.
    var silencesAllSounds: Bool {
        get { AppSettingDefinitions.silencesAllSounds.read(from: defaults) ?? false }
        set {
            AppSettingDefinitions.silencesAllSounds.write(newValue, to: defaults)
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
            AppSettingDefinitions.convertsDroppedImages.write(newValue, to: defaults)
        }
    }

    /// Read inside the drop itself, which is a view's main-thread work rather than the actor's.
    nonisolated static var convertsDroppedImages: Bool {
        _ = registerStandardDefaults
        return AppSettingDefinitions.convertsDroppedImages.read(from: .standard) ?? true
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
            AppSettingDefinitions.copiesTerminalSelection.write(newValue, to: defaults)
        }
    }

    /// Read at the end of the selection gesture, which is a view's main-thread work.
    nonisolated static var copiesTerminalSelection: Bool {
        _ = registerStandardDefaults
        return AppSettingDefinitions.copiesTerminalSelection.read(from: .standard) ?? false
    }

    /// Whether the sidebar follows the agent's own name for the conversation — the terminal
    /// title while a PTY is attached, the transcript's title records otherwise.
    var usesAgentTitleInSidebar: Bool {
        get { Self.usesAgentTitleInSidebar }
        set {
            AppSettingDefinitions.usesAgentTitleInSidebar.write(newValue, to: defaults)
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
        return AppSettingDefinitions.usesAgentTitleInSidebar.read(from: .standard) ?? true
    }

    /// Likewise for the sidebar's branch grouping, which `SidebarTreeBuilder` consults while
    /// building nodes from plain model values.
    nonisolated static var groupsSessionsByBranch: Bool {
        _ = registerStandardDefaults
        return AppSettingDefinitions.groupsSessionsByBranch.read(from: .standard) ?? true
    }

    /// Whether the sidebar gathers a project's sessions under the branch they ran on,
    /// where a branch has more than one.
    var groupsSessionsByBranch: Bool {
        get { Self.groupsSessionsByBranch }
        set {
            AppSettingDefinitions.groupsSessionsByBranch.write(newValue, to: defaults)
        }
    }

    /// Same access pattern as `groupsSessionsByBranch`, for the same reader.
    nonisolated static var groupsLoneBranches: Bool {
        _ = registerStandardDefaults
        return AppSettingDefinitions.groupsLoneBranches.read(from: .standard) ?? true
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
            AppSettingDefinitions.groupsLoneBranches.write(newValue, to: defaults)
        }
    }

    /// Whether the sidebar's tree drops horizontal indentation and starts every row at one
    /// shared edge, saying where a group begins with vertical spacing and a rule instead.
    ///
    /// Opt-in, so it defaults to `false` and needs no seed. Read only where the outline draws,
    /// which is main-actor code throughout — `SidebarTreeBuilder` never consults it, because
    /// the compact tree is the same tree presented differently.
    var compactsSidebarTree: Bool {
        get { AppSettingDefinitions.compactsSidebarTree.read(from: defaults) ?? false }
        set {
            AppSettingDefinitions.compactsSidebarTree.write(newValue, to: defaults)
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
        get { AppSettingDefinitions.followsCheckoutBranch.read(from: defaults) ?? true }
        set {
            AppSettingDefinitions.followsCheckoutBranch.write(newValue, to: defaults)
        }
    }

    /// Same access pattern again; no seeding needed — an absent or unknown raw value reads
    /// as `.manual`, which is the documented default.
    nonisolated static var sidebarSessionOrder: SidebarSessionOrder {
        let raw = AppSettingDefinitions.sidebarSessionOrder.read(from: .standard)
        return raw.flatMap(SidebarSessionOrder.init(rawValue:)) ?? .manual
    }

    /// How a project's chats and terminals are arranged in the sidebar. Pinned chats are
    /// hoisted within the chat group; this decides the order among equals or which type leads.
    ///
    /// Choosing a *different* order lands on that order's natural direction. A direction is a
    /// statement about one order's field — "Z to A" is about names — so carrying it into the
    /// next order chosen is a reversal nobody asked for. Enforced here rather than at the menu
    /// so every route to the setting keeps the invariant.
    var sidebarSessionOrder: SidebarSessionOrder {
        get { Self.sidebarSessionOrder }
        set {
            if newValue != Self.sidebarSessionOrder {
                AppSettingDefinitions.sidebarSessionOrderIsReversed.write(
                    false,
                    to: defaults,
                    notifying: false
                )
            }
            AppSettingDefinitions.sidebarSessionOrder.write(newValue.rawValue, to: defaults)
        }
    }

    /// Same access pattern; an absent key reads as `false`, which is the natural direction of
    /// whichever order is chosen.
    nonisolated static var sidebarSessionOrderIsReversed: Bool {
        AppSettingDefinitions.sidebarSessionOrderIsReversed.read(from: .standard) ?? false
    }

    /// Whether the chosen order runs backwards: newest added first, least recently active
    /// first, Z to A, or terminals before chats.
    var sidebarSessionOrderIsReversed: Bool {
        get { Self.sidebarSessionOrderIsReversed }
        set {
            AppSettingDefinitions.sidebarSessionOrderIsReversed.write(newValue, to: defaults)
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
        let raw = AppSettingDefinitions.promptReturnKey.read(from: .standard)
        return raw.flatMap(PromptReturnKey.init(rawValue:)) ?? .matchesComposer
    }

    /// What Return does in a prompt composer.
    var promptReturnKey: PromptReturnKey {
        get { Self.promptReturnKey }
        set {
            AppSettingDefinitions.promptReturnKey.write(newValue.rawValue, to: defaults)
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
        AppSettingDefinitions.chromeFontFamily.read(from: .standard)
    }

    var chromeFontFamily: String? {
        get { Self.chromeFontFamily }
        set {
            if let newValue {
                AppSettingDefinitions.chromeFontFamily.write(newValue, to: defaults)
            } else {
                AppSettingDefinitions.chromeFontFamily.remove(from: defaults)
            }
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
        AppSettingDefinitions.conversationFontFamily.read(from: .standard)
    }

    var conversationFontFamily: String? {
        get { Self.conversationFontFamily }
        set {
            if let newValue {
                AppSettingDefinitions.conversationFontFamily.write(newValue, to: defaults)
            } else {
                AppSettingDefinitions.conversationFontFamily.remove(from: defaults)
            }
        }
    }

    /// The semantic scale applied to every font vended by `Design.Typography`.
    ///
    /// The terminal remains independent because its profile stores an explicit family and point
    /// size. Host-rendered extension UI does use the design system and therefore follows this
    /// setting automatically.
    nonisolated static var appTextSize: AppTextSize {
        _ = registerStandardDefaults
        let raw = AppSettingDefinitions.appTextSize.read(from: .standard)
        return raw.flatMap(AppTextSize.init(rawValue:)) ?? .standard
    }

    var appTextSize: AppTextSize {
        get {
            let raw = AppSettingDefinitions.appTextSize.read(from: defaults)
            return raw.flatMap(AppTextSize.init(rawValue:)) ?? .standard
        }
        set {
            AppSettingDefinitions.appTextSize.write(newValue.rawValue, to: defaults)
        }
    }

    /// Whether projects without an icon look for one automatically — the checkout's own
    /// favicon or app icon, then the repository's GitHub avatar or homepage favicon.
    /// The network sources only ever contact hosts the project itself points at.
    var discoversProjectIcons: Bool {
        get { AppSettingDefinitions.discoversProjectIcons.read(from: defaults) ?? true }
        set {
            AppSettingDefinitions.discoversProjectIcons.write(newValue, to: defaults)
        }
    }

    /// Whether sessions show their account's avatar, looked up from its login email via
    /// Gravatar or GitHub's public-email search. Off sends nothing anywhere.
    var discoversAccountAvatars: Bool {
        get { AppSettingDefinitions.discoversAccountAvatars.read(from: defaults) ?? true }
        set {
            AppSettingDefinitions.discoversAccountAvatars.write(newValue, to: defaults)
        }
    }

    /// The working indicator shown for each newly-started conversation turn.
    var workingOrbStyle: WorkingOrbStyle {
        get {
            AppSettingDefinitions.workingOrbStyle.read(from: defaults)
                .flatMap(WorkingOrbStyle.init(rawValue:))
                ?? MotionPreferencesDefaults.workingOrbStyle
        }
        set {
            AppSettingDefinitions.workingOrbStyle.write(newValue.rawValue, to: defaults)
        }
    }

    /// The character animation used when the active chat's visible name changes.
    var chatNameMorphStyle: ChatNameMorphStyle {
        get {
            AppSettingDefinitions.chatNameMorphStyle.read(from: defaults)
                .flatMap(ChatNameMorphStyle.init(rawValue:))
                ?? MotionPreferencesDefaults.chatNameMorphStyle
        }
        set {
            AppSettingDefinitions.chatNameMorphStyle.write(newValue.rawValue, to: defaults)
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
                (AppSettingDefinitions.disabledAttachmentDetectionAgentKinds.read(from: defaults) ?? [])
                    .compactMap(AgentKind.init(rawValue:))
            )
        }
        set {
            AppSettingDefinitions.disabledAttachmentDetectionAgentKinds.write(
                newValue.map(\.rawValue).sorted(),
                to: defaults
            )
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
        get { AppSettingDefinitions.includesAttachmentsOutsideProject.read(from: defaults) ?? false }
        set {
            AppSettingDefinitions.includesAttachmentsOutsideProject.write(newValue, to: defaults)
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
        get { AppSettingDefinitions.capturesPageBeforeAgentActions.read(from: defaults) ?? false }
        set {
            AppSettingDefinitions.capturesPageBeforeAgentActions.write(newValue, to: defaults)
        }
    }

    /// Which same-repository checkout moves an agent may queue without another question.
    var sessionCheckoutAuthorityPolicy: SessionCheckoutAuthorityPolicy {
        get {
            let raw = AppSettingDefinitions.sessionCheckoutAuthorityPolicy.read(from: defaults)
            return raw.flatMap(SessionCheckoutAuthorityPolicy.init(rawValue:))
                ?? .allowExplicitRequests
        }
        set {
            AppSettingDefinitions.sessionCheckoutAuthorityPolicy.write(
                newValue.rawValue,
                to: defaults
            )
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

    /// Which complete leading navigator the user chose. An absent or unreadable value is Native;
    /// unreadable bytes are quarantined before the next choice can replace them.
    var workspaceNavigatorSelection: WorkspaceNavigatorSelection {
        get { cachedWorkspaceNavigatorSelection }
        set {
            guard newValue != cachedWorkspaceNavigatorSelection else { return }
            do {
                try Self.validateWorkspaceNavigatorSelection(newValue)
            } catch {
                ThreadingLogger.extensions.error(
                    "Refusing invalid workspace navigator selection"
                )
                return
            }
            guard workspaceNavigatorPersistence.save(newValue) else { return }
            cachedWorkspaceNavigatorSelection = newValue
            AppSettingDefinitions.workspaceNavigatorSelection.notifyChange()
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
        get { AppSettingDefinitions.usesContainedExtensionLauncher.read(from: defaults) ?? false }
        set {
            AppSettingDefinitions.usesContainedExtensionLauncher.write(newValue, to: defaults)
        }
    }

    // MARK: - MCP Transport

    /// Whether launches address the tool channel through `threading-mcp-bridge` rather than a
    /// URL the CLI resolves once at startup.
    ///
    /// Hidden and off by default: this is rollout step 2 of
    /// `docs/feature-drafts/durable-sessions.md` — the shim behind a setting, with HTTP still
    /// the fallback while it settles. `defaults write codes.threading mcpStdioBridgeEnabled
    /// -bool true` turns it on for the next launch of a session.
    ///
    /// `MCPBridgeDecision.live(settings:server:bundle:)` snapshots this accessor together with
    /// the two listener outcomes at the main-actor launch composition boundary.
    var usesMCPStdioBridge: Bool {
        get { AppSettingDefinitions.usesMCPStdioBridge.read(from: defaults) ?? false }
        set {
            AppSettingDefinitions.usesMCPStdioBridge.write(newValue, to: defaults)
        }
    }

    // MARK: - Background PTY Host

    /// Whether a session's PTY may live in the `threading-ptyd` background host rather than in
    /// this process.
    ///
    /// Hidden and off by default: this is §9 step 4 of
    /// `docs/feature-drafts/durable-sessions.md`, and it **must stay off** until the TCC
    /// attribution question (R1/P4 of the PTY-host design) has been answered on a SIP-enabled
    /// Mac. A launchd agent is not a supervised child of Threading, and if its children do not
    /// inherit Threading's file-access grants the feature reads to the user as "agents stopped
    /// being able to open my files". `defaults write codes.threading ptyHostEnabled -bool true`
    /// turns it on for the next session launch.
    ///
    /// Read through `PTYHostDecision.live(settings:bundle:)`, which snapshots it at the
    /// main-actor composition boundary together with the bundle's helper path and the rendezvous.
    var ptyHostEnabled: Bool {
        get { AppSettingDefinitions.ptyHostEnabled.read(from: defaults) ?? false }
        set {
            AppSettingDefinitions.ptyHostEnabled.write(newValue, to: defaults)
        }
    }

    // MARK: - Command Line Tools

    /// Whether every shell and agent Threading launches gets its command-line tools on `PATH`.
    ///
    /// Off by default: this changes the `PATH` of every child the app starts, which is not
    /// something to do to somebody's terminal unasked. On, the shim directory is *prepended* to
    /// whatever `PATH` already says, so `threading-ptyd` resolves inside Threading's own
    /// terminals and the shell drawer without a profile edit, and nothing else moves. The
    /// composition lives in `AgentEnvironment.applyingCommandLineTools`, which both the PTY and
    /// the headless launch paths go through.
    var prependsCommandLineToolsToPATH: Bool {
        get { Self.prependsCommandLineToolsToPATH }
        set {
            AppSettingDefinitions.prependsCommandLineToolsToPATH.write(newValue, to: defaults)
        }
    }

    /// Read where a child's environment is composed, which is not always the main actor —
    /// `AgentEnvironment.launchEnvironment()` runs wherever a headless probe runs.
    nonisolated static var prependsCommandLineToolsToPATH: Bool {
        _ = registerStandardDefaults
        return AppSettingDefinitions.prependsCommandLineToolsToPATH.read(from: .standard) ?? false
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
        get { AppSettingDefinitions.reportsClaudeLifecycleEvents.read(from: defaults) ?? true }
        set {
            AppSettingDefinitions.reportsClaudeLifecycleEvents.write(newValue, to: defaults)
        }
    }

    /// Whether Threading installs its lifecycle hooks into each Codex account's `hooks.json`.
    ///
    /// Off by default because it writes to a file the user owns and may already be using —
    /// this machine's own `~/.codex/hooks.json` was written by another tool. Installation
    /// merges rather than replaces, but the honest default for touching someone else's config
    /// is to ask first.
    var installsCodexHooks: Bool {
        get { AppSettingDefinitions.installsCodexHooks.read(from: defaults) ?? false }
        set {
            AppSettingDefinitions.installsCodexHooks.write(newValue, to: defaults)
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
        get { AppSettingDefinitions.suppressesClaudeStatusLine.read(from: defaults) ?? false }
        set {
            AppSettingDefinitions.suppressesClaudeStatusLine.write(newValue, to: defaults)
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
        get { AppSettingDefinitions.readsClaudeLoginFromKeychain.read(from: defaults) ?? false }
        set {
            AppSettingDefinitions.readsClaudeLoginFromKeychain.write(newValue, to: defaults)
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
        get { AppSettingDefinitions.bypassesCodexHookTrust.read(from: defaults) ?? false }
        set {
            AppSettingDefinitions.bypassesCodexHookTrust.write(newValue, to: defaults)
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
            guard let raw = AppSettingDefinitions.claudeRemoteControl.read(from: defaults),
                  let value = ClaudeRemoteControl(rawValue: raw) else { return .followClaude }
            return value
        }
        set {
            AppSettingDefinitions.claudeRemoteControl.write(newValue.rawValue, to: defaults)
        }
    }

    // MARK: - Conversation Speed

    /// How sessions for one runtime start before a conversation makes its own choice.
    ///
    /// The shipped default is `.agentSetting`, which preserves the CLI's own configuration.
    /// Standard and Fast are explicit overrides, kept separate per runtime because the two
    /// providers have independent accounts, availability and usage costs. A session-level
    /// `AgentSession.fastMode` remains more specific and wins at launch.
    func startupSpeed(for kind: AgentKind) -> AgentStartupSpeed {
        guard let descriptor = startupSpeedDescriptor(for: kind),
              let raw = descriptor.read(from: defaults),
              let speed = AgentStartupSpeed(rawValue: raw)
        else { return .agentSetting }
        return speed
    }

    func setStartupSpeed(_ speed: AgentStartupSpeed, for kind: AgentKind) {
        guard let descriptor = startupSpeedDescriptor(for: kind) else { return }
        descriptor.write(speed.rawValue, to: defaults)
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
            guard let raw = AppSettingDefinitions.defaultPermissionMode.read(from: defaults)
            else { return nil }
            return AgentPermissionMode(rawValue: raw)
        }
        set {
            if let newValue {
                AppSettingDefinitions.defaultPermissionMode.write(newValue.rawValue, to: defaults)
            } else {
                AppSettingDefinitions.defaultPermissionMode.remove(from: defaults)
            }
        }
    }

    // MARK: - Local Diagnostics

    /// Whether this Mac accepts bounded diagnostics requested from a paired owner iPhone.
    /// Off by default and independent of Remote Access: the transport may be available while
    /// this evidence path remains inert.
    var localDiagnosticsEnabled: Bool {
        get { AppSettingDefinitions.localDiagnosticsEnabled.read(from: defaults) ?? false }
        set {
            AppSettingDefinitions.localDiagnosticsEnabled.write(newValue, to: defaults)
        }
    }

    // MARK: - Remote Access

    /// Whether the remote-access server runs (and, once implemented, its tunnel). Off by
    /// default: even the loopback-only first milestone exposes interactive terminal access to
    /// any process holding its private link, so it exists only when the user turns it on.
    var remoteAccessEnabled: Bool {
        get {
            remoteAccessIsOffered
                && (AppSettingDefinitions.remoteAccessEnabled.read(from: defaults) ?? false)
        }
        set {
            AppSettingDefinitions.remoteAccessEnabled.write(
                remoteAccessIsOffered && newValue,
                to: defaults
            )
        }
    }

    /// The first-party hosted service selected by a developer-enabled build.
    ///
    /// A public release installed over an internal build shares its defaults domain, so the
    /// public getter deliberately refuses to inherit a stored development endpoint.
    var remoteHostedServiceEnvironment: RemoteHostedServiceEnvironment {
        get {
#if DEBUG || THREADING_INTERNAL
            let stored = AppSettingDefinitions.remoteHostedServiceEnvironment.read(from: defaults)
            return stored.flatMap(RemoteHostedServiceEnvironment.init(rawValue:)) ?? .production
#else
            return .production
#endif
        }
        set {
#if DEBUG || THREADING_INTERNAL
            AppSettingDefinitions.remoteHostedServiceEnvironment.write(
                newValue.rawValue,
                to: defaults
            )
#else
            AppSettingDefinitions.remoteHostedServiceEnvironment.write(
                RemoteHostedServiceEnvironment.production.rawValue,
                to: defaults
            )
#endif
        }
    }

    /// Whether this Mac answers on its tailnet.
    ///
    /// The `tailscale` door's switch. The setting says nothing about what the door is made of,
    /// which is what let a listener on this Mac's own tailnet address replace the Serve handler
    /// without the settings page changing.
    var remoteAccessTailscaleEnabled: Bool {
        get { AppSettingDefinitions.remoteAccessTailscaleEnabled.read(from: defaults) ?? false }
        set {
            AppSettingDefinitions.remoteAccessTailscaleEnabled.write(newValue, to: defaults)
        }
    }

    /// Whether a browser on the tailnet may open Threading without a certificate warning.
    ///
    /// **Reserved.** It becomes operative when the `tailscale` door binds this Mac's own tailnet
    /// address; until then Serve *is* that door and this switch would contradict it. See the
    /// descriptor for why it carries no settings row yet.
    var remoteAccessTailscaleServeEnabled: Bool {
        get {
            AppSettingDefinitions.remoteAccessTailscaleServeEnabled.read(from: defaults) ?? false
        }
        set {
            AppSettingDefinitions.remoteAccessTailscaleServeEnabled.write(newValue, to: defaults)
        }
    }

    /// The port the remote-access listener tries first.
    ///
    /// Sticky across launches, which is what lets a paired phone reconnect tomorrow without
    /// scanning again. A value outside the allowed range is refused on the way in and on the way
    /// out, so a privileged port cannot reach the listener however it was written.
    var remoteAccessListenerPort: UInt16 {
        get {
            let stored = AppSettingDefinitions.remoteAccessListenerPort.read(from: defaults)
                ?? Int(RemoteAccessDefaults.defaultListenerPort)
            guard let port = UInt16(exactly: stored) else {
                return RemoteAccessDefaults.defaultListenerPort
            }
            return port
        }
        set {
            AppSettingDefinitions.remoteAccessListenerPort.write(Int(newValue), to: defaults)
        }
    }

    /// How long a released remote viewport lease keeps holding its grid before the Mac's own
    /// frame decides again.
    ///
    /// Read at release time rather than cached, so a `defaults write` takes effect without a
    /// relaunch. `0` is a legal value and means "release immediately", which is the behaviour
    /// the grace replaced; the range clamps rather than refuses, because the nearest allowed
    /// delay is what somebody typing a number meant.
    var remoteViewportLeaseGraceSeconds: Int {
        get {
            AppSettingDefinitions.remoteViewportLeaseGraceSeconds.read(from: defaults)
                ?? RemoteAccessDefaults.viewportLeaseGraceSeconds
        }
        set {
            AppSettingDefinitions.remoteViewportLeaseGraceSeconds.write(newValue, to: defaults)
        }
    }

    /// The routable doors that get a listener.
    ///
    /// `lan` is the shipped default: the listener presents this Mac's pinned identity, so the
    /// door is offered. Empty means loopback only, which reaches this Mac and nothing else. An
    /// unrecognised value in the stored array is dropped rather than guessed at: a door is a
    /// decision to listen on a network, so an unknown one fails closed.
    var remoteAccessDoors: Set<RemoteAccessDoor> {
        get {
            let stored = AppSettingDefinitions.remoteAccessDoors.read(from: defaults) ?? []
            return Set(stored.compactMap(RemoteAccessDoor.init(rawValue:)))
                .intersection(RemoteAccessDoor.selectable)
        }
        set {
            let raw = newValue
                .intersection(RemoteAccessDoor.selectable)
                .map(\.rawValue)
                .sorted()
            AppSettingDefinitions.remoteAccessDoors.write(raw, to: defaults)
        }
    }

    /// An extra address to advertise beside the ones the interfaces report.
    ///
    /// Empty means none. This is the escape hatch for a static DNS name or a fixed address on
    /// the far side of a VPN, neither of which this Mac can enumerate.
    var remoteAccessAdvertisedHostname: String {
        get {
            (AppSettingDefinitions.remoteAccessAdvertisedHostname.read(from: defaults) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        set {
            AppSettingDefinitions.remoteAccessAdvertisedHostname.write(
                newValue.trimmingCharacters(in: .whitespacesAndNewlines),
                to: defaults
            )
        }
    }

    /// Whether this Mac announces its LAN door on the network so a paired phone finds it without
    /// being told an address.
    ///
    /// On by default. It is a separate switch from the door itself because an advertisement is a
    /// broadcast: everyone on the network can see the service, its instance name and its TXT
    /// record. Those carry this Mac's id, the protocol version and the certificate fingerprint,
    /// and nothing about the person using it.
    var remoteAccessDiscoveryEnabled: Bool {
        get { AppSettingDefinitions.remoteAccessDiscoveryEnabled.read(from: defaults) ?? true }
        set {
            AppSettingDefinitions.remoteAccessDiscoveryEnabled.write(newValue, to: defaults)
        }
    }

    /// How a newly shared session starts. The choice is only a default: the owner can switch
    /// the live session between collaborative and focused control at any time.
    var remoteInputControlDefault: RemoteInputControlDefault {
        get {
            guard let raw = AppSettingDefinitions.remoteInputControlDefault.read(from: defaults),
                  let value = RemoteInputControlDefault(rawValue: raw) else {
                return .collaborative
            }
            return value
        }
        set {
            AppSettingDefinitions.remoteInputControlDefault.write(newValue.rawValue, to: defaults)
        }
    }

    /// Where a report sent from a paired phone does its work.
    ///
    /// A shake report is the one session nobody watches start: it arrives while its owner is
    /// away from the Mac, in whichever checkout they left open. This is the choice that says
    /// whether it may touch that checkout.
    var phoneReportWorkspace: PhoneReportWorkspacePolicy {
        get {
            guard let raw = AppSettingDefinitions.phoneReportWorkspace.read(from: defaults),
                  let value = PhoneReportWorkspacePolicy(rawValue: raw) else {
                return .sameCheckout
            }
            return value
        }
        set {
            AppSettingDefinitions.phoneReportWorkspace.write(newValue.rawValue, to: defaults)
        }
    }

    /// Which builds this person receives, which is not what their build *is*. See
    /// `UpdateChannelSubscription`.
    ///
    /// An unset value is resolved against the running build rather than against a constant: a
    /// beta someone downloaded directly would otherwise default to the stable subscription,
    /// filtering away every beta item and never updating again. The stored string therefore only
    /// ever records a choice somebody actually made.
    var updateChannelSubscription: UpdateChannelSubscription {
        get {
            let stored = AppSettingDefinitions.updateChannelSubscription.read(from: defaults) ?? ""
            return UpdateChannelSubscription(rawValue: stored)
                ?? UpdateChannelSubscription.standard(for: AppInfo.buildChannel)
        }
        set {
            AppSettingDefinitions.updateChannelSubscription.write(newValue.rawValue, to: defaults)
        }
    }

    /// Whether Threading may ask its own and installed agent tools' official release sources
    /// whether newer versions exist.
    ///
    /// Defaults to **on**, and `defaults.bool` cannot express that — an unset key reads `false`,
    /// which would ship the feature switched off for everyone who never opened Settings. The
    /// registered default is `true` and this reads through it, so "never touched" and
    /// "deliberately off" stay distinguishable in the stored domain.
    var automaticUpdateChecksEnabled: Bool {
        get { AppSettingDefinitions.automaticUpdateChecksEnabled.read(from: defaults) ?? true }
        set {
            AppSettingDefinitions.automaticUpdateChecksEnabled.write(newValue, to: defaults)
        }
    }

    /// Whether an unfinished agent turn may prevent idle system sleep.
    ///
    /// Off by default because this changes the Mac's power use. The runtime holds no assertion
    /// merely because an agent process is alive at its prompt: only `.working` and
    /// `.awaitingUser` are unfinished turns. Display sleep and lid-closed sleep remain macOS's.
    var preventsIdleSystemSleepWhileAgentsWork: Bool {
        get {
            AppSettingDefinitions.preventsIdleSystemSleepWhileAgentsWork.read(from: defaults)
                ?? false
        }
        set {
            AppSettingDefinitions.preventsIdleSystemSleepWhileAgentsWork.write(
                newValue,
                to: defaults
            )
        }
    }

    // MARK: - MCP Tool Groups

    /// The tool groups the user has switched *off* on the Tools page. Stored as the disabled set,
    /// not the enabled one, so a group added in a future release is on by default rather than
    /// absent — an omitted id reads as enabled.
    var disabledToolGroupIDs: Set<String> {
        get { Set(AppSettingDefinitions.disabledToolGroupIDs.read(from: defaults) ?? []) }
        set {
            AppSettingDefinitions.disabledToolGroupIDs.write(Array(newValue), to: defaults)
        }
    }

    /// Dynamic identity is admitted only at the authenticated-owner boundary. Every other
    /// production access uses the typed descriptors above.
    func applyRemoteMutation(
        identity: String,
        value: AppSettingStoredValue
    ) -> AppSettingRemoteMutationResult {
        AppSettingDefinitions.applyRemoteMutation(
            identity: identity,
            value: value,
            defaults: defaults
        )
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

    /// Carries the pre-rename choices that together made an already-installed integration run.
    ///
    /// Codex hooks are opt-in because they edit a user-owned file. Before the bundle-id rename,
    /// that choice lived in `se.mjukis.Skalman`; losing it leaves a pre-rename installation on
    /// disk that Threading is no longer authorised to maintain, so no lifecycle report can pass
    /// its guard and ordinary model-thinking gaps read as finished turns. A stored current value
    /// always wins — including an explicit `false`. Only legacy `true` values are carried,
    /// because `false` is already the current default and writing it would distinguish nothing.
    ///
    /// The trust bypass is security-sensitive, but carrying it does not lower a new boundary:
    /// it restores the exact launch posture the same user explicitly chose for the same hooks
    /// before the bundle-id rename. It is carried only while hook installation itself remains
    /// enabled; a current choice to turn installation off also keeps the bypass off.
    /// This remains a narrow migration rather than a wholesale preferences import.
    private func migrateLegacyCodexHookPreferences(from legacyPreferences: [String: Any]) {
        let installsHooks = AppSettingDefinitions.installsCodexHooks
        let bypassesTrust = AppSettingDefinitions.bypassesCodexHookTrust
        if !installsHooks.containsValue(in: defaults),
           legacyPreferences[installsHooks.persistenceKey] as? Bool == true {
            installsHooks.write(true, to: defaults, notifying: false)
        }

        if installsHooks.read(from: defaults) == true,
           !bypassesTrust.containsValue(in: defaults),
           legacyPreferences[bypassesTrust.persistenceKey] as? Bool == true {
            bypassesTrust.write(true, to: defaults, notifying: false)
        }
    }

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
    /// Writes through typed descriptors with notification suppressed because this runs while
    /// the settings object is still being built.
    private func migrateClosingConfirmation() {
        let marker = AppSettingDefinitions.closingConfirmationMigration
        let legacy = AppSettingDefinitions.legacyClosingConfirmation
        let suppressed = AppSettingDefinitions.suppressedConfirmations
        guard !marker.containsValue(in: defaults) else { return }

        // Seeded `true`, so a `false` here can only have been written by the old settings row.
        if legacy.read(from: defaults) == false {
            let carried = suppressedConfirmations
                .union(ConfirmationPrompt.closingConfirmationSuccessors)
            suppressed.write(carried.map(\.rawValue).sorted(), to: defaults, notifying: false)
        }
        legacy.remove(from: defaults, notifying: false)
        marker.write(true, to: defaults, notifying: false)
    }

    /// `playsAttentionAlertSound` was a checkbox for something the picker can now say itself.
    ///
    /// Its meaning — "alerts never sound" — is `attentionAlertSound = .silent`, so an unchecked
    /// box carries over as that value and silences exactly the alerts it silenced before. A
    /// checked box and an install that never touched it both write nothing: sounding is what
    /// the picker already answers.
    ///
    /// The old key's **seed is gone**, which is what makes the removal the marker: with nothing
    /// registered, `object(forKey:)` answers non-nil only while a real stored value survives, so
    /// this runs once and every later launch returns on the first line. Written through
    /// The typed descriptors suppress notification because this runs while the settings object
    /// is still being built.
    private func migrateAttentionAlertSoundSwitch() {
        let legacy = AppSettingDefinitions.legacyPlaysAttentionAlertSound
        guard legacy.containsValue(in: defaults) else { return }
        if legacy.read(from: defaults) == false {
            AppSettingDefinitions.attentionAlertSound.write(
                SoundChoice.silent.storedValue,
                to: defaults,
                notifying: false
            )
        }
        legacy.remove(from: defaults, notifying: false)
    }

    /// `remoteAccessConnectionMode` was one choice between overlapping things; a door is a
    /// switch per network. This is what is left of it.
    ///
    /// The carry is deliberately narrow. `tailscale` and `tailscaleAndRelay` both mean "this Mac
    /// answers on my tailnet", so both turn the `tailscale` door on. `relay` carries **nothing**:
    /// the Cloudflare Quick Tunnel it named is gone, because its address changed every launch and
    /// pairing cannot survive that. Somebody who was on Relay therefore lands on the shipped
    /// default, `This network`, which is the route that replaced it.
    ///
    /// The three keys are read as raw strings and booleans rather than through descriptors,
    /// because they are no longer settings: nothing writes them, nothing else reads them, and a
    /// descriptor for a value the app does not have is a settings row waiting to be reintroduced
    /// by mistake. Having read them, this removes them, so the only trace left of the mode is the
    /// marker below.
    ///
    /// `remoteAccessDoors` is not touched here. Its registered default moved to `lan` in the
    /// same release, so an install that never wrote the key gets the LAN door by reading it, and
    /// an install that did write one already stated a decision this migration must not overrule.
    ///
    /// The marker is written last and never seeded, so an interrupted migration re-runs; the
    /// second run finds the keys gone and carries nothing, so a person who later switches
    /// Tailscale off keeps that answer. Writes suppress notification because this runs while the
    /// settings object is still being built.
    private func migrateRemoteAccessConnectionMode() {
        // A hosted test bundle runs inside the shipping app and sees the developer's real
        // defaults domain, so this would be a write on their behalf — the rule
        // `legacyPreferencesForSharedProcess` already states for the other one-time import. A
        // store a test hands over explicitly still migrates, which is how it is asserted.
        guard defaults != .standard || Self.importsLegacyPreferencesForSharedProcess else {
            return
        }
        let marker = AppSettingDefinitions.remoteAccessDoorMigration
        guard !marker.containsValue(in: defaults) else { return }
        let mode = defaults.string(forKey: RetiredRemoteAccessKeys.connectionMode)
        if mode == RetiredRemoteAccessKeys.tailscaleMode
            || mode == RetiredRemoteAccessKeys.tailscaleAndRelayMode {
            AppSettingDefinitions.remoteAccessTailscaleEnabled.write(
                true,
                to: defaults,
                notifying: false
            )
        }
        for key in RetiredRemoteAccessKeys.all { defaults.removeObject(forKey: key) }
        marker.write(true, to: defaults, notifying: false)
    }

    /// A release installed over a development build inherits that build's defaults domain.
    /// Clear an old opt-in rather than merely masking it, so a later channel that offers Remote
    /// Access cannot silently resurrect a server the person last enabled in an experimental
    /// build. Writes no value for the ordinary already-off case.
    private func disableRemoteAccessWhenUnavailable() {
        guard !remoteAccessIsOffered,
              AppSettingDefinitions.remoteAccessEnabled.read(from: defaults) == true else {
            return
        }
        AppSettingDefinitions.remoteAccessEnabled.write(
            false,
            to: defaults,
            notifying: false
        )
    }

    /// The stored values the retired connection mode left behind, named once so the migration
    /// that reads them is also the thing that deletes them.
    ///
    /// Raw keys rather than `AppSettingDescriptor`s: these are not settings any more. The two
    /// mode values named here are the only ones that ever meant "this Mac answers on my tailnet";
    /// `relay` and anything unrecognised carry nothing.
    private enum RetiredRemoteAccessKeys {
        static let connectionMode = "remoteAccessConnectionMode"
        static let ownerRelayFallback = "remoteAccessAllowsOwnerRelayFallback"
        static let keepsRelayReady = "remoteAccessKeepsRelayReady"
        static let tailscaleMode = "tailscale"
        static let tailscaleAndRelayMode = "tailscaleAndRelay"

        static let all = [connectionMode, ownerRelayFallback, keepsRelayReady]
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
        AppSettingDefinitions.registeredDefaults
    }

    /// The setting is intentionally defined only for runtimes with a measured Fast mechanism.
    /// An exhaustive switch keeps adding a new runtime from silently borrowing another one's
    /// preference key.
    private func startupSpeedDescriptor(for kind: AgentKind) -> AppSettingDescriptor<String>? {
        switch kind {
        case .claude: return AppSettingDefinitions.claudeStartupSpeed
        case .codex: return AppSettingDefinitions.codexStartupSpeed
        case .grok, .openCode, .cursor: return nil
        }
    }

    private enum WorkspaceNavigatorValidationError: Error {
        case invalidIdentity
    }

    private static func validateWorkspaceNavigatorSelection(
        _ selection: WorkspaceNavigatorSelection
    ) throws {
        guard AppSettingDefinitions.accepts(selection) else {
            throw WorkspaceNavigatorValidationError.invalidIdentity
        }
    }

}

// MARK: - Agent Startup Speed

/// The app-wide speed posture for sessions that have no per-conversation override.
///
/// Three states rather than a toggle because omission has provider-owned meaning: Claude may
/// persist `fastMode` in its settings and Codex may set `service_tier` in `config.toml`. Only
/// `.agentSetting` leaves those untouched; Standard must travel as an explicit `false`/`default`
/// to turn off an account configured for Fast.
enum AgentStartupSpeed: String, CaseIterable {
    case agentSetting
    case standard
    case fast

    var fastModeOverride: Bool? {
        switch self {
        case .agentSetting: nil
        case .standard: false
        case .fast: true
        }
    }

    var settingsTitle: String {
        switch self {
        case .agentSetting: L10n.string("Agent's Setting")
        case .standard: L10n.string("Standard")
        case .fast: L10n.string("Fast")
        }
    }
}

// MARK: - Legacy App Preferences

enum LegacyAppPreferenceDefaults {
    /// The preferences domain used before the product and bundle identifier were renamed.
    static let domainName = "se.mjukis.Skalman"
}

// MARK: - App Text Size

/// A deliberately small, named scale instead of a free point-size field.
///
/// Font roles keep their hierarchy at every step, layout can be exercised at a bounded largest
/// size, and the user can still move from compact to accessibility-sized chrome without
/// knowing what point size each role started at.
public enum AppTextSize: String, CaseIterable {
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

// MARK: - Session Restore Policy

/// Which sessions a launch brings back live.
///
/// The two answers differ in what they are bounded by, which is the whole of the choice.
/// `.runningAtLastQuit` is bounded by evidence: the machine ran exactly that set side by side a
/// second before the quit. It depends on one record, though, and a reboot, a force quit, or an
/// app that opened and closed again without restoring anything leaves that record saying nothing.
/// `.recentlyUsed` survives all of those because it reads the conversations themselves, and is
/// bounded only by the cap it is given.
enum SessionRestorePolicy: String, CaseIterable, Sendable {

    /// Bring nothing back. Every row starts dormant and resumes when it is opened.
    case nothing

    /// What had a live agent at the last quit.
    case runningAtLastQuit

    /// What was used inside the window, most recent first, up to the limit.
    case recentlyUsed

    /// The settings pop-up's wording, read as the end of its row's title: "Bring back at launch ▸
    /// Running at last quit". Terse because the control is one pop-up wide and a title that
    /// truncates says less than a short one.
    var settingsTitle: String {
        switch self {
        case .nothing: L10n.string("Nothing")
        case .runningAtLastQuit: L10n.string("Running at last quit")
        case .recentlyUsed: L10n.string("Recently used")
        }
    }

    /// The policy a store holds, given what is stored and the toggle this setting replaced.
    ///
    /// Kept apart from `UserDefaults` so the migration is a fact about values rather than about a
    /// hosted test's preferences: this bundle runs inside the app, and a test that wrote a real
    /// policy key would decide what the developer's own next launch does.
    static func resolved(
        stored: String?,
        legacyRestoresRunningSessions: Bool
    ) -> SessionRestorePolicy {
        if let stored, let value = SessionRestorePolicy(rawValue: stored) { return value }
        return legacyRestoresRunningSessions ? .runningAtLastQuit : .nothing
    }
}

// MARK: - Session Restore Defaults

enum SessionRestoreDefaults {

    /// One day, which on a working store is close to what was running anyway, and reaches the
    /// conversation somebody left open overnight without reaching last week's.
    static let windowDays = 1

    /// Twelve, which is about what one machine already carries comfortably and roughly a dozen
    /// staggered CLI starts, so the launch settles in well under a minute.
    static let limit = 12

    /// Offered in the settings pop-ups. Bounds rather than a free field: both values decide how
    /// many processes a launch spawns, so the range is the product's, not a text field's.
    static let windowDayChoices = [1, 2, 3, 7, 14, 30]
    static let limitChoices = [4, 8, 12, 16, 24, 32]

    static func clampWindowDays(_ value: Int) -> Int {
        guard let first = windowDayChoices.first, let last = windowDayChoices.last else {
            return windowDays
        }
        return value <= 0 ? windowDays : min(max(value, first), last)
    }

    static func clampLimit(_ value: Int) -> Int {
        guard let first = limitChoices.first, let last = limitChoices.last else { return limit }
        return value <= 0 ? limit : min(max(value, first), last)
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
public enum PromptReturnKey: String, CaseIterable {

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

/// How a project's chats and terminals are arranged in the sidebar.
///
/// `manual` is the store's own order — the order sessions were created in, which is also the
/// only order the user can influence directly. The others are derived orders, re-applied on
/// every rebuild. Raw values are stored in defaults, so a case rename is a silent reset.
enum SidebarSessionOrder: String, CaseIterable {
    case manual
    case recentActivity
    case name
    case type

    /// The menu wording: what the order sorts by, since "manual" describes a mechanism and
    /// "order added" describes what the list actually shows.
    var menuTitle: String {
        switch self {
        case .manual: L10n.string("Sort by Order Added")
        case .recentActivity: L10n.string("Sort by Recent Activity")
        case .name: L10n.string("Sort by Name")
        case .type: L10n.string("Sort by Type")
        }
    }

    /// What this order's forward direction is called. "Ascending" says nothing about a list of
    /// sessions, so each order names its own ends: the field decides whether "first" means the
    /// oldest, the most recent, or A.
    var naturalDirectionTitle: String {
        switch self {
        case .manual: L10n.string("Oldest First")
        case .recentActivity: L10n.string("Most Recent First")
        case .name: L10n.string("A to Z")
        case .type: L10n.string("Chats First")
        }
    }

    /// The same end of the same field, read from the other side.
    var reversedDirectionTitle: String {
        switch self {
        case .manual: L10n.string("Newest First")
        case .recentActivity: L10n.string("Least Recent First")
        case .name: L10n.string("Z to A")
        case .type: L10n.string("Terminals First")
        }
    }
}

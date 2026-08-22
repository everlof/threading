import AppKit
import UniformTypeIdentifiers

/// General preferences: which agent new sessions use, startup behaviour, and the shell.
final class GeneralPreferencesViewController: NSViewController {

    // MARK: - Controls

    private let defaultAgentPopUp = ThemedPopUp()
    private let claudeStartupSpeedPopUp = ThemedPopUp()
    private let codexStartupSpeedPopUp = ThemedPopUp()
    private let terminalTitleToggle = ThemedToggle()
    private let branchGroupingToggle = ThemedToggle()
    private let compactTreeToggle = ThemedToggle()
    private let branchFollowToggle = ThemedToggle()
    private let projectIconToggle = ThemedToggle()
    private let accountAvatarToggle = ThemedToggle()
    /// One path-detection switch per runtime. The scanner setting is keyed by `AgentKind`, so
    /// constructing the page from the same closed set prevents a new runtime from getting a
    /// setting the empty state can name but no row the user can reach.
    private let attachmentDetectionToggles: [AgentKind: ThemedToggle] = Dictionary(
        uniqueKeysWithValues: AgentKind.allCases.map { ($0, ThemedToggle()) }
    )
    private let outsideProjectAttachmentToggle = ThemedToggle()
    private let beforeActionCaptureToggle = ThemedToggle()
    private let restoreSessionToggle = ThemedToggle()
    private let restorePolicyPopUp = ThemedPopUp()
    private let restoreWindowPopUp = ThemedPopUp()
    private let restoreLimitPopUp = ThemedPopUp()
    private let attentionNotificationToggle = ThemedToggle()
    private let automaticUpdateToggle = ThemedToggle()
    private let preventIdleSleepToggle = ThemedToggle()

    /// One toggle per suppressible prompt, built from the register rather than declared one by
    /// one, so a prompt that can be switched off cannot arrive without the switch that turns it
    /// back on. That is the half of the register a type cannot enforce: `.suppressible` makes
    /// the settings copy unwritable-as-absent, and this makes the row unforgettable.
    private let confirmationToggles: [ConfirmationPrompt: ThemedToggle] = Dictionary(
        uniqueKeysWithValues: ConfirmationPrompt.suppressible.map { ($0, ThemedToggle()) }
    )

    /// The one control that un-hides notices — dynamic keys get a count and a way back, not a
    /// row per key, because a hidden receipt's extension may no longer exist to name it.
    private var showHiddenNoticesButton: ThemedButton?

    /// One toggle per alert kind, built from the enum rather than declared one by one, so a
    /// kind added later cannot arrive without a row to switch it off.
    private let alertToggles: [AttentionAlert: ThemedToggle] = Dictionary(
        uniqueKeysWithValues: AttentionAlert.allCases.map { ($0, ThemedToggle()) }
    )
    private let alertSoundPopUp = ThemedPopUp()
    private let bellSoundPopUp = ThemedPopUp()
    /// The global silence gate, mirrored. Its storage is the sidebar footer's and the menu
    /// item's — one Boolean, three surfaces — so this row follows the setting rather than only
    /// its own clicks; see `observeSilenceGate`.
    private let silenceToggle = ThemedToggle()
    /// Holds that subscription for the page's lifetime.
    private let appEvents = AppEventObservations()
    /// The Custom sounds list's home. Retained so a record gaining or losing an override
    /// replaces one card rather than the whole page — and, transitively, every other section's
    /// controls and their observers.
    private let customSoundsHost = NSView()
    private var customSoundsCard: NSView?
    private let claudeHookToggle = ThemedToggle()
    private let statusLineToggle = ThemedToggle()
    private let codexHookToggle = ThemedToggle()
    private let codexHookTrustToggle = ThemedToggle()
    private let remoteControlPopUp = ThemedPopUp()
    private let permissionModePopUp = ThemedPopUp()
    private let shellField = ThemedTextField()
    /// The two halves of the opening message, either side of the task. One timer settles
    /// whichever of them was typed into, because both write the same kind of value and neither
    /// means anything until the typing stops.
    private let newChatOpeningPrefixField = ThemedTextField()
    private let newChatOpeningSuffixField = ThemedTextField()
    private var openingMessageWriteTimer: Timer?
    /// The half with typing in it that has not settled yet, and the only half a flush writes.
    ///
    /// One at a time, because moving to the other field ends editing in this one and settles it
    /// first. Naming it matters: a flush that wrote *both* fields would push whatever this page
    /// last read into the half nobody touched, undoing a change made anywhere else while
    /// Settings was open — and would broadcast twice for one settled sentence.
    private weak var unsettledOpeningMessageField: ThemedTextField?

    /// The scratchpad's folder, **shown rather than typed.** A path with a typo in it is a
    /// scratchpad nobody can find and an agent launching into nothing; the picker cannot
    /// produce one, and a read-only field would offer an affordance it does not honour.
    private let scratchpadFolderLabel = NSTextField(labelWithString: "")

    private lazy var scratchpadDefaultButton = SettingsUI.button(
        "Use Default",
        target: self,
        action: #selector(useDefaultScratchpadFolder)
    )

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
        setupControls()
        setupLayout()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        flushOpeningMessageWrite()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // The page is cached across visits and messages are hidden from alerts elsewhere, so
        // the count is re-read on the way in rather than showing the last visit's state.
        updateHiddenNoticesControl()
        // Same reason, one folder further out: the Sounds folder is macOS's, and a sound can
        // arrive in it from Finder or another app between two visits to this page.
        rebuildAlertSoundMenu()
        rebuildBellSoundMenu()
        // Same reason once more: a record can gain or lose a sound from the sidebar between two
        // visits, and the list is the one surface that must never disagree with the records.
        rebuildCustomSoundsCard()
    }

    // MARK: - Setup

    private func setupControls() {
        for kind in AgentKind.allCases {
            defaultAgentPopUp.addItem(
                ThemedMenuItem(title: kind.displayName, representedValue: kind)
            )
        }
        defaultAgentPopUp.selectItem(at: AgentKind.allCases.firstIndex(of: AppSettings.shared.defaultAgentKind) ?? 0)
        defaultAgentPopUp.target = self
        defaultAgentPopUp.action = #selector(defaultAgentChanged)
        defaultAgentPopUp.translatesAutoresizingMaskIntoConstraints = false
        defaultAgentPopUp.widthAnchor.constraint(equalToConstant: SettingsUIDefaults.controlWidth).isActive = true

        configureStartupSpeedPopUp(
            claudeStartupSpeedPopUp,
            kind: .claude,
            accessibilityIdentifier: "settings.general.claude-startup-speed"
        )
        configureStartupSpeedPopUp(
            codexStartupSpeedPopUp,
            kind: .codex,
            accessibilityIdentifier: "settings.general.codex-startup-speed"
        )

        configure(terminalTitleToggle, isOn: AppSettings.shared.usesAgentTitleInSidebar, action: #selector(terminalTitleChanged))
        configure(branchGroupingToggle,
                  isOn: AppSettings.shared.groupsSessionsByBranch,
                  action: #selector(branchGroupingChanged))
        configure(compactTreeToggle,
                  isOn: AppSettings.shared.compactsSidebarTree,
                  action: #selector(compactTreeChanged))
        configure(branchFollowToggle,
                  isOn: AppSettings.shared.followsCheckoutBranch,
                  action: #selector(branchFollowChanged))
        configure(projectIconToggle,
                  isOn: AppSettings.shared.discoversProjectIcons,
                  action: #selector(projectIconChanged))
        configure(accountAvatarToggle,
                  isOn: AppSettings.shared.discoversAccountAvatars,
                  action: #selector(accountAvatarChanged))
        for kind in AgentKind.allCases {
            guard let toggle = attachmentDetectionToggles[kind] else { continue }
            configure(
                toggle,
                isOn: AppSettings.shared.detectsAttachmentReferences(for: kind),
                action: #selector(attachmentDetectionChanged(_:))
            )
            toggle.setAccessibilityIdentifier(
                "settings.general.\(kind.rawValue)-attachment-detection"
            )
        }
        configure(
            outsideProjectAttachmentToggle,
            isOn: AppSettings.shared.includesAttachmentsOutsideProject,
            action: #selector(outsideProjectAttachmentsChanged)
        )
        configure(
            beforeActionCaptureToggle,
            isOn: AppSettings.shared.capturesPageBeforeAgentActions,
            action: #selector(beforeActionCaptureChanged)
        )
        configure(restoreSessionToggle, isOn: AppSettings.shared.restoresLastSession, action: #selector(restoreSessionChanged))
        configureRestoreControls()
        for (prompt, toggle) in confirmationToggles {
            configure(toggle,
                      isOn: AppSettings.shared.asks(before: prompt),
                      action: #selector(confirmationChanged))
        }
        configure(attentionNotificationToggle,
                  isOn: AppSettings.shared.notifiesOnAttention,
                  action: #selector(attentionNotificationChanged))
        configure(automaticUpdateToggle,
                  isOn: AppSettings.shared.automaticUpdateChecksEnabled,
                  action: #selector(automaticUpdateChecksChanged))
        configure(
            preventIdleSleepToggle,
            isOn: AppSettings.shared.preventsIdleSystemSleepWhileAgentsWork,
            action: #selector(preventIdleSleepChanged)
        )
        preventIdleSleepToggle.setAccessibilityIdentifier(
            "settings.general.prevent-idle-system-sleep"
        )
        for (alert, toggle) in alertToggles {
            configure(toggle,
                      isOn: AppSettings.shared.notifies(on: alert),
                      action: #selector(alertKindChanged))
        }
        configureAlertSoundPopUp()
        configureBellSoundPopUp()
        configure(silenceToggle,
                  isOn: AppSettings.shared.silencesAllSounds,
                  action: #selector(silenceChanged))
        silenceToggle.setAccessibilityIdentifier("settings.general.silence-sounds")
        observeSilenceGate()
        customSoundsHost.setAccessibilityIdentifier("settings.general.custom-sounds")
        rebuildCustomSoundsCard()
        // Built from the store, so it follows the store: a chat given a sound from its own row
        // while this page is open has to appear here without a revisit.
        appEvents.observe(ProjectsDidChange.self) { [weak self] _ in
            self?.rebuildCustomSoundsCard()
        }
        updateNotificationRefinements()
        configure(claudeHookToggle,
                  isOn: AppSettings.shared.reportsClaudeLifecycleEvents,
                  action: #selector(claudeHookChanged))
        configure(statusLineToggle,
                  isOn: AppSettings.shared.suppressesClaudeStatusLine,
                  action: #selector(statusLineChanged))
        configure(codexHookToggle,
                  isOn: AppSettings.shared.installsCodexHooks,
                  action: #selector(codexHookChanged))
        configure(codexHookTrustToggle,
                  isOn: AppSettings.shared.bypassesCodexHookTrust,
                  action: #selector(codexHookTrustChanged))
        codexHookTrustToggle.isEnabled = AppSettings.shared.installsCodexHooks

        for value in ClaudeRemoteControl.allCases {
            remoteControlPopUp.addItem(
                ThemedMenuItem(title: value.settingsTitle, representedValue: value)
            )
        }
        rebuildPermissionModePopUp(for: AppSettings.shared.defaultAgentKind)
        permissionModePopUp.target = self
        permissionModePopUp.action = #selector(permissionModeChanged)
        permissionModePopUp.translatesAutoresizingMaskIntoConstraints = false
        permissionModePopUp.widthAnchor
            .constraint(equalToConstant: SettingsUIDefaults.controlWidth).isActive = true

        remoteControlPopUp.selectItem(
            at: ClaudeRemoteControl.allCases.firstIndex(of: AppSettings.shared.claudeRemoteControl) ?? 0
        )
        remoteControlPopUp.target = self
        remoteControlPopUp.action = #selector(remoteControlChanged)
        remoteControlPopUp.translatesAutoresizingMaskIntoConstraints = false
        remoteControlPopUp.widthAnchor
            .constraint(equalToConstant: SettingsUIDefaults.controlWidth).isActive = true

        shellField.applyFont(.body)
        shellField.placeholderString = TerminalDefaults.defaultShell
        shellField.stringValue = ProfileStorage.shared.defaultProfile.shellPath
        shellField.target = self
        shellField.action = #selector(shellPathChanged)

        newChatOpeningPrefixField.placeholderString = L10n.string(
            "For example: Think it through before you start changing files."
        )
        newChatOpeningPrefixField.stringValue = AppSettings.shared.newChatOpeningPrefix
        newChatOpeningPrefixField.setAccessibilityIdentifier(
            "settings.general.new-chat-opening-prefix"
        )
        newChatOpeningPrefixField.delegate = self

        newChatOpeningSuffixField.placeholderString = L10n.string(
            "For example: Rename this chat to a ONE-WORD, ALL-CAPS name that represents it."
        )
        newChatOpeningSuffixField.stringValue = AppSettings.shared.newChatOpeningSuffix
        newChatOpeningSuffixField.setAccessibilityIdentifier(
            "settings.general.new-chat-opening-suffix"
        )
        newChatOpeningSuffixField.delegate = self
    }

    private func configure(_ toggle: ThemedToggle, isOn: Bool, action: Selector) {
        toggle.state = isOn ? .on : .off
        toggle.target = self
        toggle.action = action
    }

    private func configureStartupSpeedPopUp(
        _ popUp: ThemedPopUp,
        kind: AgentKind,
        accessibilityIdentifier: String
    ) {
        for speed in AgentStartupSpeed.allCases {
            popUp.addItem(
                ThemedMenuItem(title: speed.settingsTitle, representedValue: speed)
            )
        }
        popUp.selectItem(
            at: AgentStartupSpeed.allCases.firstIndex(
                of: AppSettings.shared.startupSpeed(for: kind)
            ) ?? 0
        )
        popUp.target = self
        popUp.action = #selector(startupSpeedChanged)
        popUp.setAccessibilityIdentifier(accessibilityIdentifier)
        popUp.translatesAutoresizingMaskIntoConstraints = false
        popUp.widthAnchor
            .constraint(equalToConstant: SettingsUIDefaults.controlWidth).isActive = true
    }

    /// The three launch-restore controls.
    ///
    /// The window and the limit are pop-ups rather than fields because both decide how many agent
    /// processes a launch spawns: the range belongs to the product, not to whatever somebody can
    /// type. See `SessionRestoreDefaults`.
    private func configureRestoreControls() {
        let settings = AppSettings.shared

        for policy in SessionRestorePolicy.allCases {
            restorePolicyPopUp.addItem(
                ThemedMenuItem(title: policy.settingsTitle, representedValue: policy)
            )
        }
        restorePolicyPopUp.selectItem(
            at: SessionRestorePolicy.allCases.firstIndex(of: settings.sessionRestorePolicy) ?? 0
        )
        configureRestorePopUp(
            restorePolicyPopUp,
            action: #selector(restorePolicyChanged),
            accessibilityIdentifier: "settings.general.session-restore-policy"
        )

        for days in SessionRestoreDefaults.windowDayChoices {
            restoreWindowPopUp.addItem(
                ThemedMenuItem(title: Self.windowTitle(days: days), representedValue: days)
            )
        }
        restoreWindowPopUp.selectItem(
            at: SessionRestoreDefaults.windowDayChoices
                .firstIndex(of: settings.sessionRestoreWindowDays) ?? 0
        )
        configureRestorePopUp(
            restoreWindowPopUp,
            action: #selector(restoreWindowChanged),
            accessibilityIdentifier: "settings.general.session-restore-window"
        )

        for limit in SessionRestoreDefaults.limitChoices {
            restoreLimitPopUp.addItem(
                ThemedMenuItem(title: Self.limitTitle(limit), representedValue: limit)
            )
        }
        restoreLimitPopUp.selectItem(
            at: SessionRestoreDefaults.limitChoices
                .firstIndex(of: settings.sessionRestoreLimit) ?? 0
        )
        configureRestorePopUp(
            restoreLimitPopUp,
            action: #selector(restoreLimitChanged),
            accessibilityIdentifier: "settings.general.session-restore-limit"
        )

        updateRestoreRefinements()
    }

    private func configureRestorePopUp(
        _ popUp: ThemedPopUp,
        action: Selector,
        accessibilityIdentifier: String
    ) {
        popUp.target = self
        popUp.action = action
        popUp.setAccessibilityIdentifier(accessibilityIdentifier)
        popUp.translatesAutoresizingMaskIntoConstraints = false
        popUp.widthAnchor
            .constraint(equalToConstant: SettingsUIDefaults.controlWidth).isActive = true
    }

    /// The window and the limit belong to one policy, so they are dimmed rather than hidden under
    /// the others: a row that disappears takes the explanation of what the policy does with it.
    private func updateRestoreRefinements() {
        let refines = AppSettings.shared.sessionRestorePolicy == .recentlyUsed
        restoreWindowPopUp.isEnabled = refines
        restoreLimitPopUp.isEnabled = refines
    }

    /// "1 day", "3 days", localized by the system rather than by a plural rule of ours.
    private static func windowTitle(days: Int) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day]
        formatter.unitsStyle = .full
        let seconds = Double(days) * SessionRestoreDefaults.secondsPerDay
        return formatter.string(from: seconds) ?? "\(days)"
    }

    private static func limitTitle(_ limit: Int) -> String {
        L10n.format("At most %d", limit)
    }

    private func setupLayout() {
        let sessions = SettingsCard(rows: [
            SettingsUI.row(title: "New sessions use",
                           subtitle: "Used by New Session (⌘N). Other agents stay available from the Project menu.",
                           control: defaultAgentPopUp),
            SettingsUI.row(title: "Name sessions after the agent's own title",
                           subtitle: "Agents name the conversation as it develops. Renaming a session keeps your name.",
                           control: terminalTitleToggle),
            SettingsUI.row(
                title: "Group sessions by branch",
                subtitle: "Sessions that ran on the same branch gather under it, "
                    + "when a branch has more than one.",
                control: branchGroupingToggle
            ),
            SettingsUI.row(
                title: "Compact tree",
                subtitle: "Every sidebar row starts at the same edge. Projects separate "
                    + "with spacing and a rule instead of indentation.",
                control: compactTreeToggle
            ),
            SettingsUI.row(
                title: "Follow the checkout's branch",
                subtitle: "A session that isn't running updates its branch whenever its "
                    + "checkout switches — from another session or outside Threading alike. "
                    + "Off, it keeps the branch it last ran on.",
                control: branchFollowToggle
            ),
            SettingsUI.row(
                title: "Discover project icons",
                subtitle: "Projects without an icon use their own favicon or app icon, "
                    + "else their GitHub avatar or homepage favicon.",
                control: projectIconToggle
            ),
            SettingsUI.row(
                title: "Discover account avatars",
                subtitle: "Sessions show their account's Gravatar or GitHub avatar, "
                    + "found by its login email. A chosen emoji still wins.",
                control: accountAvatarToggle
            )
        ])

        let startup = SettingsCard(rows: [
            SettingsUI.row(title: "Reopen the last session at launch", control: restoreSessionToggle),
            SettingsUI.row(
                title: "Bring back at launch",
                subtitle: "Sessions resume in the background, one at a time, and are already "
                    + "running when you open them. Everything else stays dormant and resumes "
                    + "when you open it.",
                control: restorePolicyPopUp
            ),
            SettingsUI.row(
                title: "Counts as recently used",
                subtitle: "How far back to look. Measured from the last time a turn ran in the "
                    + "conversation, not from the last time Threading opened it.",
                control: restoreWindowPopUp
            ),
            SettingsUI.row(
                title: "Sessions brought back",
                subtitle: "Most recent first. Each one is a real agent process, so this is the "
                    + "ceiling on what a launch may start.",
                control: restoreLimitPopUp
            )
        ])

        let confirmations = SettingsCard(rows: confirmationRows())

        let notifications = SettingsCard(rows: notificationRows())

        let shell = SettingsCard(rows: [
            SettingsUI.fullRow(shellRow())
        ])

        let scratchpad = SettingsCard(rows: [
            SettingsUI.fullRow(scratchpadRow())
        ])

        let page = SettingsUI.page(title: "General", sections: [
            SettingsUI.section("Sessions", sessions),
            SettingsUI.section("Conversation Speed", conversationSpeedCard()),
            SettingsUI.section("Opening Message", openingMessageCard()),
            SettingsUI.note("Both are sent once, inside the first turn of a new chat — side "
                + "chats and cross-provider continuations included. Neither is sent again when "
                + "a chat resumes, and an imported conversation receives nothing. The name in "
                + "the sidebar still comes from the task you wrote."),
            SettingsUI.section("Attachments", attachmentDetectionCard()),
            SettingsUI.section("Scratchpad", scratchpad),
            SettingsUI.note("Chats that are about no project live here. The folder is made the "
                + "first time you start a scratchpad, and it is an ordinary git repository, so "
                + "Git Review works on it and nothing you write is lost. It sits outside "
                + "Threading's own storage on purpose — Reset Everything does not touch it."),
            SettingsUI.section("Startup", startup),
            SettingsUI.section("Confirmations", confirmations),
            SettingsUI.note("Only interruptions you can safely stop are listed. Anything that deletes something "
                + "for good, or grants access to a website, a tool, an extension or another person, "
                + "always asks."),
            SettingsUI.section("Notifications", notifications),
            SettingsUI.section("Terminal Bell", terminalBellCard()),
            SettingsUI.section("Silence", silenceCard()),
            SettingsUI.section("Custom Sounds", customSoundsHost),
            SettingsUI.note("Sounds you add are copied into ~/Library/Sounds, which is macOS's "
                + "folder rather than Threading's: anything installed there also appears in "
                + "System Settings' alert-sound list, and removing a file there removes it from "
                + "both."),
            SettingsUI.section("Permission Mode", permissionModeCard()),
            SettingsUI.section("Claude Remote Control", claudeRemoteControlCard()),
            SettingsUI.section("Claude Hooks", claudeHooksCard()),
            SettingsUI.section("Codex Hooks", codexHooksCard()),
            SettingsUI.section("Software Updates", updatesCard()),
            SettingsUI.section("Power", SettingsCard(rows: [
                SettingsUI.row(
                    title: "Keep this Mac awake while agents work",
                    subtitle: "Prevents idle system sleep while an agent turn is active or "
                        + "waiting for your answer. The display may turn off, and closing a "
                        + "MacBook’s lid can still put it to sleep.",
                    control: preventIdleSleepToggle
                )
            ])),
            SettingsUI.section("Shell", shell),
            SettingsUI.note("Shell path is used by shell sessions. Agent sessions launch through your login shell regardless.")
        ], hostPage: .general)

        page.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(page)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: view.topAnchor),
            page.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            page.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    /// The two providers expose Fast through different wires, but the user-facing decision is
    /// the same. Each row is separate because account settings and availability are separate;
    /// both explicitly cover terminal and Native surfaces so the choice does not read as a
    /// preference for only the composer beneath it.
    private func conversationSpeedCard() -> SettingsCard {
        SettingsCard(rows: [
            SettingsUI.row(
                title: "Claude sessions start in",
                subtitle: "Applies to Terminal and Native chats. Agent's Setting preserves "
                    + "Claude Code's own choice; Fast uses more credits and works only with "
                    + "supported models.",
                control: claudeStartupSpeedPopUp
            ),
            SettingsUI.row(
                title: "Codex sessions start in",
                subtitle: "Applies to Terminal and Native chats. Agent's Setting preserves "
                    + "Codex's own service tier; Fast uses more credits.",
                control: codexStartupSpeedPopUp
            )
        ])
    }

    private func attachmentDetectionCard() -> SettingsCard {
        let runtimeRows = AgentKind.allCases.compactMap { kind -> NSView? in
            guard let toggle = attachmentDetectionToggles[kind] else { return nil }
            return SettingsUI.row(
                title: "Detect attachments from \(kind.displayName)",
                subtitle: "Scans \(kind.displayName) output for image, PDF, document, archive, "
                    + "and diagram paths. Turn this off if an agent update changes how paths "
                    + "are rendered.",
                control: toggle
            )
        }
        return SettingsCard(rows: runtimeRows + [
            SettingsUI.row(
                title: "Include files outside the project",
                subtitle: "Detected paths are normally kept to the session's own project, because "
                    + "a paired phone can fetch anything in the list and printed text is not a "
                    + "handoff. Turn this on to list them wherever they are; Threading copies "
                    + "each one in. Images you attach or the agent shows are never affected.",
                control: outsideProjectAttachmentToggle
            ),
            SettingsUI.row(
                title: "Keep the page as it was before each agent action",
                subtitle: "Lets an agent ask what its own click changed, by comparing the page "
                    + "with a picture taken just before it. The pictures stay in memory for the "
                    + "chat and are never added to your visual baselines. Off by default because "
                    + "every page-changing tool call then costs a screenshot. It covers the "
                    + "agent's own actions only, not your clicks or a page updating itself.",
                control: beforeActionCaptureToggle
            )
        ])
    }

    /// Standing context for a new conversation, kept visibly separate from the task composed
    /// for one chat. Either field empty is that half's off state.
    ///
    /// Two of them because the halves do different work: text before the task sets how the
    /// agent should work on whatever follows, and text after it is an instruction about the
    /// answer — an order the model reads as written, which is why they are separate fields
    /// rather than one message the user has to position by hand.
    private func openingMessageCard() -> SettingsCard {
        SettingsCard(rows: [
            SettingsUI.row(
                title: "Before the task you write",
                subtitle: "Sent once ahead of the task, framing how this chat should be worked on."
            ),
            SettingsUI.fullRow(newChatOpeningPrefixField),
            SettingsUI.row(
                title: "After the task you write",
                subtitle: "Sent once after the task, for a standing instruction about the answer."
            ),
            SettingsUI.fullRow(newChatOpeningSuffixField)
        ])
    }

    /// Claude's own Remote Control bridge — not Threading's Remote Access, which has its own page.
    ///
    /// The wording carries that distinction, because the two are easy to confuse and mean
    /// different things: this one hands the conversation to claude.ai and the Claude mobile app,
    /// and it is Claude's setting that Threading is choosing a default for rather than a switch of
    /// its own. Hence three states — the first defers instead of deciding.
    /// How much a new session may do before it has to ask.
    ///
    /// Both agents, in one vocabulary: Claude states a mode directly, and Codex reaches the same
    /// postures through its approval policy, sandbox, and reviewer. The default defers rather
    /// than deciding — picking a mode here for everyone would override a `permissions.defaultMode` or
    /// `config.toml` the user set themselves, on the one axis where being wrong either nags
    /// them all day or stops asking when it should have.
    private func permissionModeCard() -> SettingsCard {
        SettingsCard(rows: [
            SettingsUI.row(
                title: "New sessions start in",
                subtitle: "How much a session may do before it stops to ask. "
                    + "Following leaves it to the agent's own configuration. "
                    + "A single chat can still be set from its ⋯ menu, "
                    + "and the mode applies from that chat's next launch.",
                control: permissionModePopUp
            )
        ])
    }

    private func claudeRemoteControlCard() -> SettingsCard {
        SettingsCard(rows: [
            SettingsUI.row(
                title: "Remote Control for new Claude sessions",
                subtitle: "Claude's own bridge to claude.ai and the Claude mobile app, "
                    + "separate from Threading's Remote Access. "
                    + "Following leaves it to the account's own /config. "
                    + "A single chat can still be set on or off from its ⋯ menu.",
                control: remoteControlPopUp
            )
        ])
    }

    /// The two Codex hook settings.
    ///
    /// Two switches rather than one, because they are separate decisions and only the second
    /// has a security cost: installing writes entries to a file the user owns, while skipping
    /// review un-gates every hook in that folder rather than only ours.
    private func codexHooksCard() -> SettingsCard {
        SettingsCard(rows: [
            SettingsUI.row(
                title: "Report Codex turn boundaries",
                subtitle: "Adds Threading's entries to each Codex account's hooks.json, "
                    + "so sessions show exact activity instead of guessing from output. "
                    + "Your existing entries are kept.",
                control: codexHookToggle
            ),
            SettingsUI.row(
                title: "Skip Codex hook review",
                subtitle: "Codex will not run a hook until you approve its text once. "
                    + "Skipping that runs every hook in the config folder unreviewed, "
                    + "including any an agent adds later. Leave off and approve once in Codex.",
                control: codexHookTrustToggle
            )
        ])
    }

    /// One row per prompt the register marks suppressible, in declaration order: the four that
    /// were a single "Ask before closing a running session" switch, then the two that joined
    /// them. Both strings are the register's own (`localizes: false`, since they arrive
    /// localized), which is what keeps the row and the "Don't ask again" box describing the
    /// same thing — they were one setting over four prompts, and switching off the one you
    /// meant switched off three you did not.
    private func confirmationRows() -> [NSView] {
        var rows: [NSView] = ConfirmationPrompt.suppressible.compactMap { prompt in
            guard let suppression = prompt.suppression,
                  let toggle = confirmationToggles[prompt] else { return nil }
            return SettingsUI.row(
                title: suppression.settingsTitle,
                subtitle: suppression.settingsSubtitle,
                control: toggle,
                localizes: false
            )
        }
        rows.append(hiddenNoticesRow())
        return rows
    }

    /// The notice register's way back, beside the confirmations because the two boxes read as
    /// one family. One control for all of them rather than a row per hidden message: notice
    /// keys are dynamic — an extension command each — so a hidden receipt whose extension was
    /// removed would be a row with no honest title. Disabled rather than hidden while nothing
    /// is hidden, the same rule the notification refinements follow: a control that vanishes
    /// explains less than one that waits.
    private func hiddenNoticesRow() -> NSView {
        let button = SettingsUI.button(
            "Show All",
            target: self,
            action: #selector(showHiddenNoticesAgain)
        )
        showHiddenNoticesButton = button
        updateHiddenNoticesControl()

        return SettingsUI.row(
            title: "Hidden extension messages",
            subtitle: "An extension command's “done” message offers "
                + "“Don't show this message again”. Show All brings every hidden message back; "
                + "failures always show either way.",
            control: button
        )
    }

    private func updateHiddenNoticesControl() {
        showHiddenNoticesButton?.isEnabled = AppSettings.shared.hiddenNoticeCount > 0
    }

    /// The master switch, then one row per alert kind, then which sound they carry.
    ///
    /// The three kinds are worth separating because they are not equally welcome: being
    /// blocked on an approval is work stopping, while a turn ending in the background is the
    /// chatty one — and someone who wants only the first should not have to choose between
    /// all of it and none of it. Each row's second line is the sentence its banner would say,
    /// so a toggle can be matched to the thing it silences without switching it off to find
    /// out. Both strings are the alert's own (`localizes: false`, since they arrive localized).
    private func notificationRows() -> [NSView] {
        let master = SettingsUI.row(
            title: "Notify when a session needs you",
            subtitle: "A macOS notification when a session is blocked on an approval "
                + "or finishes while you are elsewhere. Banners appear only while "
                + "Threading is in the background; clicking one opens the session.",
            control: attentionNotificationToggle
        )

        let kinds = AttentionAlert.allCases.compactMap { alert -> NSView? in
            guard let toggle = alertToggles[alert] else { return nil }
            return SettingsUI.row(
                title: alert.settingsTitle,
                subtitle: L10n.format("Says “%@”.", alert.body),
                control: toggle,
                localizes: false
            )
        }

        // Which alerts sound is stated rather than implied. The card used to claim only the
        // blocked one ever does, which was never true of an update an agent sends — that path
        // has always carried the same sound, from a place this page did not describe.
        let choice = SettingsUI.row(
            title: "Alert sound",
            subtitle: "What a blocked approval carries, and an update an agent sends you. The "
                + "other alerts stay silent. Picking one plays it. Add a Sound copies a sound "
                + "file into your Sounds folder, where macOS looks for it.",
            control: alertSoundPopUp
        )

        // The per-event tier is a door rather than a control: the card above answers "what do
        // alerts sound like", and this answers "and if one of them should sound different".
        let events = SettingsUI.row(
            title: "Sounds for each alert",
            subtitle: "Give one alert its own sound — or silence one — without changing the "
                + "rest. The same sheet a chat or a checkout opens, at the app's own scope.",
            control: SettingsUI.button(
                "Customize Events…",
                target: self,
                action: #selector(customizeAppSounds)
            )
        )

        return [master] + kinds + [choice, events]
    }

    // MARK: - Opening Message

    private func scheduleOpeningMessageWrite(for field: ThemedTextField) {
        if let unsettled = unsettledOpeningMessageField, unsettled !== field {
            flushOpeningMessageWrite()
        }
        unsettledOpeningMessageField = field
        openingMessageWriteTimer?.invalidate()
        openingMessageWriteTimer = Timer.scheduledTimer(
            withTimeInterval: GeneralPreferencesDefaults.textSettingCoalescingInterval,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.flushOpeningMessageWrite() }
        }
    }

    private func flushOpeningMessageWrite() {
        openingMessageWriteTimer?.invalidate()
        openingMessageWriteTimer = nil
        guard let field = unsettledOpeningMessageField else { return }
        unsettledOpeningMessageField = nil
        let typed = field.stringValue
        if field === newChatOpeningPrefixField {
            guard AppSettings.shared.newChatOpeningPrefix != typed else { return }
            AppSettings.shared.newChatOpeningPrefix = typed
        } else {
            guard AppSettings.shared.newChatOpeningSuffix != typed else { return }
            AppSettings.shared.newChatOpeningSuffix = typed
        }
    }

    // MARK: - Alert Sound

    private func configureAlertSoundPopUp() {
        alertSoundPopUp.target = self
        alertSoundPopUp.action = #selector(alertSoundChoiceChanged)
        alertSoundPopUp.translatesAutoresizingMaskIntoConstraints = false
        alertSoundPopUp.widthAnchor
            .constraint(equalToConstant: SettingsUIDefaults.controlWidth).isActive = true
        alertSoundPopUp.setAccessibilityIdentifier("settings.general.alert-sound")
        rebuildAlertSoundMenu()
    }

    /// The menu is rebuilt rather than updated, because what it lists is a folder: a sound
    /// added, renamed or deleted between two visits to this page must not leave an item behind
    /// that resolves to nothing at delivery time.
    ///
    /// Five groups, in the order the list is read: Off, the system default, the handful worth
    /// suggesting, the rest of what macOS ships, and the user's own. `NotificationSoundLibrary`
    /// decides which is which; the page only draws the separators.
    ///
    /// Off is where the retired "Play a sound" checkbox went. Silence is one of the answers the
    /// question has, so it belongs among the answers rather than in a second control above them
    /// — the same shape the bell's picker has had from the start.
    private func rebuildAlertSoundMenu() {
        alertSoundPopUp.removeAllItems()

        for (title, value) in [
            (L10n.string("Off"), SoundChoice.silent),
            (L10n.string("macOS Alert Sound"), SoundChoice.system)
        ] {
            alertSoundPopUp.addItem(ThemedMenuItem(title: title, representedValue: value))
        }

        let indexOfSound = SoundPickerMenu.addSounds(to: alertSoundPopUp) {
            SoundChoice.named($0)
        }

        SoundPickerMenu.addCustomSoundItem(to: alertSoundPopUp) { [weak self] in
            // Choosing an item moves the selection onto it, and this one is a door rather
            // than a choice. Put the control back before the panel opens over the page:
            // nothing has been chosen yet, and the row would otherwise read as if it had.
            self?.rebuildAlertSoundMenu()
            self?.addAlertSound()
        }

        // A stored name whose file has gone shows as the default, because that is what it will
        // sound like: `SoundChoice.notificationSound()` falls back the same way, and a picker
        // naming a sound nobody will hear would be the one lie on the page.
        switch AppSettings.shared.attentionAlertSound {
        case .silent:
            alertSoundPopUp.selectItem(at: 0)
        case .system:
            alertSoundPopUp.selectItem(at: 1)
        case .named(let fileName):
            alertSoundPopUp.selectItem(at: indexOfSound[fileName] ?? 1)
        }
    }

    /// Copies a chosen file into `~/Library/Sounds` and selects it.
    ///
    /// Choosing this item moves the pop-up's selection onto it, so every path back through here
    /// rebuilds the menu: cancelling has to put the previous choice back on the control.
    private func addAlertSound() {
        SoundPickerMenu.addCustomSound { [weak self] sound in
            guard let self else { return }
            if let sound {
                AppSettings.shared.attentionAlertSound = .named(sound.fileName)
            }
            self.rebuildAlertSoundMenu()
            if let sound { NotificationSoundPreview.play(sound) }
        }
    }

    // MARK: - Terminal Bell

    /// The bell is its own card rather than another row under Notifications, because it obeys
    /// none of that card's switches.
    ///
    /// A notification is Threading noticing something for you: the master switch, the three
    /// kinds, and a project's mute all get a say in it. A bell is a program writing one byte
    /// down the PTY, and nothing above it applies — muting a project does not gag its terminal,
    /// and the bell rings whether or not the session needs you. Filing it under Notifications
    /// would make that card's copy false for the sake of putting two sounds side by side.
    private func terminalBellCard() -> SettingsCard {
        SettingsCard(rows: [
            SettingsUI.row(
                title: "Bell sound",
                subtitle: "What a program's bell does. Picking one plays it. Off still marks "
                    + "the session in the sidebar, so a silenced bell is seen rather than "
                    + "missed.",
                control: bellSoundPopUp
            ),
            SettingsUI.row(
                title: "Sounds for each bell",
                subtitle: "Tell the reasons a bell rings apart: an agent asking while you are "
                    + "away, a bell in the session you are watching, one during a launch, and "
                    + "one from another program.",
                control: SettingsUI.button(
                    "Customize Events…",
                    target: self,
                    action: #selector(customizeAppSounds)
                )
            )
        ])
    }

    private func configureBellSoundPopUp() {
        bellSoundPopUp.target = self
        bellSoundPopUp.action = #selector(bellSoundChanged)
        bellSoundPopUp.translatesAutoresizingMaskIntoConstraints = false
        bellSoundPopUp.widthAnchor
            .constraint(equalToConstant: SettingsUIDefaults.controlWidth).isActive = true
        bellSoundPopUp.setAccessibilityIdentifier("settings.general.bell-sound")
        rebuildBellSoundMenu()
    }

    /// The same list the alert sound offers, in the same order and with the same two answers
    /// above it. What differs is only what `system` means — the alert beep here, the
    /// notification tone there — which is the kind's business rather than the list's.
    private func rebuildBellSoundMenu() {
        bellSoundPopUp.removeAllItems()

        for (title, value) in [
            (L10n.string("Off"), SoundChoice.silent),
            (L10n.string("macOS Alert Sound"), SoundChoice.system)
        ] {
            bellSoundPopUp.addItem(ThemedMenuItem(title: title, representedValue: value))
        }

        let indexOfSound = SoundPickerMenu.addSounds(to: bellSoundPopUp) {
            SoundChoice.named($0)
        }

        SoundPickerMenu.addCustomSoundItem(to: bellSoundPopUp) { [weak self] in
            self?.rebuildBellSoundMenu()
            self?.addBellSound()
        }

        switch AppSettings.shared.terminalBellSound {
        case .silent:
            bellSoundPopUp.selectItem(at: 0)
        case .system:
            bellSoundPopUp.selectItem(at: 1)
        case .named(let fileName):
            // Falls back to the system alert for the same reason `TerminalBell` does: a name
            // whose file has gone still rings, and the picker has to say which sound that is.
            bellSoundPopUp.selectItem(at: indexOfSound[fileName] ?? 1)
        }
    }

    private func addBellSound() {
        SoundPickerMenu.addCustomSound { [weak self] sound in
            guard let self else { return }
            if let sound {
                AppSettings.shared.terminalBellSound = .named(sound.fileName)
            }
            self.rebuildBellSoundMenu()
            if let sound { TerminalBell.play(.named(sound.fileName)) }
        }
    }

    // MARK: - Silence

    /// The global silence gate, in its own section **after** both sound cards rather than inside
    /// either of them.
    ///
    /// It has to read as covering both, and neither card could carry it honestly: the
    /// Notifications card's copy is about Threading noticing something on your behalf, and the
    /// bell sits apart precisely because none of that applies to it. This is app chrome's own
    /// state, mirrored here from the speaker at the sidebar's foot — not a fourth notification
    /// switch — so it says which storage it shares and stays out of both cards' arguments.
    private func silenceCard() -> SettingsCard {
        SettingsCard(rows: [
            SettingsUI.row(
                title: "Silence every sound",
                subtitle: "Holds every sound Threading makes — notification alerts and the "
                    + "terminal bell alike — without changing what either is set to; switching "
                    + "it off gives both back exactly what they had. Nothing is suppressed: "
                    + "banners still arrive and the sidebar still marks the session, quietly. "
                    + "The speaker at the sidebar's foot is the same switch.",
                control: silenceToggle
            )
        ])
    }

    /// One Boolean written from three surfaces, so the row follows the storage rather than its
    /// own clicks: silencing from the footer or the menu while this page is open has to move
    /// the toggle, and refreshing on the way in would leave it stale for as long as the page
    /// stayed put.
    ///
    /// The two sound pickers follow the same storage for the same reason, one surface further
    /// out: the Customize sheet's kind rows **are** these two preferences, so a bell chosen
    /// there has to move the pop-up here rather than leaving the page claiming the old sound.
    private func observeSilenceGate() {
        appEvents.observe(AppSettingsDidChange.self) { [weak self] _ in
            guard let self else { return }
            let state: NSControl.StateValue =
                AppSettings.shared.silencesAllSounds ? .on : .off
            if self.silenceToggle.state != state { self.silenceToggle.state = state }
            self.rebuildAlertSoundMenu()
            self.rebuildBellSoundMenu()
        }
    }

    // MARK: - Custom Sounds

    /// Every record carrying a sound of its own — the answer to "why is this chat making that
    /// noise", and to the same question two weeks after somebody stopped remembering.
    ///
    /// Built from the store on every reading rather than held, so it cannot drift from the
    /// records: a scope that has been reset is simply not in the next reading. The card is
    /// replaced whole because it is a handful of rows by construction — the list is bounded by
    /// what has been *configured*, and `SoundAuditDefaults.visibleLimit` caps even that before
    /// any view is built.
    private func rebuildCustomSoundsCard() {
        customSoundsCard?.removeFromSuperview()

        let entries = SoundOverrideAudit.entries()
        let card = SettingsCard(rows: customSoundsRows(entries))
        card.translatesAutoresizingMaskIntoConstraints = false
        customSoundsHost.addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: customSoundsHost.topAnchor),
            card.bottomAnchor.constraint(equalTo: customSoundsHost.bottomAnchor),
            card.leadingAnchor.constraint(equalTo: customSoundsHost.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: customSoundsHost.trailingAnchor)
        ])
        customSoundsCard = card
    }

    /// One quiet line when nothing overrides anything, which is what a fresh install reads —
    /// the section says so rather than vanishing, because "nothing is overriding" is the answer
    /// somebody came here for as often as a list is.
    private func customSoundsRows(_ entries: [SoundOverrideAudit.Entry]) -> [NSView] {
        guard !entries.isEmpty else {
            return [SettingsUI.row(
                title: "Nothing overrides these sounds",
                subtitle: "A chat, a checkout or a terminal given a sound of its own from its "
                    + "Sounds menu is listed here."
            )]
        }

        var rows: [NSView] = entries
            .prefix(SoundAuditDefaults.visibleLimit)
            .enumerated()
            .map { customSoundsRow($1, index: $0) }

        let hidden = entries.count - rows.count
        if hidden > 0 {
            rows.append(SettingsUI.row(
                title: hidden == 1
                    ? L10n.format("%lld more scope carries a sound", hidden)
                    : L10n.format("%lld more scopes carry a sound", hidden),
                subtitle: "Reset All clears every one of them.",
                localizes: false
            ))
        }

        rows.append(SettingsUI.row(
            title: "Every custom sound",
            subtitle: "Puts every chat, checkout and terminal back to what it inherits. The "
                + "app's own sounds above are untouched.",
            control: SettingsUI.button(
                "Reset All",
                target: self,
                action: #selector(resetAllCustomSounds)
            )
        ))
        return rows
    }

    /// The scope's name over what it is and where, its stored say trailing, and the two things
    /// worth doing to it. The buttons carry the row's index in their tag, so an action maps
    /// straight back to its entry — the pattern the archived list already uses.
    private func customSoundsRow(_ entry: SoundOverrideAudit.Entry, index: Int) -> NSView {
        let open = SettingsUI.button("Customize…", target: self, action: #selector(openCustomSound(_:)))
        open.tag = index

        let reset = SettingsUI.button("Reset", target: self, action: #selector(resetCustomSound(_:)))
        reset.tag = index

        return SettingsUI.row(
            title: entry.name,
            subtitle: L10n.format("%@ · %@", entry.detail, entry.summary),
            control: SettingsUI.controlGroup([open, reset]),
            localizes: false
        )
    }

    @objc private func customizeAppSounds() {
        SoundCustomizeViewController.present(.app, from: self)
    }

    @objc private func openCustomSound(_ sender: ThemedButton) {
        let entries = SoundOverrideAudit.entries()
        guard entries.indices.contains(sender.tag) else { return }
        SoundCustomizeViewController.present(entries[sender.tag].scope, from: self)
    }

    /// Re-read rather than captured: the list is rebuilt from the store on every change, and a
    /// tag captured when the row was built would name a different scope after one reset.
    @objc private func resetCustomSound(_ sender: ThemedButton) {
        let entries = SoundOverrideAudit.entries()
        guard entries.indices.contains(sender.tag) else { return }
        entries[sender.tag].scope.resetAll()
        rebuildCustomSoundsCard()
    }

    @objc private func resetAllCustomSounds() {
        for entry in SoundOverrideAudit.entries() { entry.scope.resetAll() }
        rebuildCustomSoundsCard()
    }

    /// Claude's observational hooks are session-local and independent from Native permission
    /// brokering. That distinction makes this a real off switch without breaking approval cards.
    /// One switch is the authority for both kinds of passive release traffic. What each check
    /// reveals is on the Privacy page; this row states what happens after either one finds news.
    private func updatesCard() -> SettingsCard {
        SettingsCard(rows: [
            SettingsUI.row(
                title: "Check for updates automatically",
                subtitle: "Once a day, Threading checks GitHub for the app and each installed "
                    + "agent's official release source. App updates use Sparkle after you "
                    + "agree; agent updates run in a visible terminal only when you choose "
                    + "Update. Off stops both background checks — Help ▸ Check for Updates… "
                    + "still checks the app.",
                control: automaticUpdateToggle
            )
        ])
    }

    private func claudeHooksCard() -> SettingsCard {
        SettingsCard(rows: [
            SettingsUI.row(
                title: "Report Claude turn and subagent activity",
                subtitle: "Uses a session-only settings file and never edits your Claude "
                    + "configuration. Off removes Threading's lifecycle hooks from Terminal; "
                    + "Native permission prompts keep working. Applies on the next start or resume.",
                control: claudeHookToggle
            ),
            SettingsUI.row(
                title: "Hide Claude's status line in Threading terminals",
                subtitle: "Threading's status card and usage pill already show the model, "
                    + "effort, branch and rate limits, so the line under the composer mostly "
                    + "repeats them. This hides it in sessions Threading launches — your own "
                    + "terminals keep it — while your status-line command still runs with its "
                    + "output discarded, so anything it feeds (like a usage cache) keeps "
                    + "working. Applies on the next start or resume.",
                control: statusLineToggle
            )
        ])
    }

    /// Where the scratchpad's folder is, and the two ways to move it.
    private func scratchpadRow() -> NSView {
        let label = NSTextField(labelWithString: L10n.string("Folder"))
        label.applyFont(.body)
        label.textColor = Design.Text.label
        label.setContentHuggingPriority(.required, for: .horizontal)

        scratchpadFolderLabel.applyFont(.body)
        scratchpadFolderLabel.textColor = Design.Text.secondary
        scratchpadFolderLabel.lineBreakMode = .byTruncatingMiddle
        scratchpadFolderLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        scratchpadFolderLabel.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )

        let choose = SettingsUI.button(
            "Choose…",
            target: self,
            action: #selector(browseForScratchpadFolder)
        )

        let row = NSStackView(views: [
            label,
            scratchpadFolderLabel,
            choose,
            scratchpadDefaultButton
        ])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Design.Spacing.medium
        updateScratchpadFolder()
        return row
    }

    /// The shell field with its Choose button, filling the row.
    private func shellRow() -> NSView {
        let label = NSTextField(labelWithString: L10n.string("Shell path"))
        label.applyFont(.body)
        label.textColor = Design.Text.label
        label.setContentHuggingPriority(.required, for: .horizontal)

        let choose = SettingsUI.button("Choose…", target: self, action: #selector(browseForShell))

        let row = NSStackView(views: [label, shellField, choose])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Design.Spacing.medium
        shellField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }

    // MARK: - Actions

    /// Rebuilds the shared default in the vocabulary of the agent new chats use. The persisted
    /// value stays the same when that agent changes; only Codex needs to qualify Auto with the
    /// automatic reviewer behavior the launch will select.
    private func rebuildPermissionModePopUp(for kind: AgentKind) {
        permissionModePopUp.removeAllItems()
        // The first item inherits — no flag, the agent's own configuration decides — and the
        // six follow. Its represented value is deliberately nil, which is how the handler
        // tells "leave it alone" from a mode.
        permissionModePopUp.addItem(
            ThemedMenuItem(title: L10n.string("Agent's Setting"), representedValue: nil)
        )
        for mode in AgentPermissionMode.allCases {
            permissionModePopUp.addItem(ThemedMenuItem(
                title: mode.displayName(for: kind),
                subtitle: mode.menuDescription(for: kind),
                representedValue: mode
            ))
        }
        permissionModePopUp.selectItem(
            at: AppSettings.shared.defaultPermissionMode
                .flatMap { AgentPermissionMode.allCases.firstIndex(of: $0).map { $0 + 1 } } ?? 0
        )
    }

    @objc private func defaultAgentChanged() {
        guard let kind = defaultAgentPopUp.selectedItem?.representedValue as? AgentKind else { return }
        AppSettings.shared.defaultAgentKind = kind
        rebuildPermissionModePopUp(for: kind)
    }

    @objc private func startupSpeedChanged(_ sender: ThemedPopUp) {
        guard let speed = sender.selectedItem?.representedValue as? AgentStartupSpeed else {
            return
        }

        if sender === claudeStartupSpeedPopUp {
            AppSettings.shared.setStartupSpeed(speed, for: .claude)
        } else if sender === codexStartupSpeedPopUp {
            AppSettings.shared.setStartupSpeed(speed, for: .codex)
        }
    }

    @objc private func restoreSessionChanged() {
        AppSettings.shared.restoresLastSession = restoreSessionToggle.state == .on
    }

    @objc private func restorePolicyChanged() {
        guard let value = restorePolicyPopUp.selectedItem?.representedValue
            as? SessionRestorePolicy else { return }
        AppSettings.shared.sessionRestorePolicy = value
        updateRestoreRefinements()
    }

    @objc private func restoreWindowChanged() {
        guard let days = restoreWindowPopUp.selectedItem?.representedValue as? Int else { return }
        AppSettings.shared.sessionRestoreWindowDays = days
    }

    @objc private func restoreLimitChanged() {
        guard let limit = restoreLimitPopUp.selectedItem?.representedValue as? Int else { return }
        AppSettings.shared.sessionRestoreLimit = limit
    }

    @objc private func confirmationChanged(_ sender: ThemedToggle) {
        guard let prompt = confirmationToggles.first(where: { $0.value === sender })?.key else { return }
        AppSettings.shared.setAsks(sender.state == .on, before: prompt)
    }

    @objc private func showHiddenNoticesAgain() {
        AppSettings.shared.showAllNoticesAgain()
        updateHiddenNoticesControl()
    }

    @objc private func automaticUpdateChecksChanged() {
        // The setter posts the settings notification both update coordinators observe. That is
        // what stops their scheduled checks; this view reaches into neither implementation.
        AppSettings.shared.automaticUpdateChecksEnabled = automaticUpdateToggle.state == .on
    }

    @objc private func preventIdleSleepChanged() {
        AppSettings.shared.preventsIdleSystemSleepWhileAgentsWork =
            preventIdleSleepToggle.state == .on
    }

    @objc private func attentionNotificationChanged() {
        // The setter's own settings notification is what makes the alert center withdraw
        // everything already delivered when this switches off.
        AppSettings.shared.notifiesOnAttention = attentionNotificationToggle.state == .on
        updateNotificationRefinements()
    }

    @objc private func alertKindChanged(_ sender: ThemedToggle) {
        guard let alert = alertToggles.first(where: { $0.value === sender })?.key else { return }
        AppSettings.shared.setNotifies(sender.state == .on, on: alert)
        updateNotificationRefinements()
    }

    /// Choosing a sound also plays it, the way every alert-sound list does: a name is not a
    /// sound, and switching to one and then waiting for the next blocked turn to find out what
    /// it does is not choosing.
    ///
    /// Two items are the exception and stay silent. macOS's notification tone lives inside a
    /// private framework rather than in the folders a name resolves in, and the one sound that
    /// *is* reachable — the system beep — is the alert sound, a different sound entirely;
    /// playing that here would be a preview of the wrong thing. Off previews as silence, which
    /// is the honest answer.
    @objc private func alertSoundChoiceChanged() {
        guard let choice = alertSoundPopUp.selectedItem?.representedValue as? SoundChoice
        else { return }
        AppSettings.shared.attentionAlertSound = choice
        guard case .named(let fileName) = choice,
              let sound = NotificationSoundLibrary.resolve(fileName: fileName) else { return }
        NotificationSoundPreview.play(sound)
    }

    /// Same contract as the alert sound's picker, and one difference: the bell *can* preview
    /// its default, because the system alert sound is a sound this app can ask for. Off
    /// previews as silence, which is the honest answer.
    @objc private func bellSoundChanged() {
        guard let choice = bellSoundPopUp.selectedItem?.representedValue as? SoundChoice
        else { return }
        AppSettings.shared.terminalBellSound = choice
        TerminalBell.play(choice)
    }

    /// Writes the same Boolean the footer's speaker and the menu item write, and nothing else:
    /// the gate stores no choice of its own, so both pickers above keep whatever they were set
    /// to while it holds.
    @objc private func silenceChanged() {
        AppSettings.shared.silencesAllSounds = silenceToggle.state == .on
    }

    /// The kind rows refine the master switch and the sound refines the blocked row, so each
    /// waits on what it refines — disabled rather than hidden, the same rule the lone-branch
    /// heading and the Codex hook-trust rows already follow: a control that vanishes explains
    /// less than one that waits.
    private func updateNotificationRefinements() {
        let notifies = attentionNotificationToggle.state == .on
        for toggle in alertToggles.values { toggle.isEnabled = notifies }
        // Which sound is a question only a page that is going to play one can answer.
        alertSoundPopUp.isEnabled = notifies && alertToggles[.blocked]?.state == .on
    }

    @objc private func terminalTitleChanged() {
        AppSettings.shared.usesAgentTitleInSidebar = terminalTitleToggle.state == .on
        NotificationCenter.default.post(ProjectsDidChange())
    }

    @objc private func projectIconChanged() {
        AppSettings.shared.discoversProjectIcons = projectIconToggle.state == .on
        // Sweeps immediately, so switching this on does not wait for a relaunch.
        ProjectIconDiscovery.shared.retryAll()
    }

    @objc private func accountAvatarChanged() {
        AppSettings.shared.discoversAccountAvatars = accountAvatarToggle.state == .on
        // Forgotten attempts plus a sidebar rebuild, so re-enabling acts immediately —
        // rows re-prime lookups as they reconfigure.
        AccountAvatarStore.retryAll()
        NotificationCenter.default.post(ProjectsDidChange())
    }

    @objc private func attachmentDetectionChanged(_ sender: ThemedToggle) {
        guard let kind = attachmentDetectionToggles.first(where: { $0.value === sender })?.key
        else { return }
        AppSettings.shared.setAttachmentReferenceDetection(
            for: kind,
            enabled: sender.state == .on
        )
    }

    /// Widening this hides nothing that was already listed and reveals what each open pane
    /// refused, which those panes do for themselves: every one of them refreshes on
    /// `AppSettingsDidChange`, and the store's read gate answers the rest.
    @objc private func outsideProjectAttachmentsChanged() {
        AppSettings.shared.includesAttachmentsOutsideProject =
            outsideProjectAttachmentToggle.state == .on
    }

    @objc private func beforeActionCaptureChanged() {
        AppSettings.shared.capturesPageBeforeAgentActions = beforeActionCaptureToggle.state == .on
    }

    @objc private func branchGroupingChanged() {
        AppSettings.shared.groupsSessionsByBranch = branchGroupingToggle.state == .on
        // The sidebar rebuilds its tree on this, which is what adds or removes the level.
        NotificationCenter.default.post(ProjectsDidChange())
    }

    @objc private func compactTreeChanged() {
        // No extra post: density changes no node, and the setter's own settings event is what
        // the sidebar re-lays out on. See `ProjectSidebarViewController.applyTreeDensity`.
        AppSettings.shared.compactsSidebarTree = compactTreeToggle.state == .on
    }

    @objc private func branchFollowChanged() {
        // No extra post needed either way: the setter's own settings notification makes
        // `CheckoutBranchFollower` reconcile, and switching on catches every checkout up,
        // which regroups the sidebar through the store where anything actually moved.
        AppSettings.shared.followsCheckoutBranch = branchFollowToggle.state == .on
    }

    /// A running Claude process has already loaded its settings file, so changing this is
    /// intentionally a next-launch choice rather than pretending to detach hooks mid-turn.
    @objc private func claudeHookChanged() {
        AppSettings.shared.reportsClaudeLifecycleEvents = claudeHookToggle.state == .on
    }

    /// Same next-launch rule as the hooks above, for the same reason: the override rides the
    /// per-session settings file a running Claude has already read.
    @objc private func statusLineChanged() {
        AppSettings.shared.suppressesClaudeStatusLine = statusLineToggle.state == .on
    }

    /// Switching off also removes what was installed, rather than leaving inert entries in a
    /// file the user owns — an off switch that leaves its traces behind is not off.
    @objc private func codexHookChanged() {
        let isOn = codexHookToggle.state == .on
        AppSettings.shared.installsCodexHooks = isOn
        codexHookTrustToggle.isEnabled = isOn

        for account in AgentAccountDiscovery.accounts(for: .codex) {
            if isOn {
                CodexHookInstaller.install(inCodexHome: account.configPath)
            } else {
                CodexHookInstaller.uninstall(fromCodexHome: account.configPath)
            }
        }
    }

    /// Takes effect on the next launch of each session that has not chosen for itself: the value
    /// is read when the settings file is written, so a running conversation keeps whatever it
    /// connected with until it is relaunched.
    @objc private func remoteControlChanged() {
        guard let value = remoteControlPopUp.selectedItem?.representedValue
            as? ClaudeRemoteControl else { return }
        AppSettings.shared.claudeRemoteControl = value
    }

    /// Applies to sessions started from here on, and to existing ones only where they have made
    /// no choice of their own — and then from their next launch, since the mode is stated in the
    /// flags of the process it configures.
    ///
    /// Nil is the first item rather than a missing selection: reading it as "not a mode" is what
    /// lets the default go back to deferring after a mode has been picked.
    @objc private func permissionModeChanged() {
        AppSettings.shared.defaultPermissionMode = permissionModePopUp.selectedItem?
            .representedValue as? AgentPermissionMode
    }

    @objc private func codexHookTrustChanged() {
        AppSettings.shared.bypassesCodexHookTrust = codexHookTrustToggle.state == .on
    }

    @objc private func shellPathChanged() {
        var profile = ProfileStorage.shared.defaultProfile
        profile.shellPath = shellField.stringValue
        ProfileStorage.shared.defaultProfile = profile
    }

    /// Restates the path and whether there is anything to reset to.
    private func updateScratchpadFolder() {
        scratchpadFolderLabel.stringValue =
            (ScratchpadWorkspace.folderURL.path as NSString).abbreviatingWithTildeInPath
        scratchpadDefaultButton.isEnabled = ScratchpadWorkspace.configuredFolderURL != nil
    }

    /// Picks the folder the scratchpad should sit **in**, not the scratchpad itself.
    ///
    /// The distinction is load-bearing: an open panel returns the directory the user selected,
    /// so choosing their home folder would make the home folder the scratchpad — and the first
    /// thing this feature does to a scratchpad is `git init` it. Appending the name keeps the
    /// result the same shape as the default, and keeps the worst outcome unreachable.
    @objc private func browseForScratchpadFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = ScratchpadWorkspace.folderURL.deletingLastPathComponent()
        panel.message = L10n.string("Choose the folder to keep the scratchpad in.")
        panel.prompt = L10n.string("Choose")

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.moveScratchpad(
                to: url.appendingPathComponent(
                    ScratchpadDefaults.folderName,
                    isDirectory: true
                )
            )
        }
    }

    @objc private func useDefaultScratchpadFolder() {
        moveScratchpad(to: nil)
    }

    /// Moves the folder and re-points the row at it. Nil means back to the default.
    ///
    /// The sidebar row keeps its identity across the move — it is flagged, not matched by
    /// path — so the chats in it survive being relocated, which is the whole reason the flag
    /// is stored rather than derived.
    private func moveScratchpad(to destination: URL?) {
        do {
            let folderURL = try ScratchpadWorkspace.relocate(to: destination)
            if ProjectStore.shared.scratchpadProject != nil {
                ProjectStore.shared.ensureScratchpadProject(at: folderURL)
            }
            updateScratchpadFolder()
        } catch {
            let alert = ThemedAlert()
            alert.alertStyle = .warning
            alert.messageText = L10n.string("The scratchpad could not be moved")
            alert.informativeText =
                (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            if let window = view.window {
                alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
        }
    }

    @objc private func browseForShell() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: GeneralPreferencesDefaults.shellBrowseDirectory)
        panel.message = "Select a shell executable"

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.shellField.stringValue = url.path
            self.shellPathChanged()
        }
    }
}

extension GeneralPreferencesViewController: NSTextFieldDelegate {
    /// Coalesced, because writing this setting is not free: every write posts
    /// `AppSettingsDidChange`, and its observers re-read each project's git control files,
    /// re-scan the three sound directories twice, and diff a snapshot of every session. That is
    /// several milliseconds of filesystem work per *character* — measured at ~2 ms of git reads
    /// alone across ten projects — for a value nothing reads until the next chat is created.
    ///
    /// Coalescing here rather than in the descriptor: a toggle or a pop-up is a settled choice
    /// the moment it is made and must still broadcast at once. Only free text arrives one
    /// keystroke at a time, and it means nothing until it stops.
    func controlTextDidChange(_ notification: Notification) {
        guard let field = openingMessageField(notification.object) else { return }
        scheduleOpeningMessageWrite(for: field)
    }

    /// A field that is left settles the setting immediately; so does leaving the page. Between
    /// them, no path out of this row can lose what was typed into it.
    func controlTextDidEndEditing(_ notification: Notification) {
        guard openingMessageField(notification.object) != nil else { return }
        flushOpeningMessageWrite()
    }

    private func openingMessageField(_ object: Any?) -> ThemedTextField? {
        guard let field = object as? ThemedTextField,
              field === newChatOpeningPrefixField || field === newChatOpeningSuffixField
        else { return nil }
        return field
    }
}

// MARK: - General Preferences Defaults

enum GeneralPreferencesDefaults {
    static let shellBrowseDirectory = "/bin"
    /// Long enough that an ordinary sentence is one write, short enough that a page closed by
    /// ⌘W a moment after the last character has already settled without needing the flush.
    static let textSettingCoalescingInterval: TimeInterval = 0.4
}

import AppKit

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
    private let alertSoundToggle = ThemedToggle()
    private let claudeHookToggle = ThemedToggle()
    private let statusLineToggle = ThemedToggle()
    private let codexHookToggle = ThemedToggle()
    private let codexHookTrustToggle = ThemedToggle()
    private let remoteControlPopUp = ThemedPopUp()
    private let permissionModePopUp = ThemedPopUp()
    private let shellField = ThemedTextField()
    private let newChatOpeningMessageField = ThemedTextField()

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
        setupControls()
        setupLayout()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // The page is cached across visits and messages are hidden from alerts elsewhere, so
        // the count is re-read on the way in rather than showing the last visit's state.
        updateHiddenNoticesControl()
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
        for (alert, toggle) in alertToggles {
            configure(toggle,
                      isOn: AppSettings.shared.notifies(on: alert),
                      action: #selector(alertKindChanged))
        }
        configure(alertSoundToggle,
                  isOn: AppSettings.shared.playsAttentionAlertSound,
                  action: #selector(alertSoundChanged))
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
        // The first item inherits — no flag, the agent's own configuration decides — and the
        // six follow. Its represented value is deliberately nil, which is how the handler
        // tells "leave it alone" from a mode.
        permissionModePopUp.addItem(
            ThemedMenuItem(title: L10n.string("Agent's Setting"), representedValue: nil)
        )
        for mode in AgentPermissionMode.allCases {
            permissionModePopUp.addItem(
                ThemedMenuItem(
                    title: mode.displayName,
                    subtitle: mode.menuDescription,
                    representedValue: mode
                )
            )
        }
        permissionModePopUp.selectItem(
            at: AppSettings.shared.defaultPermissionMode
                .flatMap { AgentPermissionMode.allCases.firstIndex(of: $0).map { $0 + 1 } } ?? 0
        )
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

        newChatOpeningMessageField.placeholderString = L10n.string(
            "For example: Rename this chat to a ONE-WORD, ALL-CAPS name that represents it."
        )
        newChatOpeningMessageField.stringValue = AppSettings.shared.newChatOpeningMessage
        newChatOpeningMessageField.setAccessibilityIdentifier(
            "settings.general.new-chat-opening-message"
        )
        newChatOpeningMessageField.delegate = self
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

        let page = SettingsUI.page(title: "General", sections: [
            SettingsUI.section("Sessions", sessions),
            SettingsUI.section("Conversation Speed", conversationSpeedCard()),
            SettingsUI.section("Opening Message", openingMessageCard()),
            SettingsUI.section("Attachments", attachmentDetectionCard()),
            SettingsUI.section("Startup", startup),
            SettingsUI.section("Confirmations", confirmations),
            SettingsUI.note("Only interruptions you can safely stop are listed. Anything that deletes something "
                + "for good, or grants access to a website, a tool, an extension or another person, "
                + "always asks."),
            SettingsUI.section("Notifications", notifications),
            SettingsUI.section("Permission Mode", permissionModeCard()),
            SettingsUI.section("Claude Remote Control", claudeRemoteControlCard()),
            SettingsUI.section("Claude Hooks", claudeHooksCard()),
            SettingsUI.section("Codex Hooks", codexHooksCard()),
            SettingsUI.section("Software Updates", updatesCard()),
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
    /// for one chat. Empty is the off state.
    private func openingMessageCard() -> SettingsCard {
        SettingsCard(rows: [
            SettingsUI.row(
                title: "Add to every new chat",
                subtitle: "Appended once after the task you write. "
                    + "It is not sent again when an existing chat resumes."
            ),
            SettingsUI.fullRow(newChatOpeningMessageField)
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
    /// postures through its approval policy and sandbox. The default defers rather than deciding
    /// — picking a mode here for everyone would override a `permissions.defaultMode` or
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

    /// The master switch, then one row per alert kind, then the sound.
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

        let sound = SettingsUI.row(
            title: "Play a sound",
            subtitle: "Only the blocked alert ever sounds — the other two are silent "
                + "either way. Off shows it without the ping.",
            control: alertSoundToggle
        )

        return [master] + kinds + [sound]
    }

    /// Claude's observational hooks are session-local and independent from Native permission
    /// brokering. That distinction makes this a real off switch without breaking approval cards.
    /// Named rather than described vaguely: Sparkle is the framework doing the checking, and an
    /// app that talks to a release feed should say who it talks through. What the check reveals
    /// is on the Privacy page; this row is the switch.
    private func updatesCard() -> SettingsCard {
        SettingsCard(rows: [
            SettingsUI.row(
                title: "Check for updates automatically",
                subtitle: "Once a day, Threading asks its release feed on GitHub whether a "
                    + "newer version exists. Updates are installed by Sparkle, and only after "
                    + "you agree to each one. Off, nothing is asked — Help ▸ Check for "
                    + "Updates… still works.",
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

    @objc private func defaultAgentChanged() {
        guard let kind = defaultAgentPopUp.selectedItem?.representedValue as? AgentKind else { return }
        AppSettings.shared.defaultAgentKind = kind
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
        // The setter posts the settings notification `AppUpdater` observes, which is what stops
        // the scheduled check rather than anything here reaching into Sparkle.
        AppSettings.shared.automaticUpdateChecksEnabled = automaticUpdateToggle.state == .on
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

    @objc private func alertSoundChanged() {
        AppSettings.shared.playsAttentionAlertSound = alertSoundToggle.state == .on
    }

    /// The kind rows refine the master switch and the sound refines the blocked row, so each
    /// waits on what it refines — disabled rather than hidden, the same rule the lone-branch
    /// heading and the Codex hook-trust rows already follow: a control that vanishes explains
    /// less than one that waits.
    private func updateNotificationRefinements() {
        let notifies = attentionNotificationToggle.state == .on
        for toggle in alertToggles.values { toggle.isEnabled = notifies }
        alertSoundToggle.isEnabled = notifies && alertToggles[.blocked]?.state == .on
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
    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSTextField === newChatOpeningMessageField else { return }
        AppSettings.shared.newChatOpeningMessage = newChatOpeningMessageField.stringValue
    }
}

// MARK: - General Preferences Defaults

enum GeneralPreferencesDefaults {
    static let shellBrowseDirectory = "/bin"
}

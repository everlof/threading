import AppKit
import UniformTypeIdentifiers

/// General preferences: how the app itself behaves — what comes back at launch, how long idle
/// agents keep running, which interruptions ask first, updates, and this Mac.
///
/// General used to be every setting without a better home: the sidebar, new-chat defaults,
/// every sound, and each provider's hooks, twenty-two captions deep. Those now have pages of
/// their own (Sidebar, Chats, Notifications, Integration), and a row belongs here only when it
/// is about the application rather than about one of those subjects. Extensions still
/// contribute to this page through `ExtensionHostSettingsPage.general`.
final class GeneralPreferencesViewController: NSViewController {

    let agentTools = AgentCLISettingsViewController()

    // MARK: - Controls

    private let restoreSessionToggle = ThemedToggle()
    private let restorePolicyPopUp = ThemedPopUp()
    private let restoreWindowPopUp = ThemedPopUp()
    private let restoreLimitPopUp = ThemedPopUp()
    private let automaticUpdateToggle = ThemedToggle()
    private let updateChannelPopUp = ThemedPopUp()
    private let preventIdleSleepToggle = ThemedToggle()
    private let shellField = ThemedTextField()

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
        configure(restoreSessionToggle, isOn: AppSettings.shared.restoresLastSession, action: #selector(restoreSessionChanged))
        configureRestoreControls()
        for (prompt, toggle) in confirmationToggles {
            configure(toggle,
                      isOn: AppSettings.shared.asks(before: prompt),
                      action: #selector(confirmationChanged))
        }
        configure(automaticUpdateToggle,
                  isOn: AppSettings.shared.automaticUpdateChecksEnabled,
                  action: #selector(automaticUpdateChecksChanged))
        configureUpdateChannelPopUp()
        configure(
            preventIdleSleepToggle,
            isOn: AppSettings.shared.preventsIdleSystemSleepWhileAgentsWork,
            action: #selector(preventIdleSleepChanged)
        )
        preventIdleSleepToggle.setAccessibilityIdentifier(
            "settings.general.prevent-idle-system-sleep"
        )

        shellField.applyFont(.body)
        shellField.placeholderString = TerminalDefaults.defaultShell
        shellField.stringValue = ProfileStorage.shared.defaultProfile.shellPath
        shellField.target = self
        shellField.action = #selector(shellPathChanged)
        SettingsUI.preferControlWidth(shellField)
    }

    private func configure(_ toggle: ThemedToggle, isOn: Bool, action: Selector) {
        toggle.state = isOn ? .on : .off
        toggle.target = self
        toggle.action = action
    }

    /// Which builds this person is willing to receive.
    ///
    /// The selection resolves through `AppSettings`, which falls back to the running build's own
    /// channel rather than to a constant: a beta handed to a friend must default to the beta
    /// subscription or every beta item is filtered away and their build never updates again.
    private func configureUpdateChannelPopUp() {
        for subscription in UpdateChannelSubscription.allCases {
            updateChannelPopUp.addItem(
                ThemedMenuItem(title: subscription.settingsTitle, representedValue: subscription)
            )
        }
        updateChannelPopUp.selectItem(
            at: UpdateChannelSubscription.allCases.firstIndex(
                of: AppSettings.shared.updateChannelSubscription
            ) ?? 0
        )
        updateChannelPopUp.target = self
        updateChannelPopUp.action = #selector(updateChannelChanged)
        updateChannelPopUp.setAccessibilityIdentifier("settings.general.update-channel")
        SettingsUI.preferControlWidth(updateChannelPopUp)
    }

    /// The launch choice and the two process-retention controls.
    ///
    /// The window and the limit are pop-ups rather than fields because both bound live agent
    /// processes as well as startup: the range belongs to the product, not to whatever somebody
    /// can type. See `SessionRestoreDefaults`.
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
    }

    private func configureRestorePopUp(
        _ popUp: ThemedPopUp,
        action: Selector,
        accessibilityIdentifier: String
    ) {
        popUp.target = self
        popUp.action = action
        popUp.setAccessibilityIdentifier(accessibilityIdentifier)
        SettingsUI.preferControlWidth(popUp)
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
        let startup = SettingsCard(rows: [
            SettingsUI.row(title: "Reopen the last session at launch", control: restoreSessionToggle),
            SettingsUI.row(
                title: "Bring back at launch",
                subtitle: "Which sessions are running again when Threading opens.",
                help: SettingsUI.help(
                    "Bring back at launch",
                    "Sessions resume in the background, one at a time, and are already running "
                        + "when you open them. Everything else stays dormant and resumes when you "
                        + "open it."
                ),
                control: restorePolicyPopUp
            )
        ])

        let idleAgents = SettingsCard(rows: [
            SettingsUI.row(
                title: "Stop idle agents after",
                subtitle: "Counted from your latest turn or visit.",
                help: SettingsUI.help(
                    "Stop idle agents after",
                    "Counts from the latest submitted turn or local view. Opening a dormant "
                        + "conversation resumes it and refreshes this timer."
                ),
                control: restoreWindowPopUp
            ),
            SettingsUI.row(
                title: "Keep idle agents running",
                subtitle: "The most recently used keep running.",
                help: SettingsUI.help(
                    "Keep idle agents running",
                    "Most recent first. Unfinished, non-resumable, visible, or remotely viewed "
                        + "work is never stopped by this limit."
                ),
                control: restoreLimitPopUp
            )
        ])

        addChild(agentTools)
        let page = SettingsUI.page(title: "General", sections: [
            SettingsUI.section("Startup", startup),
            SettingsUI.section("Idle Agents", idleAgents),
            SettingsUI.section(
                "Confirmations",
                SettingsCard(rows: confirmationRows()),
                help: SettingsUI.help(
                    "Confirmations",
                    "Only interruptions you can safely stop are listed. Anything that deletes "
                        + "something for good, or grants access to a website, a tool, an "
                        + "extension or another person, always asks."
                )
            ),
            SettingsUI.section("Software Updates", updatesCard()),
            SettingsUI.section(nil, agentTools.view),
            SettingsUI.section("This Mac", thisMacCard())
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
            subtitle: "Brings back every message you chose not to see again.",
            help: SettingsUI.help(
                "Hidden extension messages",
                "An extension command's “done” message offers “Don't show this message again”. "
                    + "Show All brings every hidden message back; failures always show either way."
            ),
            control: button
        )
    }

    private func updateHiddenNoticesControl() {
        showHiddenNoticesButton?.isEnabled = AppSettings.shared.hiddenNoticeCount > 0
    }

    /// One switch is the authority for both kinds of passive release traffic. What each check
    /// reveals is on the Privacy page; this row states what happens after either one finds news.
    private func updatesCard() -> SettingsCard {
        SettingsCard(rows: [
            SettingsUI.row(
                title: "Updates you receive",
                subtitle: "Betas arrive earlier and may be rough.",
                help: SettingsUI.help(
                    "Updates you receive",
                    "Stable is the finished release and needs no action. Betas arrive earlier "
                        + "and may be rough; switching back here returns you to stable at the "
                        + "next release.",
                    "Nightly is a separate feed you join by installing a nightly build, and "
                        + "leave by downloading a stable build yourself, because a nightly's date "
                        + "version is higher than any release."
                ),
                control: updateChannelPopUp
            ),
            SettingsUI.row(
                title: "Check for updates automatically",
                subtitle: "Once a day, for the app and each installed agent.",
                help: SettingsUI.help(
                    "Check for updates automatically",
                    "Threading checks GitHub for the app and each installed agent's official "
                        + "release source. App updates use Sparkle after you agree; agent updates "
                        + "run in a visible terminal only when you choose Update.",
                    "Off stops both background checks — Help ▸ Check for Updates… still checks "
                        + "the app."
                ),
                control: automaticUpdateToggle
            )
        ])
    }

    /// The machine the agents run on: whether it may sleep under them, and which shell a shell
    /// session starts.
    private func thisMacCard() -> SettingsCard {
        let choose = SettingsUI.button("Choose…", target: self, action: #selector(browseForShell))
        return SettingsCard(rows: [
            SettingsUI.row(
                title: "Keep this Mac awake while agents work",
                subtitle: "While a turn is running or waiting for your answer.",
                help: SettingsUI.help(
                    "Keep this Mac awake while agents work",
                    "Prevents idle system sleep while an agent turn is active or waiting for "
                        + "your answer. The display may turn off, and closing a MacBook’s lid can "
                        + "still put it to sleep."
                ),
                control: preventIdleSleepToggle
            ),
            SettingsUI.row(
                title: "Shell path",
                subtitle: "For shell sessions. Agents launch through your login shell.",
                control: SettingsUI.controlGroup([shellField, choose])
            )
        ])
    }

    // MARK: - Actions

    @objc private func restoreSessionChanged() {
        AppSettings.shared.restoresLastSession = restoreSessionToggle.state == .on
    }

    @objc private func restorePolicyChanged() {
        guard let value = restorePolicyPopUp.selectedItem?.representedValue
            as? SessionRestorePolicy else { return }
        AppSettings.shared.sessionRestorePolicy = value
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

    @objc private func updateChannelChanged() {
        guard let subscription = updateChannelPopUp.selectedItem?.representedValue
            as? UpdateChannelSubscription else { return }
        // Writing it is the whole effect. Sparkle asks the delegate for `allowedChannels` on each
        // check rather than caching them, so the next check honours this with nothing to restart.
        AppSettings.shared.updateChannelSubscription = subscription
    }

    @objc private func preventIdleSleepChanged() {
        AppSettings.shared.preventsIdleSystemSleepWhileAgentsWork =
            preventIdleSleepToggle.state == .on
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

// MARK: - General Preferences Defaults

enum GeneralPreferencesDefaults {
    static let shellBrowseDirectory = "/bin"
}

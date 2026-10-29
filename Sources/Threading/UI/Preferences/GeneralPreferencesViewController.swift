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
                ThemedMenuItem(title: SessionRestoreDefaults.windowTitle(days: days), representedValue: days)
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
                ThemedMenuItem(title: SessionRestoreDefaults.limitTitle(limit), representedValue: limit)
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

    private func setupLayout() {
        addChild(agentTools)
        let chooseShell = SettingsUI.button(
            "Choose…", target: self, action: #selector(browseForShell)
        )
        let controls = GeneralSettingsPageStructure.Controls(
            startup: .init(restoresSession: restoreSessionToggle, policy: restorePolicyPopUp),
            idleAgents: .init(window: restoreWindowPopUp, limit: restoreLimitPopUp),
            confirmations: confirmationCard(),
            softwareUpdates: .init(channel: updateChannelPopUp,
                                   automaticChecks: automaticUpdateToggle),
            agentTools: agentTools.view,
            machine: .init(preventsIdleSleep: preventIdleSleepToggle,
                           shellPath: SettingsUI.controlGroup([shellField, chooseShell]))
        )
        let sections = GeneralSettingsPageStructure.sections(
            controls: controls,
            machineTitle: "This Mac",
            row: { descriptor, control in
                SettingsUI.row(title: descriptor.title, subtitle: descriptor.subtitle,
                               help: descriptor.help.map(Self.helpTopic), control: control)
            },
            section: { title, help, content in
                SettingsUI.section(title, content, help: help.map(Self.helpTopic))
            }
        )
        let page = SettingsUI.page(title: "General", sections: sections, hostPage: .general)

        page.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(page)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: view.topAnchor),
            page.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            page.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    private static func helpTopic(_ help: GeneralSettingsPageStructure.Help) -> HelpTopic {
        HelpTopic(title: L10n.string(help.title),
                  paragraphs: help.paragraphs.map { L10n.string($0) })
    }

    /// One row per prompt the register marks suppressible, in declaration order: the four that
    /// were a single "Ask before closing a running session" switch, then the two that joined
    /// them. Both strings are the register's own (`localizes: false`, since they arrive
    /// localized), which is what keeps the row and the "Don't ask again" box describing the
    /// same thing — they were one setting over four prompts, and switching off the one you
    /// meant switched off three you did not.
    private func confirmationCard() -> SettingsCard {
        let choices: [SettingsConfirmationCard.Choice] = ConfirmationPrompt.suppressible.compactMap { prompt in
            guard let suppression = prompt.suppression,
                  let toggle = confirmationToggles[prompt] else { return nil }
            return SettingsConfirmationCard.Choice(
                title: suppression.settingsTitle,
                subtitle: suppression.settingsSubtitle,
                control: toggle
            )
        }
        let result = SettingsConfirmationCard.make(
            choices: choices, trailingRows: [hiddenNoticesRow()]
        )
        for (choice, row) in zip(choices, result.choiceRows) {
            SettingsRowAnchor.tag(row, title: choice.title)
        }
        return result.card
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

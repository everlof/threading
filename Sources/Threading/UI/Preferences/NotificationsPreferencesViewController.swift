import AppKit

/// Notifications preferences: which alerts Threading raises, what they and a terminal's bell
/// sound like, the one switch that silences both, and every chat that sounds different.
///
/// Four cards that were a third of General. They share one subject — what Threading makes you
/// hear or see when you are not looking — and none of General's rows touch it.
final class NotificationsPreferencesViewController: NSViewController {

    // MARK: - Controls

    private let attentionNotificationToggle = ThemedToggle()
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
    /// Holds the page's subscriptions for its lifetime.
    private let appEvents = AppEventObservations()
    /// The Custom sounds list's home. Retained so a record gaining or losing an override
    /// replaces one card rather than the whole page — and, transitively, every other section's
    /// controls and their observers.
    private let customSoundsHost = NSView()
    private var customSoundsCard: NSView?

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
        setupControls()
        setupLayout()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // The page is cached across visits, and the Sounds folder is macOS's: a sound can arrive
        // in it from Finder or another app between two visits to this page.
        rebuildAlertSoundMenu()
        rebuildBellSoundMenu()
        // Same reason once more: a record can gain or lose a sound from the sidebar between two
        // visits, and the list is the one surface that must never disagree with the records.
        rebuildCustomSoundsCard()
    }

    // MARK: - Setup

    private func setupControls() {
        configure(attentionNotificationToggle,
                  isOn: AppSettings.shared.notifiesOnAttention,
                  action: #selector(attentionNotificationChanged))
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
        silenceToggle.setAccessibilityIdentifier("settings.notifications.silence-sounds")
        observeSilenceGate()
        customSoundsHost.setAccessibilityIdentifier("settings.notifications.custom-sounds")
        rebuildCustomSoundsCard()
        // Built from the store, so it follows the store: a chat given a sound from its own row
        // while this page is open has to appear here without a revisit.
        appEvents.observe(ProjectsDidChange.self) { [weak self] _ in
            self?.rebuildCustomSoundsCard()
        }
        updateNotificationRefinements()
    }

    private func configure(_ toggle: ThemedToggle, isOn: Bool, action: Selector) {
        toggle.state = isOn ? .on : .off
        toggle.target = self
        toggle.action = action
    }

    private func setupLayout() {
        let page = SettingsUI.page(title: "Notifications", sections: [
            SettingsUI.section("Alerts", SettingsCard(rows: alertRows())),
            SettingsUI.section("Terminal Bell", terminalBellCard()),
            SettingsUI.section("Silence", silenceCard()),
            SettingsUI.section(
                "Custom Sounds",
                customSoundsHost,
                help: SettingsUI.help(
                    "Custom Sounds",
                    "Sounds you add are copied into ~/Library/Sounds, which is macOS's folder "
                        + "rather than Threading's: anything installed there also appears in "
                        + "System Settings' alert-sound list, and removing a file there removes "
                        + "it from both."
                )
            )
        ])

        page.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(page)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: view.topAnchor),
            page.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            page.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    /// The master switch, then one row per alert kind, then which sound they carry.
    ///
    /// The kinds are worth separating because they are not equally welcome: being blocked on an
    /// approval is work stopping, while a turn ending in the background is the chatty one — and
    /// someone who wants only the first should not have to choose between all of it and none of
    /// it. Each row's second line is the sentence its banner would say, so a toggle can be
    /// matched to the thing it silences without switching it off to find out. Both strings are
    /// the alert's own (`localizes: false`, since they arrive localized).
    private func alertRows() -> [NSView] {
        let master = SettingsUI.row(
            title: "Notify when a session needs you",
            subtitle: "When a session is blocked or finishes while you are elsewhere.",
            help: SettingsUI.help(
                "Notify when a session needs you",
                "A macOS notification when a session is blocked on an approval or finishes "
                    + "while you are elsewhere. Banners appear only while Threading is in the "
                    + "background; clicking one opens the session."
            ),
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
            subtitle: "For a blocked approval and an update an agent sends you.",
            help: SettingsUI.help(
                "Alert sound",
                "The other alerts stay silent. Picking one plays it. Add a Sound copies a sound "
                    + "file into your Sounds folder, where macOS looks for it."
            ),
            control: alertSoundPopUp
        )

        // The per-event tier is a door rather than a control: the row above answers "what do
        // alerts sound like", and this answers "and if one of them should sound different".
        let events = SettingsUI.row(
            title: "Sounds for each alert",
            subtitle: "Give one alert its own sound, or silence it.",
            help: SettingsUI.help(
                "Sounds for each alert",
                "Give one alert its own sound — or silence one — without changing the rest. The "
                    + "same sheet a chat or a checkout opens, at the app's own scope."
            ),
            control: SettingsUI.button(
                "Customize Events…",
                target: self,
                action: #selector(customizeAppSounds)
            )
        )

        return [master] + kinds + [choice, events]
    }

    // MARK: - Alert Sound

    private func configureAlertSoundPopUp() {
        alertSoundPopUp.target = self
        alertSoundPopUp.action = #selector(alertSoundChoiceChanged)
        SettingsUI.preferControlWidth(alertSoundPopUp)
        alertSoundPopUp.setAccessibilityIdentifier("settings.notifications.alert-sound")
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

    /// The bell is its own card rather than another row under Alerts, because it obeys none of
    /// that card's switches.
    ///
    /// A notification is Threading noticing something for you: the master switch, the kinds,
    /// and a project's mute all get a say in it. A bell is a program writing one byte down the
    /// PTY, and nothing above it applies — muting a project does not gag its terminal, and the
    /// bell rings whether or not the session needs you. Filing it under Alerts would make that
    /// card's copy false for the sake of putting two sounds side by side.
    private func terminalBellCard() -> SettingsCard {
        SettingsCard(rows: [
            SettingsUI.row(
                title: "Bell sound",
                subtitle: "What a program's bell does. Picking one plays it.",
                help: SettingsUI.help(
                    "Bell sound",
                    "Off still marks the session in the sidebar, so a silenced bell is seen "
                        + "rather than missed."
                ),
                control: bellSoundPopUp
            ),
            SettingsUI.row(
                title: "Sounds for each bell",
                subtitle: "Tell the reasons a bell rings apart.",
                help: SettingsUI.help(
                    "Sounds for each bell",
                    "An agent asking while you are away, a bell in the session you are "
                        + "watching, one during a launch, and one from another program can each "
                        + "sound different."
                ),
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
        SettingsUI.preferControlWidth(bellSoundPopUp)
        bellSoundPopUp.setAccessibilityIdentifier("settings.notifications.bell-sound")
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
    /// It has to read as covering both, and neither card could carry it honestly: the Alerts
    /// card's copy is about Threading noticing something on your behalf, and the bell sits apart
    /// precisely because none of that applies to it. This is app chrome's own state, mirrored
    /// here from the speaker at the sidebar's foot — not another notification switch — so it
    /// says which storage it shares and stays out of both cards' arguments.
    private func silenceCard() -> SettingsCard {
        SettingsCard(rows: [
            SettingsUI.row(
                title: "Silence every sound",
                subtitle: "Holds alerts and the bell without changing what either is set to.",
                help: SettingsUI.help(
                    "Silence every sound",
                    "Switching it off gives both back exactly what they had. Nothing is "
                        + "suppressed: banners still arrive and the sidebar still marks the "
                        + "session, quietly. The speaker at the sidebar's foot is the same switch."
                ),
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
        appEvents.observe(AppSettingsDidChange.self) { [weak self] change in
            guard let self else { return }
            guard change.affects(
                AppSettingIdentity.silencesAllSounds.rawValue,
                AppSettingIdentity.attentionAlertSound.rawValue,
                AppSettingIdentity.terminalBellSound.rawValue,
                AppSettingIdentity.soundEventChoices.rawValue
            ) else { return }
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
                subtitle: L10n.string("Reset All clears every one of them."),
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

    // MARK: - Actions

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
}

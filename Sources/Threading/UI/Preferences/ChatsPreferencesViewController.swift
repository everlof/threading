import AppKit

/// Chats preferences: what a new chat starts as, what it is told first, what Threading lifts out
/// of its output, and where chats about no project live.
///
/// Every row here is a default a chat is *born* with — the agent, how much it may do, its speed,
/// its opening message — or a reading of what it prints. That is the line between this page and
/// General, which holds how the app itself behaves.
final class ChatsPreferencesViewController: NSViewController {

    // MARK: - Controls

    private let defaultAgentPopUp = ThemedPopUp()
    private let permissionModePopUp = ThemedPopUp()
    private let claudeStartupSpeedPopUp = ThemedPopUp()
    private let codexStartupSpeedPopUp = ThemedPopUp()
    /// One path-detection switch per runtime. The scanner setting is keyed by `AgentKind`, so
    /// constructing the page from the same closed set prevents a new runtime from getting a
    /// setting the empty state can name but no row the user can reach.
    private let attachmentDetectionToggles: [AgentKind: ThemedToggle] = Dictionary(
        uniqueKeysWithValues: AgentKind.allCases.map { ($0, ThemedToggle()) }
    )
    private let outsideProjectAttachmentToggle = ThemedToggle()
    private let beforeActionCaptureToggle = ThemedToggle()

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
    private var scratchpadFolderLabel: NSTextField?

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

    // MARK: - Setup

    private func setupControls() {
        for kind in AgentKind.allCases {
            defaultAgentPopUp.addItem(
                ThemedMenuItem(title: kind.displayName, representedValue: kind)
            )
        }
        defaultAgentPopUp.selectItem(
            at: AgentKind.allCases.firstIndex(of: AppSettings.shared.defaultAgentKind) ?? 0
        )
        defaultAgentPopUp.target = self
        defaultAgentPopUp.action = #selector(defaultAgentChanged)
        SettingsUI.preferControlWidth(defaultAgentPopUp)

        rebuildPermissionModePopUp(for: AppSettings.shared.defaultAgentKind)
        permissionModePopUp.target = self
        permissionModePopUp.action = #selector(permissionModeChanged)
        SettingsUI.preferControlWidth(permissionModePopUp)

        configureStartupSpeedPopUp(
            claudeStartupSpeedPopUp,
            kind: .claude,
            accessibilityIdentifier: "settings.chats.claude-startup-speed"
        )
        configureStartupSpeedPopUp(
            codexStartupSpeedPopUp,
            kind: .codex,
            accessibilityIdentifier: "settings.chats.codex-startup-speed"
        )

        for kind in AgentKind.allCases {
            guard let toggle = attachmentDetectionToggles[kind] else { continue }
            configure(
                toggle,
                isOn: AppSettings.shared.detectsAttachmentReferences(for: kind),
                action: #selector(attachmentDetectionChanged(_:))
            )
            toggle.setAccessibilityIdentifier(
                "settings.chats.\(kind.rawValue)-attachment-detection"
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

        newChatOpeningPrefixField.placeholderString =
            L10n.string(OpeningMessageSettingsStructure.prefixPlaceholder)
        newChatOpeningPrefixField.stringValue = AppSettings.shared.newChatOpeningPrefix
        newChatOpeningPrefixField.setAccessibilityIdentifier(
            "settings.chats.new-chat-opening-prefix"
        )
        newChatOpeningPrefixField.delegate = self

        newChatOpeningSuffixField.placeholderString =
            L10n.string(OpeningMessageSettingsStructure.suffixPlaceholder)
        newChatOpeningSuffixField.stringValue = AppSettings.shared.newChatOpeningSuffix
        newChatOpeningSuffixField.setAccessibilityIdentifier(
            "settings.chats.new-chat-opening-suffix"
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
        SettingsUI.preferControlWidth(popUp)
    }

    private func setupLayout() {
        let content = ChatsSettingsPageStructure.Content(
            newChats: newChatsCard(),
            openingMessage: openingMessageCard(),
            attachments: attachmentDetectionCard(),
            scratchpad: SettingsCard(rows: [scratchpadRow()])
        )
        let page = SettingsUI.page(title: "Chats",
            sections: ChatsSettingsPageStructure.sections(content))

        page.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(page)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: view.topAnchor),
            page.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            page.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    /// The four defaults a new chat is launched with.
    ///
    /// Speed is two rows because the providers expose Fast through different wires and their
    /// account settings and availability are separate; both cover Terminal and Native chats, so
    /// the choice does not read as a preference for only the composer beneath it.
    ///
    /// The permission default defers rather than deciding — picking a mode here for everyone
    /// would override a `permissions.defaultMode` or `config.toml` the user set themselves, on
    /// the one axis where being wrong either nags them all day or stops asking when it should.
    private func newChatsCard() -> SettingsCard {
        let controls = NewChatsSettingsStructure.Controls(
            agent: defaultAgentPopUp, permission: permissionModePopUp,
            claudeSpeed: claudeStartupSpeedPopUp, codexSpeed: codexStartupSpeedPopUp)
        return SettingsCard(rows: NewChatsSettingsStructure.rows(controls: controls) { row, control in
            SettingsUI.row(title: row.title, subtitle: row.subtitle,
                help: row.help?.topic, control: control)
        })
    }

    /// Standing context for a new conversation, kept visibly separate from the task composed
    /// for one chat. Either field empty is that half's off state.
    ///
    /// Two of them because the halves do different work: text before the task sets how the
    /// agent should work on whatever follows, and text after it is an instruction about the
    /// answer — an order the model reads as written, which is why they are separate fields
    /// rather than one message the user has to position by hand.
    private func openingMessageCard() -> SettingsCard {
        SettingsCard(rows: OpeningMessageSettingsStructure.rows(
            prefixField: newChatOpeningPrefixField,
            suffixField: newChatOpeningSuffixField,
            makeLabelRow: { SettingsUI.row(title: $0.title, subtitle: $0.subtitle) },
            makeFullRow: SettingsUI.fullRow))
    }

    /// One switch per runtime, named by the runtime alone: what every one of them does is the
    /// same sentence, said once on the section's "?" rather than five times down the card.
    private func attachmentDetectionCard() -> SettingsCard {
        let controls = AttachmentSettingsStructure.Controls(
            detection: attachmentDetectionToggles,
            outsideProject: outsideProjectAttachmentToggle,
            beforeActionCapture: beforeActionCaptureToggle)
        return AttachmentSettingsStructure.card(controls: controls) { row, control in
            SettingsUI.row(title: row.title, subtitle: row.subtitle,
                           help: row.help?.topic, control: control)
        }
    }

    /// Where the scratchpad's folder is, and the two ways to move it. The path is the row's
    /// second line, so it reads like every other setting's current value.
    private func scratchpadRow() -> NSView {
        let choose = SettingsUI.button(
            "Choose…",
            target: self,
            action: #selector(browseForScratchpadFolder)
        )
        let help = HelpPopoverButton(topic: ScratchpadSettingsStructure.helpTopic)
        let row = ScratchpadSettingsStructure.row(path: Self.scratchpadPath,
            choose: choose, useDefault: scratchpadDefaultButton, helpButton: help)
        scratchpadFolderLabel = row.pathLabel
        updateScratchpadFolder()
        return row.view
    }

    private static var scratchpadPath: String {
        ScratchpadLocation.displayPath(ScratchpadWorkspace.folderURL,
            home: FileManager.default.homeDirectoryForCurrentUser)
    }

    // MARK: - Opening Message

    private func scheduleOpeningMessageWrite(for field: ThemedTextField) {
        if let unsettled = unsettledOpeningMessageField, unsettled !== field {
            flushOpeningMessageWrite()
        }
        unsettledOpeningMessageField = field
        openingMessageWriteTimer?.invalidate()
        openingMessageWriteTimer = Timer.scheduledTimer(
            withTimeInterval: NewChatDefaults.textSettingCoalescingInterval,
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

    // MARK: - Actions

    /// Rebuilds the shared default in the vocabulary of the agent new chats use. The persisted
    /// value stays the same when that agent changes; only Codex needs to qualify Auto with the
    /// automatic reviewer behavior the launch will select.
    private func rebuildPermissionModePopUp(for kind: AgentKind) {
        permissionModePopUp.removeAllItems()
        for choice in NewChatsSettingsStructure.permissionChoices(for: kind) {
            permissionModePopUp.addItem(ThemedMenuItem(title: choice.title,
                subtitle: choice.subtitle, representedValue: choice.mode))
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

    /// Restates the path and whether there is anything to reset to.
    private func updateScratchpadFolder() {
        scratchpadFolderLabel?.stringValue = Self.scratchpadPath
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
}
extension ChatsPreferencesViewController: NSTextFieldDelegate {
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

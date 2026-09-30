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

        newChatOpeningPrefixField.placeholderString = L10n.string(
            "For example: Think it through before you start changing files."
        )
        newChatOpeningPrefixField.stringValue = AppSettings.shared.newChatOpeningPrefix
        newChatOpeningPrefixField.setAccessibilityIdentifier(
            "settings.chats.new-chat-opening-prefix"
        )
        newChatOpeningPrefixField.delegate = self

        newChatOpeningSuffixField.placeholderString = L10n.string(
            "For example: Rename this chat to a ONE-WORD, ALL-CAPS name that represents it."
        )
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
        let page = SettingsUI.page(title: "Chats", sections: [
            SettingsUI.section("New Chats", newChatsCard()),
            SettingsUI.section(
                "Opening Message",
                openingMessageCard(),
                help: SettingsUI.help(
                    "Opening Message",
                    "Both are sent once, inside the first turn of a new chat — side chats and "
                        + "cross-provider continuations included. Neither is sent again when a "
                        + "chat resumes, and an imported conversation receives nothing. The name "
                        + "in the sidebar still comes from the task you wrote."
                )
            ),
            SettingsUI.section(
                "Attachments",
                attachmentDetectionCard(),
                help: SettingsUI.help(
                    "Attachments",
                    "Threading reads each agent's output for image, PDF, document, archive "
                        + "and diagram paths and lists them in the chat's panel. Turn an agent "
                        + "off here if an update changes how it prints paths."
                )
            ),
            SettingsUI.section("Scratchpad", SettingsCard(rows: [scratchpadRow()]))
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
        SettingsCard(rows: [
            SettingsUI.row(
                title: "New sessions use",
                subtitle: "Used by New Session (⌘N). Other agents stay available from the Project menu.",
                control: defaultAgentPopUp
            ),
            SettingsUI.row(
                title: "New sessions start in",
                subtitle: "How much a session may do before it stops to ask.",
                help: SettingsUI.help(
                    "New sessions start in",
                    "Following leaves it to the agent's own configuration. A single chat can "
                        + "still be set from its ⋯ menu, and the mode applies from that chat's "
                        + "next launch."
                ),
                control: permissionModePopUp
            ),
            SettingsUI.row(
                title: "Claude sessions start in",
                subtitle: "Fast uses more credits and needs a supported model.",
                help: SettingsUI.help(
                    "Claude sessions start in",
                    "Applies to Terminal and Native chats. Agent's Setting preserves Claude "
                        + "Code's own choice."
                ),
                control: claudeStartupSpeedPopUp
            ),
            SettingsUI.row(
                title: "Codex sessions start in",
                subtitle: "Fast uses more credits.",
                help: SettingsUI.help(
                    "Codex sessions start in",
                    "Applies to Terminal and Native chats. Agent's Setting preserves Codex's "
                        + "own service tier."
                ),
                control: codexStartupSpeedPopUp
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

    /// One switch per runtime, named by the runtime alone: what every one of them does is the
    /// same sentence, said once on the section's "?" rather than five times down the card.
    private func attachmentDetectionCard() -> SettingsCard {
        let runtimeRows = AgentKind.allCases.compactMap { kind -> NSView? in
            guard let toggle = attachmentDetectionToggles[kind] else { return nil }
            return SettingsUI.row(
                title: "Detect attachments from \(kind.displayName)",
                control: toggle
            )
        }
        return SettingsCard(rows: runtimeRows + [
            SettingsUI.row(
                title: "Include files outside the project",
                subtitle: "Lists paths from anywhere, copying each one in.",
                help: SettingsUI.help(
                    "Include files outside the project",
                    "Detected paths are normally kept to the session's own project, because a "
                        + "paired phone can fetch anything in the list and printed text is not a "
                        + "handoff. Images you attach or the agent shows are never affected."
                ),
                control: outsideProjectAttachmentToggle
            ),
            SettingsUI.row(
                title: "Keep the page as it was before each agent action",
                subtitle: "Lets an agent ask what its own browser click changed.",
                help: SettingsUI.help(
                    "Keep the page as it was before each agent action",
                    "The agent compares the page with a picture taken just before its action. "
                        + "The pictures stay in memory for the chat and are never added to your "
                        + "visual baselines.",
                    "Off by default because every page-changing tool call then costs a "
                        + "screenshot. It covers the agent's own actions only, not your clicks or "
                        + "a page updating itself."
                ),
                control: beforeActionCaptureToggle
            )
        ])
    }

    /// Where the scratchpad's folder is, and the two ways to move it. The path is the row's
    /// second line, so it reads like every other setting's current value.
    private func scratchpadRow() -> NSView {
        let choose = SettingsUI.button(
            "Choose…",
            target: self,
            action: #selector(browseForScratchpadFolder)
        )
        var pathField: NSTextField?
        let row = SettingsUI.row(
            title: L10n.string("Scratchpad folder"),
            subtitle: Self.scratchpadPath,
            help: SettingsUI.help(
                "Scratchpad folder",
                "Chats that are about no project live here. The folder is made the first time "
                    + "you start a scratchpad, and it is an ordinary git repository, so Git "
                    + "Review works on it and nothing you write is lost. It sits outside "
                    + "Threading's own storage on purpose — Reset Everything does not touch it."
            ),
            control: SettingsUI.controlGroup([choose, scratchpadDefaultButton]),
            subtitleField: &pathField,
            localizes: false
        )
        pathField?.lineBreakMode = .byTruncatingMiddle
        scratchpadFolderLabel = pathField
        updateScratchpadFolder()
        return row
    }

    private static var scratchpadPath: String {
        (ScratchpadWorkspace.folderURL.path as NSString).abbreviatingWithTildeInPath
    }

    // MARK: - Opening Message

    private func scheduleOpeningMessageWrite(for field: ThemedTextField) {
        if let unsettled = unsettledOpeningMessageField, unsettled !== field {
            flushOpeningMessageWrite()
        }
        unsettledOpeningMessageField = field
        openingMessageWriteTimer?.invalidate()
        openingMessageWriteTimer = Timer.scheduledTimer(
            withTimeInterval: ChatsPreferencesDefaults.textSettingCoalescingInterval,
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

// MARK: - Chats Preferences Defaults

enum ChatsPreferencesDefaults {
    /// Long enough that an ordinary sentence is one write, short enough that a page closed by
    /// ⌘W a moment after the last character has already settled without needing the flush.
    static let textSettingCoalescingInterval: TimeInterval = 0.4
}

import AppKit
import SkalmanExtensionKit
import SkalmanRemoteKit

// MARK: - Shared Session Action Presentation

/// The one description of the surface a session can switch *to*.
///
/// The row menu and pane-header button are two entrances to the same relaunch. Keeping the
/// target title here means a native session cannot say "Claude Code UI" in one place and
/// "Terminal" in another, or leave the button pointing at the surface already on screen.
struct SessionSurfaceTogglePresentation: Equatable {
    static var nativeTitle: String { L10n.string("Native UI (Experimental)") }
    static let nativeSymbol = "bubble.left.and.text.bubble.right"
    static let originalSymbol = "terminal"

    let targetUsesNativeUI: Bool
    let title: String
    let symbolName: String

    init(session: AgentSession) {
        targetUsesNativeUI = !session.usesNativeUI
        title = Self.title(usesNativeUI: targetUsesNativeUI, kind: session.kind)
        symbolName = targetUsesNativeUI ? Self.nativeSymbol : Self.originalSymbol
    }

    static func title(usesNativeUI: Bool, kind: AgentKind) -> String {
        usesNativeUI ? nativeTitle : kind.originalUITitle
    }
}

enum SessionActionMenuDefaults {
    static var attachmentsTitle: String { L10n.string("Attachments") }
    static let attachmentsSymbol = "paperclip"

    /// What the permission-mode submenu's first row says, given the app-wide default: the
    /// inherited answer where there is one, and where the decision goes where there is not.
    static func inheritedPermissionModeTitle(_ inherited: AgentPermissionMode?) -> String {
        guard let inherited else { return L10n.string("Use Agent's Setting") }
        return L10n.format("Use Default (%@)", inherited.displayName)
    }
}

// MARK: - Session Row Actions

/// The menu behind a session row's `⋯` hover button and its handlers. Split from the main
/// controller file purely for size; the menu targets the session in `actionSessionID`, set as
/// the menu opens.
extension ProjectSidebarViewController {

    /// Shows a row's actions beneath its hover button.
    ///
    /// Archiving is offered rather than deletion, since a session's conversation outlives the
    /// app and filing it away should not destroy anything.
    func showRowActions(for sessionID: SessionID, from anchor: NSView) {
        guard let session = ProjectStore.shared.session(withID: sessionID) else { return }

        let menu = NSMenu()
        actionSessionID = sessionID
        populateSessionActions(menu, for: session)

        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: anchor.bounds.maxY),
            in: anchor
        )
    }

    /// The full set of session actions, shared by the row's `⋯` hover button, its right-click
    /// context menu, and the pane header's Context button so none can drift — a second entrance
    /// that offered fewer actions is exactly the kind of gap that grows silently.
    ///
    /// The caller sets `actionSessionID` first: every handler here reads it, and it is set as
    /// the menu opens, so whichever surface presents the menu targets the right session.
    func populateSessionActions(_ menu: NSMenu, for session: AgentSession) {
        let sessionID = session.id

        menu.addItem(
            withTitle: session.isPinned ? L10n.string("Unpin") : L10n.string("Pin"),
            action: #selector(togglePinnedClicked),
            keyEquivalent: ""
        )
        // The sidebar only ever lists unarchived sessions, so this is always "Archive";
        // restoring one happens from Settings, where the archived sessions live.
        menu.addItem(
            withTitle: L10n.string("Archive"),
            action: #selector(archiveClicked),
            keyEquivalent: ""
        )

        if AgentRuntime.shared.isRunning(sessionID: sessionID) {
            menu.addItem(
                withTitle: L10n.string("Close Session"),
                action: #selector(closeSessionClicked),
                keyEquivalent: ""
            )
        }

        menu.addItem(.separator())
        addSideChatItems(to: menu, for: session)
        addSurfaceMenu(to: menu, for: session)
        menu.addItem(makeSessionThemeItem(for: sessionID))
        let attachments = menu.addItem(
            withTitle: SessionActionMenuDefaults.attachmentsTitle,
            action: #selector(attachmentsClicked),
            keyEquivalent: ""
        )
        attachments.image = NSImage(
            systemSymbolName: SessionActionMenuDefaults.attachmentsSymbol,
            accessibilityDescription: SessionActionMenuDefaults.attachmentsTitle
        )
        addPermissionModeItem(to: menu, for: session)
        addRemoteControlItem(to: menu, for: session)
        addMuteItem(to: menu, for: session)
        menu.addItem(
            withTitle: L10n.string("Rename Session…"),
            action: #selector(renameSessionClicked),
            keyEquivalent: ""
        )
        menu.addItem(
            withTitle: L10n.string("Copy Session ID"),
            action: #selector(copySessionIDClicked),
            keyEquivalent: ""
        )
        if AppSettings.shared.remoteAccessEnabled {
            menu.addItem(.separator())
            menu.addItem(
                withTitle: L10n.string("Share Chat…"),
                action: #selector(shareSessionClicked),
                keyEquivalent: ""
            )
            if RemoteAccessCoordinator.shared.hasSessionShares(sessionID) {
                menu.addItem(
                    withTitle: L10n.string("Stop Sharing Chat"),
                    action: #selector(stopSharingSessionClicked),
                    keyEquivalent: ""
                )
            }
        }
        addMoveToAccountItem(to: menu, for: session)
        addContinueWithProviderItem(to: menu, for: session)
        menu.addItem(.separator())
        menu.addItem(
            withTitle: L10n.string("Delete Session"),
            action: #selector(deleteSessionClicked),
            keyEquivalent: ""
        )

        for item in menu.items { item.target = self }

        // After the retarget loop: these items carry their own targets and the row's own
        // identity, lowercased to match the sanitized snapshot IDs extensions already hold.
        appendExtensionCommandItems(
            to: menu,
            placement: .sessionRow,
            context: ExtensionCommandContext(
                projectID: ProjectStore.shared.project(forSessionID: sessionID)?
                    .id.uuidString.lowercased(),
                sessionID: sessionID.uuidString.lowercased()
            )
        )
    }

    /// Silences one conversation, or lets it speak again.
    ///
    /// The title reads the *resolved* answer rather than the session's own field, so a session
    /// inside a muted project offers Unmute — the alternative is a Mute item on something that
    /// is already silent, which says the state is the opposite of what it is.
    private func addMuteItem(to menu: NSMenu, for session: AgentSession) {
        menu.addItem(
            withTitle: AttentionAlertScope.isMuted(sessionID: session.id)
                ? L10n.string("Unmute Notifications")
                : L10n.string("Mute Notifications"),
            action: #selector(toggleMutedClicked),
            keyEquivalent: ""
        )
    }

    @objc private func toggleMutedClicked() {
        guard let sessionID = actionSessionID else { return }

        let wanted = !AttentionAlertScope.isMuted(sessionID: sessionID)
        let inherited = ProjectStore.shared.project(forSessionID: sessionID)?
            .notificationsMuted ?? false

        // Storing nil where the answer already matches the project keeps this session
        // *following* it, so muting the project later still reaches here. An explicit value is
        // written only where it actually differs — which is the whole point of the field being
        // optional rather than a plain flag.
        ProjectStore.shared.setNotificationsMuted(
            wanted == inherited ? nil : wanted,
            forSessionID: sessionID
        )
        // The store knows nothing about notifications, so anything already on screen for this
        // session is still there until the alert center is asked to look again.
        AttentionAlertCenter.shared.preferencesChanged()
    }

    /// Adds the side-chat items: fork this conversation into one that starts with its context
    /// but keeps its own record.
    ///
    /// Both are hidden until there is something to fork — an agent that supports it, and a
    /// conversation that has actually started. A fork of nothing is an ordinary new session,
    /// which the composer already offers.
    private func addSideChatItems(to menu: NSMenu, for session: AgentSession) {
        guard session.kind.supportsForking, session.resumeState.isResumable else { return }

        let newItem = menu.addItem(
            withTitle: L10n.string("New Side Chat"),
            action: #selector(newSideChatClicked),
            keyEquivalent: ""
        )
        newItem.target = self

        let askItem = menu.addItem(
            withTitle: L10n.string("Ask on the Side…"),
            action: #selector(askOnTheSideClicked),
            keyEquivalent: ""
        )
        askItem.target = self
    }

    /// Adds the surface switch for an agent that has both — Skalman's own conversation view or
    /// the agent's terminal.
    ///
    /// Offered as an ordinary item rather than a warning, because it is not destructive: the
    /// two surfaces drive one conversation, resumed by the session's own id, so switching
    /// relaunches where it left off rather than starting over. What it does cost is the live
    /// process, which is why a working session confirms first.
    private func addSurfaceMenu(to menu: NSMenu, for session: AgentSession) {
        guard session.kind.supportsNativeUI else { return }

        let submenu = NSMenu(title: L10n.string("Interface"))
        let native = NSMenuItem(
            title: SessionSurfaceTogglePresentation.title(
                usesNativeUI: true,
                kind: session.kind
            ),
            action: #selector(setSurfaceClicked(_:)),
            keyEquivalent: ""
        )
        native.target = self
        native.representedObject = true
        native.state = session.usesNativeUI ? .on : .off
        submenu.addItem(native)

        let original = NSMenuItem(
            title: SessionSurfaceTogglePresentation.title(
                usesNativeUI: false,
                kind: session.kind
            ),
            action: #selector(setSurfaceClicked(_:)),
            keyEquivalent: ""
        )
        original.target = self
        original.representedObject = false
        original.state = session.usesNativeUI ? .off : .on
        submenu.addItem(original)

        let parent = NSMenuItem(
            title: L10n.string("Interface"),
            action: nil,
            keyEquivalent: ""
        )
        parent.submenu = submenu
        menu.addItem(parent)
    }

    /// Adds a "Move to Account" submenu when the conversation can move — it resumes by id, has
    /// a transcript recorded, and there is another account of the same agent to move it to.
    /// This conversation's answer about **Claude's own** Remote Control bridge, which is what
    /// lets claude.ai and the Claude mobile app drive it. Skalman's Remote Access is the
    /// separate "Share Chat…" block below.
    ///
    /// Claude-only, since Codex has no equivalent. The inherit item names the app-wide default
    /// where it can and defers where it cannot: when that default is "follow", the answer lives
    /// in the account's own `/config` and resolves server-side when unset, so claiming a value
    /// here would be a guess shown as a fact.
    private func addRemoteControlItem(to menu: NSMenu, for session: AgentSession) {
        guard session.kind == .claude else { return }

        let submenu = NSMenu()
        for choice in RemoteControlChoice.allCases {
            let item = NSMenuItem(
                title: choice.menuTitle,
                action: #selector(remoteControlChoiceClicked(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = choice
            item.state = choice.sessionValue == session.remoteControl ? .on : .off
            submenu.addItem(item)
        }

        let item = NSMenuItem(
            title: L10n.string("Claude Remote Control"),
            action: nil,
            keyEquivalent: ""
        )
        item.submenu = submenu
        menu.addItem(item)
    }

    /// How much this conversation may do before it has to ask.
    ///
    /// Both agents, unlike Remote Control above: Claude names one mode and Codex reaches the
    /// same six postures through its approval policy and sandbox, so the item means something
    /// either way. Each mode names what it does, and where the session's agent expresses it
    /// imperfectly the row says so rather than implying parity.
    ///
    /// The inherit item names the app-wide default where there is one and defers where there is
    /// not — Skalman cannot read `permissions.defaultMode` or `config.toml`, and a row claiming
    /// a value it guessed would be worse than one that says where the answer lives.
    private func addPermissionModeItem(to menu: NSMenu, for session: AgentSession) {
        let inherited = AppSettings.shared.defaultPermissionMode

        let submenu = NSMenu()
        let inheritItem = NSMenuItem(
            title: SessionActionMenuDefaults.inheritedPermissionModeTitle(inherited),
            action: #selector(permissionModeClicked(_:)),
            keyEquivalent: ""
        )
        inheritItem.target = self
        inheritItem.state = session.permissionMode == nil ? .on : .off
        submenu.addItem(inheritItem)

        for mode in AgentPermissionMode.allCases {
            let item = NSMenuItem(
                title: mode.displayName,
                action: #selector(permissionModeClicked(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = mode
            item.state = mode == session.permissionMode ? .on : .off
            item.toolTip = [mode.menuDescription, mode.caveat(for: session.kind)]
                .compactMap { $0 }
                .joined(separator: " ")
            submenu.addItem(item)
        }

        let item = NSMenuItem(
            title: L10n.string("Permission Mode"),
            action: nil,
            keyEquivalent: ""
        )
        item.submenu = submenu
        menu.addItem(item)
    }

    private func addMoveToAccountItem(to menu: NSMenu, for session: AgentSession) {
        guard let project = ProjectStore.shared.project(forSessionID: session.id),
              SessionMigration.canMigrate(session, in: project) else { return }

        let submenu = NSMenu()
        for account in SessionMigration.destinations(for: session) {
            let item = NSMenuItem(
                title: accountMenuLabel(account),
                action: #selector(moveToAccountClicked(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = account
            submenu.addItem(item)
        }

        let moveItem = NSMenuItem(
            title: L10n.string("Move to Account"),
            action: nil,
            keyEquivalent: ""
        )
        moveItem.submenu = submenu
        menu.addItem(moveItem)
    }

    /// Cross-provider is deliberately a different verb from Move. Move preserves one native
    /// transcript and can be reversed; Continue creates a new session whose first turn reads a
    /// provider-neutral handoff snapshot through MCP, while the original stays where it is.
    private func addContinueWithProviderItem(to menu: NSMenu, for session: AgentSession) {
        guard let project = ProjectStore.shared.project(forSessionID: session.id),
              ConversationContinuation.canContinue(session, in: project) else { return }

        let destinations = ConversationContinuation.destinations(for: session)
        guard let provider = destinations.first?.provider else { return }

        let submenu = NSMenu()
        for account in destinations {
            let item = NSMenuItem(
                title: accountMenuLabel(account),
                action: #selector(continueWithProviderClicked(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = account
            submenu.addItem(item)
        }

        let item = NSMenuItem(
            title: L10n.format("Continue with %@", provider.displayName),
            action: nil,
            keyEquivalent: ""
        )
        item.submenu = submenu
        menu.addItem(item)
    }

    private func accountMenuLabel(_ account: AgentAccount) -> String {
        let name = AccountName.display(for: account)
        return account.emoji.map { "\($0)  \(name)" } ?? name
    }

    // MARK: - Handlers

    /// The move itself belongs to the coordinator, not here: it stops the session's process, so
    /// the pane showing that session has to reopen it under the new account. A sidebar reload
    /// alone leaves the terminal blank until the session is selected again.
    @objc private func moveToAccountClicked(_ sender: NSMenuItem) {
        guard let sessionID = actionSessionID,
              let account = sender.representedObject as? AgentAccount else { return }

        delegate?.projectSidebar(self, moveSession: sessionID, toAccount: account)
    }

    @objc private func continueWithProviderClicked(_ sender: NSMenuItem) {
        guard let sessionID = actionSessionID,
              let account = sender.representedObject as? AgentAccount else { return }

        delegate?.projectSidebar(
            self,
            continueSession: sessionID,
            withAccount: account
        )
    }

    /// Records the choice only. A conversation already connected stays connected until it is
    /// relaunched, because the bridge is established by the process this setting configures at
    /// startup — silently killing a live one from a sidebar menu would be a second, hidden
    /// meaning for the same item.
    @objc private func remoteControlChoiceClicked(_ sender: NSMenuItem) {
        guard let sessionID = actionSessionID,
              let choice = sender.representedObject as? RemoteControlChoice else { return }

        ProjectStore.shared.setRemoteControl(choice.sessionValue, for: sessionID)
    }

    /// Records the choice only, for the same reason Remote Control does: the mode is stated in
    /// the flags of the process this configures at startup. A running session keeps the posture
    /// it launched with until it is relaunched — and Claude's own Shift+Tab, which Skalman
    /// cannot see, may already have moved it somewhere else.
    ///
    /// A nil `representedObject` is the inherit row, not a missing value.
    @objc private func permissionModeClicked(_ sender: NSMenuItem) {
        guard let sessionID = actionSessionID else { return }

        ProjectStore.shared.setPermissionMode(
            sender.representedObject as? AgentPermissionMode,
            for: sessionID
        )
    }

    @objc private func newSideChatClicked() {
        guard let sessionID = actionSessionID else { return }
        delegate?.projectSidebar(self, createSideChatOf: sessionID, prompt: nil)
    }

    /// The same fork, opened with its question already asked — the composer's own
    /// "start it with an opening message" shape, reached from a session instead of a project.
    @objc private func askOnTheSideClicked() {
        guard let sessionID = actionSessionID,
              let session = ProjectStore.shared.session(withID: sessionID) else { return }

        promptForText(
            title: L10n.string("Ask on the Side"),
            message: L10n.format(
                "Starts a side chat from “%@”, carrying everything it knows so far. "
                    + "Nothing you ask here joins that conversation.",
                session.displayTitle
            ),
            confirmTitle: L10n.string("Ask"),
            placeholder: L10n.string("What would you like to ask?")
        ) { [weak self] question in
            guard let self, !question.isEmpty else { return }
            self.delegate?.projectSidebar(self, createSideChatOf: sessionID, prompt: question)
        }
    }

    @objc private func setSurfaceClicked(_ sender: NSMenuItem) {
        guard let sessionID = actionSessionID,
              let session = ProjectStore.shared.session(withID: sessionID),
              let usesNativeUI = sender.representedObject as? Bool,
              usesNativeUI != session.usesNativeUI else { return }

        delegate?.projectSidebar(self, setUsesNativeUI: usesNativeUI, for: sessionID)
    }

    @objc private func attachmentsClicked() {
        guard let sessionID = actionSessionID else { return }
        delegate?.projectSidebar(self, showAttachmentsFor: sessionID)
    }

    @objc private func archiveClicked() {
        guard let sessionID = actionSessionID else { return }
        archiveSession(sessionID)
    }

    /// The one archive path, shared by the menu item and the row's hover button so the two
    /// cannot drift — the same reason `populateSessionActions` is shared with the context menu.
    func archiveSession(_ sessionID: SessionID) {
        delegate?.projectSidebar(self, setArchived: true, for: sessionID)
    }

    @objc private func togglePinnedClicked() {
        guard let sessionID = actionSessionID,
              let session = ProjectStore.shared.session(withID: sessionID) else { return }
        ProjectStore.shared.setPinned(!session.isPinned, for: sessionID)
        reload()
    }

    /// Through the delegate rather than the runtime, so the row menu shares Cmd+W's
    /// confirmation instead of skipping it.
    @objc private func closeSessionClicked() {
        guard let sessionID = actionSessionID else { return }
        delegate?.projectSidebar(self, closeSession: sessionID)
    }

    @objc private func renameSessionClicked() {
        guard let sessionID = actionSessionID,
              let session = ProjectStore.shared.session(withID: sessionID) else { return }

        promptRename(
            title: L10n.string("Rename Session"),
            current: session.customTitle ?? "",
            placeholder: session.displayTitle,
            allowsEmpty: true
        ) { newTitle in
            ProjectStore.shared.renameSession(id: sessionID, to: newTitle)
            self.reload()
        }
    }

    /// Copies the identifier that names this conversation outside Skalman.
    ///
    /// It is the one fact about a chat that is needed *elsewhere* — grepping a transcript,
    /// resuming from a terminal, quoting a session in a bug report — and the only way to read
    /// it before this was to ask the agent running inside it.
    @objc private func copySessionIDClicked() {
        guard let sessionID = actionSessionID,
              let session = ProjectStore.shared.session(withID: sessionID) else { return }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(session.externalIdentifier, forType: .string)
    }

    /// A copied link is a single-use invitation for this chat only. Collaboration and permission
    /// approval are separate rights, so a trusted participant can handle requests caused by
    /// their work without gaining theme, lifecycle, project, or other-chat access.
    @objc private func shareSessionClicked() {
        guard let sessionID = actionSessionID,
              let session = ProjectStore.shared.session(withID: sessionID) else { return }

        let alert = NSAlert()
        alert.messageText = L10n.format("Share “%@”", session.displayTitle)
        let isRunning = AgentRuntime.shared.isRunning(sessionID: sessionID)
        alert.informativeText = isRunning
            ? L10n.string(
                "This single-use invitation opens only this chat and expires after 24 hours "
                    + "if nobody accepts it. Once accepted, that member keeps access until you "
                    + "stop sharing. Choose permission approval only for someone you trust."
            )
            : L10n.string(
                "This single-use invitation opens only this chat and expires after 24 hours "
                    + "if nobody accepts it. Once accepted, that member keeps access until you "
                    + "stop sharing. Choose permission approval only for someone you trust. "
                    + "Start this chat before creating a view-only link; viewing alone never "
                    + "starts an agent process."
            )
        alert.alertStyle = .informational
        alert.addButton(withTitle: L10n.string("Copy View-Only Link"))
        alert.addButton(withTitle: L10n.string("Copy Collaborator Link"))
        alert.addButton(withTitle: L10n.string("Copy Collaborator + Approval Link"))
        alert.addButton(withTitle: L10n.string("Cancel"))
        alert.buttons[0].isEnabled = isRunning

        let capability: RemoteCapability
        let canApprovePermissions: Bool
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            capability = .view
            canApprovePermissions = false
        case .alertSecondButtonReturn:
            capability = .interact
            canApprovePermissions = false
        case .alertThirdButtonReturn:
            capability = .interact
            canApprovePermissions = true
        default:
            return
        }

        guard let url = RemoteAccessCoordinator.shared.shareURL(
            for: sessionID,
            capability: capability,
            canApprovePermissions: canApprovePermissions
        ) else {
            let unavailable = NSAlert()
            unavailable.messageText = L10n.string("Secure relay isn’t ready")
            unavailable.informativeText = L10n.string(
                "Wait for Remote Access to say it is ready, then try again."
            )
            unavailable.alertStyle = .warning
            unavailable.runModal()
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    @objc private func stopSharingSessionClicked() {
        guard let sessionID = actionSessionID else { return }
        RemoteAccessCoordinator.shared.revokeSessionShares(sessionID)
    }

    @objc private func deleteSessionClicked() {
        guard let sessionID = actionSessionID else { return }
        removeSession(sessionID)
    }
}

// MARK: - Remote Control Choice

/// The three items in a session's Claude Remote Control submenu.
///
/// It carries the *session's* stored value, which is why inherit is nil rather than a third
/// boolean: a conversation that never chose has to keep following the app default as that
/// default changes, and only an absent value can do that.
private enum RemoteControlChoice: CaseIterable {
    case inherit
    case on
    case off

    var sessionValue: Bool? {
        switch self {
        case .inherit: nil
        case .on: true
        case .off: false
        }
    }

    /// The inherit item names what it defers to, which depends on the app-wide setting: an
    /// answer when there is one to name, and Claude's own configuration when there is not.
    @MainActor
    var menuTitle: String {
        switch self {
        case .inherit: AppSettings.shared.claudeRemoteControl.inheritedMenuTitle
        case .on: L10n.string("Always On")
        case .off: L10n.string("Always Off")
        }
    }
}

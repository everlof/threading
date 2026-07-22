import AppKit

// MARK: - Session Row Actions

/// The menu behind a session row's `⋯` hover button and its handlers. Split from the main
/// controller file purely for size; the menu targets the session in `actionSessionID`, set as
/// the menu opens.
extension ProjectSidebarViewController {

    /// Shows a row's actions beneath its hover button.
    ///
    /// Archiving is offered rather than deletion, since a session's conversation outlives the
    /// app and filing it away should not destroy anything.
    func showRowActions(for sessionID: UUID, from anchor: NSView) {
        guard let session = ProjectStore.shared.session(withID: sessionID) else { return }

        let menu = NSMenu()
        actionSessionID = sessionID

        // The sidebar only ever lists unarchived sessions, so this is always "Archive";
        // restoring one happens from Settings, where the archived sessions live.
        menu.addItem(withTitle: "Archive", action: #selector(archiveClicked), keyEquivalent: "")

        if AgentRuntime.shared.isRunning(sessionID: sessionID) {
            menu.addItem(withTitle: "Close Session", action: #selector(closeSessionClicked), keyEquivalent: "")
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: "Rename Session…", action: #selector(renameSessionClicked), keyEquivalent: "")
        addMoveToAccountItem(to: menu, for: session)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Delete Session", action: #selector(deleteSessionClicked), keyEquivalent: "")

        for item in menu.items { item.target = self }

        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: anchor.bounds.maxY),
            in: anchor
        )
    }

    /// Adds a "Move to Account" submenu when the conversation can move — it resumes by id, has
    /// a transcript recorded, and there is another account of the same agent to move it to.
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

        let moveItem = NSMenuItem(title: "Move to Account", action: nil, keyEquivalent: "")
        moveItem.submenu = submenu
        menu.addItem(moveItem)
    }

    private func accountMenuLabel(_ account: AgentAccount) -> String {
        account.emoji.map { "\($0)  \(account.displayName)" } ?? account.displayName
    }

    // MARK: - Handlers

    @objc private func moveToAccountClicked(_ sender: NSMenuItem) {
        guard let sessionID = actionSessionID,
              let account = sender.representedObject as? AgentAccount else { return }

        switch SessionMigration.move(sessionID: sessionID, to: account) {
        case .success:
            reload()
        case .failure(let error):
            presentMigrationError(error)
        }
    }

    private func presentMigrationError(_ error: SessionMigration.MoveError) {
        let alert = NSAlert()
        alert.messageText = "Couldn't move the conversation"
        alert.informativeText = error.message
        alert.alertStyle = .warning
        alert.runModal()
    }

    @objc private func archiveClicked() {
        guard let sessionID = actionSessionID else { return }
        delegate?.projectSidebar(self, setArchived: true, for: sessionID)
    }

    @objc private func closeSessionClicked() {
        guard let sessionID = actionSessionID else { return }
        AgentRuntime.shared.discard(sessionID: sessionID)
        reload()
    }

    @objc private func renameSessionClicked() {
        guard let sessionID = actionSessionID,
              let session = ProjectStore.shared.session(withID: sessionID) else { return }

        promptRename(
            title: "Rename Session",
            current: session.customTitle ?? "",
            placeholder: session.displayTitle,
            allowsEmpty: true
        ) { newTitle in
            ProjectStore.shared.renameSession(id: sessionID, to: newTitle)
            self.reload()
        }
    }

    @objc private func deleteSessionClicked() {
        guard let sessionID = actionSessionID else { return }
        removeSession(sessionID)
    }
}

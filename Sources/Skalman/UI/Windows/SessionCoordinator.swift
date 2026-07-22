import AppKit

/// Owns session lifecycle decisions while the window controller owns only navigation chrome.
///
/// Creation, import, worktree targeting, surface switches, and closing all converge here so an
/// opening prompt cannot be stranded in one delegate extension while the launch happens in
/// another. The sidebar and container remain the views through which those decisions appear.
@MainActor
final class SessionCoordinator: SessionComposerViewControllerDelegate {

    private let sidebar: ProjectSidebarViewController
    private let container: TerminalContainerViewController
    private let onPresentationChanged: () -> Void

    /// Consumed by the next selected session exactly once.
    private var pendingPrompt: String?

    init(
        sidebar: ProjectSidebarViewController,
        container: TerminalContainerViewController,
        onPresentationChanged: @escaping () -> Void
    ) {
        self.sidebar = sidebar
        self.container = container
        self.onPresentationChanged = onPresentationChanged
    }

    func takePendingPrompt() -> String? {
        defer { pendingPrompt = nil }
        return pendingPrompt
    }

    func newSession() {
        let projectID: ProjectID?
        if let sessionID = container.currentSessionID {
            projectID = ProjectStore.shared.project(forSessionID: sessionID)?.id
        } else {
            projectID = ProjectStore.shared.projects.first?.id
        }

        guard let projectID else {
            addProject()
            return
        }
        sidebar.select(projectID: projectID)
    }

    func addProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Project"
        panel.message = "Choose a folder to add as a project."

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            let project = ProjectStore.shared.addProject(folderURL: url)
            self.sidebar.reload()
            self.sidebar.select(projectID: project.id)
        }
    }

    func closeCurrentSession() {
        guard let sessionID = container.currentSessionID,
              confirmCloseIfRunning(sessionID: sessionID) else { return }

        container.closeTerminal(for: sessionID)
        sidebar.refreshRows()
    }

    func setUsesNativeUI(_ usesNative: Bool, for sessionID: SessionID) {
        guard confirmSurfaceSwitchIfRunning(sessionID: sessionID, toNative: usesNative) else {
            return
        }

        AgentRuntime.shared.discard(sessionID: sessionID)
        ProjectStore.shared.setUsesNativeUI(usesNative, for: sessionID)
        container.reopenIfShowing(sessionID: sessionID)
        sidebar.reload()
        onPresentationChanged()
    }

    func createSideChat(of sessionID: SessionID, prompt: String?) {
        guard let session = ProjectStore.shared.addSideChat(of: sessionID) else { return }

        EventLog.shared.record(.composer, "Side chat forked", [
            "session": session.id.uuidString,
            "parent": sessionID.uuidString,
            "prompt": prompt ?? ""
        ])

        pendingPrompt = prompt
        sidebar.reload()
        sidebar.select(sessionID: session.id)
    }

    // MARK: - Composer

    func sessionComposer(
        _ composer: SessionComposerViewController,
        startSessionIn projectID: ProjectID,
        kind: AgentKind,
        accountHandle: AccountHandle,
        model: String?,
        branch: String?,
        usesNativeUI: Bool,
        prompt: String
    ) {
        let targetProjectID = Self.targetProjectID(
            startingAt: projectID,
            branch: branch,
            checkout: ProjectStore.shared.checkout(onBranch:inRepositoryOf:)
        )

        guard let session = ProjectStore.shared.addSession(
            to: targetProjectID,
            kind: kind,
            accountHandle: accountHandle,
            model: model,
            usesNativeUI: usesNativeUI
        ) else { return }

        let opening = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        EventLog.shared.record(.composer, "Session started from composer", [
            "session": session.id.uuidString,
            "project": targetProjectID.uuidString,
            "agent": kind.rawValue,
            "account": accountHandle.name,
            "prompt": opening
        ])

        DraftStore.shared.clear(for: projectID)
        pendingPrompt = opening
        sidebar.reload()
        sidebar.select(sessionID: session.id)
    }

    func sessionComposer(
        _ composer: SessionComposerViewController,
        importSession session: ImportableSession,
        into projectID: ProjectID
    ) {
        guard let adopted = ProjectStore.shared.importSession(session, into: projectID) else {
            return
        }

        sidebar.reload()
        sidebar.select(sessionID: adopted.id)
    }

    func sessionComposer(
        _ composer: SessionComposerViewController,
        didCreateWorktreeAt url: URL,
        branch: String
    ) {
        let project = ProjectStore.shared.addProject(folderURL: url)
        sidebar.reload()
        container.showComposer(projectID: project.id)
    }

    /// A branch selection targets its existing checkout; a missing or removed checkout falls
    /// back to the project where the composer opened.
    static func targetProjectID(
        startingAt projectID: ProjectID,
        branch: String?,
        checkout: (String, ProjectID) -> ProjectID?
    ) -> ProjectID {
        branch.flatMap { checkout($0, projectID) } ?? projectID
    }

    // MARK: - Confirmation

    private func confirmCloseIfRunning(sessionID: SessionID) -> Bool {
        guard AppSettings.shared.confirmsBeforeClosingRunningSession,
              AgentRuntime.shared.isRunning(sessionID: sessionID),
              let session = ProjectStore.shared.session(withID: sessionID) else { return true }

        let alert = NSAlert()
        alert.messageText = "Close \"\(session.displayTitle)\"?"
        alert.informativeText = session.kind.supportsResume
            ? "The agent will stop. The session stays in the sidebar and can be resumed."
            : "The shell will stop. The session stays in the sidebar."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close Session")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func confirmSurfaceSwitchIfRunning(sessionID: SessionID, toNative: Bool) -> Bool {
        guard AppSettings.shared.confirmsBeforeClosingRunningSession,
              AgentRuntime.shared.isRunning(sessionID: sessionID),
              let session = ProjectStore.shared.session(withID: sessionID) else { return true }

        let surface = toNative ? "Conversation" : "Terminal"
        let alert = NSAlert()
        alert.messageText = "Show \"\(session.displayTitle)\" as \(surface.lowercased())?"
        alert.informativeText = """
            The agent stops and starts again on the new surface, resuming this conversation \
            where it left off. Anything it is working on right now is interrupted.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Show as \(surface)")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

import Foundation

/// Executes the commands an agent may apply to the session carrying its tool call.
///
/// Session identity still comes from the MCP route, never an argument. The UI coordinator is a
/// transport adapter; persistence refusal, title precedence, and deferred archive outcomes live
/// here and can be exercised without a window or display pane.
@MainActor
final class AgentSessionCommandService {
    private let projects: ProjectStore
    private let archiveScheduler: SessionArchiveScheduler
    private let usesAgentTitleInSidebar: () -> Bool

    init(
        projects: ProjectStore,
        archiveScheduler: SessionArchiveScheduler,
        usesAgentTitleInSidebar: @escaping () -> Bool
    ) {
        self.projects = projects
        self.archiveScheduler = archiveScheduler
        self.usesAgentTitleInSidebar = usesAgentTitleInSidebar
    }

    /// Arms an archive for after the current turn. Archiving inside the tool call would stop the
    /// agent before it could receive and report the result.
    func archiveSession(
        _ arguments: ArchiveSessionArguments,
        for sessionID: SessionID
    ) -> MCPToolResult {
        let title = projects.session(withID: sessionID)?.displayTitle

        switch archiveScheduler.request(sessionID: sessionID, reason: arguments.reason) {
        case .scheduled, .alreadyPending:
            let name = title.map { "“\($0)”" } ?? "This session"
            return .success("""
                \(name) will be archived when this turn ends. Finish your reply as normal — \
                the session is filed away a moment after it lands, its agent stops, and the \
                user sees a receipt with an Undo on it. Call cancel_session_archive if they \
                change their mind before then.
                """)
        case .refused(let reason):
            return .failure(reason)
        }
    }

    /// Writes the agent-owned title source. A user's custom title remains authoritative.
    func setSessionName(
        _ arguments: SetSessionNameArguments,
        for sessionID: SessionID
    ) -> MCPToolResult {
        let requested = (arguments.name ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requested.isEmpty else {
            return .failure("Provide a name: two to five words describing this conversation.")
        }

        let name = String(requested.prefix(ImportDefaults.titleLimit))
        guard let session = projects.session(withID: sessionID) else {
            return .failure("This session is no longer in the sidebar.")
        }

        switch projects.updateAgentTitle(name, for: sessionID, source: .chosen) {
        case .accepted:
            break
        case .persistenceRefused:
            return .failure("“\(name)” could not be saved. The previous session name is unchanged.")
        case .sessionNotFound:
            return .failure("This session is no longer in the sidebar.")
        case .refusedAsNoise, .protectedByStrongerSource, .cleared:
            return .failure("""
                “\(name)” was not used: it repeats something the row already shows — the \
                agent's name, the account's, or the project's. Name the conversation \
                instead, in the words that tell it apart from the others in the sidebar.
                """)
        }

        if let customTitle = session.customTitle, !customTitle.isEmpty {
            return .success("""
                Named “\(name)”. The sidebar still shows “\(customTitle)”, which the user \
                typed themselves — their name outranks yours, and this one takes over if \
                they ever clear it.
                """)
        }

        guard usesAgentTitleInSidebar() else {
            return .success("""
                Named “\(name)”. The sidebar is set to ignore agent titles, so the row still \
                reads “\(session.displayTitle)” until that is turned back on under \
                Settings ▸ General.
                """)
        }

        return .success("This session is now called “\(name)”.")
    }

    /// Cancels only a pending request. An archive that already landed remains a user-owned Undo.
    func cancelSessionArchive(for sessionID: SessionID) -> MCPToolResult {
        switch archiveScheduler.cancel(sessionID: sessionID) {
        case .cancelled:
            return .success("This session is no longer going to be archived.")
        case .nothingPending:
            return .success("""
                Nothing was pending, so nothing changed. If the session has already been \
                archived, the user takes that back from the receipt in the sidebar or from \
                Settings ▸ Archived.
                """)
        }
    }
}

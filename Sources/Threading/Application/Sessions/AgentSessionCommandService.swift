import Foundation

/// Executes the commands an agent may apply to the session carrying its tool call.
///
/// Session identity still comes from the MCP route, never an argument. The UI coordinator is a
/// transport adapter; persistence refusal, title precedence, and deferred archive outcomes live
/// here and can be exercised without a window or display pane.
/// What came of asking for a worktree of one's own.
///
/// The checkout and the move are reported separately because they fail separately, and because a
/// created worktree survives a refused move: the directory is real work the user asked for, so
/// the caller has to be able to name it even when the conversation stayed where it was.
enum SessionWorktreeCreation {
    case created(path: String, move: SessionCheckoutMoveRequestResult)
    case refused(String)
}

@MainActor
final class AgentSessionCommandService {
    private let projects: ProjectStore
    private let archiveScheduler: SessionArchiveScheduler
    private let usesAgentTitleInSidebar: () -> Bool
    private let control: WorkspaceControlPlane?
    private let checkoutCoordinator: SessionCheckoutCoordinator

    init(
        projects: ProjectStore,
        archiveScheduler: SessionArchiveScheduler,
        usesAgentTitleInSidebar: @escaping () -> Bool,
        control: WorkspaceControlPlane? = nil,
        checkoutCoordinator: SessionCheckoutCoordinator = .shared
    ) {
        self.projects = projects
        self.archiveScheduler = archiveScheduler
        self.usesAgentTitleInSidebar = usesAgentTitleInSidebar
        self.control = control
        self.checkoutCoordinator = checkoutCoordinator
    }

    func setSessionCheckout(
        _ arguments: SetSessionCheckoutArguments,
        for sessionID: SessionID,
        approval: Bool? = nil
    ) -> SessionCheckoutMoveRequestResult {
        let path = arguments.checkoutPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let reason = arguments.reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty, let basis = arguments.authorityBasis, !reason.isEmpty else {
            return .failed("Provide checkout_path, authority_basis, and reason.")
        }
        return checkoutCoordinator.requestMove(
            sessionID: sessionID,
            checkoutPath: path,
            authorityBasis: basis,
            reason: reason,
            approval: approval,
            // This service is reached by a tool executing inside the calling turn. Even if a
            // provider's activity projection is late, the tool response must return before the
            // authoritative turn-finished barrier replaces its runtime.
            waitForCurrentTurnBoundary: true
        )
    }

    /// Makes a worktree for the calling chat's repository and queues the chat's move into it.
    ///
    /// The two halves are one operation on purpose. Creating a checkout and moving a chat into it
    /// were previously reachable only from two different places — `New Worktree…` in the composer,
    /// which no agent can press, and `set_session_checkout`, which only moves into a checkout that
    /// already exists. So an agent asked for a worktree had exactly one route, `git worktree add`,
    /// which leaves ownership behind and the sidebar naming the checkout the chat launched from.
    ///
    /// The worktree is created *before* the move is requested and deliberately not cleaned up if
    /// the move is then refused: the checkout is real work the user asked for, and a tool that
    /// deletes a checkout because a policy said "ask first" would be destroying the thing it was
    /// told to make. A refused move leaves a usable worktree and a chat that has not moved, which
    /// the drift observer will notice the moment the agent starts working there.
    func createSessionWorktree(
        _ arguments: CreateSessionWorktreeArguments,
        for sessionID: SessionID,
        approval: Bool? = nil
    ) -> SessionWorktreeCreation {
        let branch = arguments.branch?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let reason = arguments.reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !branch.isEmpty, let basis = arguments.authorityBasis, !reason.isEmpty else {
            return .refused("Provide branch, authority_basis, and reason.")
        }
        guard let session = projects.session(withID: sessionID) else {
            return .refused("This chat is no longer available.")
        }
        // A managed workspace is already an isolated worktree of Threading's own making, and its
        // disposal handshake owns that checkout's whole lifetime.
        guard session.managedWorkspace == nil else {
            return .refused("This chat already runs in a Threading-managed workspace.")
        }
        guard let project = projects.project(forSessionID: sessionID) else {
            return .refused("This chat does not belong to a project.")
        }
        guard let destination = GitWorktree.suggestedLocation(forBranch: branch, in: project) else {
            return .refused(GitWorktree.Failure.notARepository.localizedDescription)
        }

        let created: URL
        do {
            created = try GitWorktree.create(
                branch: branch,
                at: destination,
                from: project,
                createsBranch: !GitWorktree.branches(in: project).contains(branch)
            )
        } catch {
            return .refused(
                (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
        }

        return .created(
            path: created.path,
            move: checkoutCoordinator.requestMove(
                sessionID: sessionID,
                checkoutPath: created.path,
                authorityBasis: basis,
                reason: reason,
                approval: approval,
                // Same reason as `setSessionCheckout`: this runs inside the calling turn and
                // must return before the turn-finished barrier replaces the runtime.
                waitForCurrentTurnBoundary: true
            )
        )
    }

    func cancelSessionCheckoutMove(for sessionID: SessionID) -> MCPToolResult {
        checkoutCoordinator.cancelPendingMove(sessionID: sessionID)
            ? .success("This session has no pending checkout move.")
            : .failure("The pending checkout move could not be cancelled.")
    }

    /// Arms an archive for after the current turn. Archiving inside the tool call would stop the
    /// agent before it could receive and report the result.
    func archiveSession(
        _ arguments: ArchiveSessionArguments,
        for sessionID: SessionID
    ) -> MCPToolResult {
        if let target = targetID(arguments.sessionID) {
            switch (control ?? .live).archive(target, reason: arguments.reason, from: .agentSession(sessionID)) {
            case .scheduled(let row), .alreadyPending(let row):
                return .success("“\(row.title)” will be archived after its settle grace.")
            case .cancelled, .nothingPending:
                return .failure("The archive request changed before it could be recorded.")
            case .refused(let refusal): return .failure(refusal.toolWords)
            }
        } else if arguments.sessionID?.isEmpty == false {
            return .failure("session_id must be a Threading UUID from list_sessions.")
        }
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

        if let target = targetID(arguments.sessionID) {
            switch (control ?? .live).rename(target, to: requested, from: .agentSession(sessionID)) {
            case .renamed(let row, let title):
                return .success("“\(row.title)” is now called “\(title)”.")
            case .protectedByUserTitle(_, let title):
                return .success("The user's title “\(title)” still wins, so the visible name did not change.")
            case .refused(let refusal): return .failure(refusal.toolWords)
            }
        } else if arguments.sessionID?.isEmpty == false {
            return .failure("session_id must be a Threading UUID from list_sessions.")
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
    func cancelSessionArchive(
        _ arguments: CancelSessionArchiveArguments = .init(),
        for sessionID: SessionID
    ) -> MCPToolResult {
        if let target = targetID(arguments.sessionID) {
            switch (control ?? .live).cancelArchive(target, from: .agentSession(sessionID)) {
            case .cancelled(let row): return .success("“\(row.title)” is no longer going to be archived.")
            case .nothingPending(let row): return .success("“\(row.title)” had no pending archive.")
            case .scheduled, .alreadyPending: return .failure("The archive state changed unexpectedly.")
            case .refused(let refusal): return .failure(refusal.toolWords)
            }
        } else if arguments.sessionID?.isEmpty == false {
            return .failure("session_id must be a Threading UUID from list_sessions.")
        }
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

    private func targetID(_ raw: String?) -> SessionID? {
        raw.flatMap { SessionID(uuidString: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
}

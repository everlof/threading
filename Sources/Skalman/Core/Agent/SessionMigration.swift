import Foundation

/// Moves a conversation to another account of the same agent, so it resumes there.
///
/// A conversation is a client-side transcript the CLI replays to the API each turn, not server
/// state tied to the account that started it — which is why a copy resumes faithfully under a
/// different login (verified: a session copied into another account's config dir resumed with
/// full context). Skalman never touches a token; the official CLI authenticates under whichever
/// account, so this is a portability action, not credential reuse.
///
/// Same agent only. Claude→Claude and Codex→Codex share a transcript format and a resume path;
/// moving *across* agents is a different, lossy operation (a re-seed, not a resume) and is not
/// this.
@MainActor
enum SessionMigration {

    struct MoveError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: - Queries

    /// The accounts a session's conversation could move to: other logins of its own agent.
    static func destinations(for session: AgentSession) -> [AgentAccount] {
        guard session.kind.supportsAccounts else { return [] }

        return AgentAccountDiscovery.accounts(for: session.kind).filter { account in
            normalizedHandle(account) != session.accountHandle
        }
    }

    /// The transcript that would move, if one has been recorded under the session's account.
    static func sourceTranscript(for session: AgentSession, in project: Project) -> URL? {
        guard let id = session.agentSessionID else { return nil }

        let url: URL?
        switch session.kind {
        case .claude: url = ClaudeTranscript.url(sessionID: id, for: session, in: project)
        case .codex: url = CodexTranscript.url(sessionID: id, for: session)
        case .shell: url = nil
        }

        guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// Whether the session can be moved: it resumes by id, has a transcript on disk, and there
    /// is somewhere to move it to.
    static func canMigrate(_ session: AgentSession, in project: Project) -> Bool {
        session.kind.supportsResume
            && !destinations(for: session).isEmpty
            && sourceTranscript(for: session, in: project) != nil
    }

    // MARK: - Move

    /// Copies the conversation into the target account and re-points the session at it, so the
    /// next launch resumes there. Non-destructive: the original transcript is left in place, so
    /// a move can be undone by moving back.
    @discardableResult
    static func move(sessionID: SessionID, to account: AgentAccount) -> Result<Void, MoveError> {
        guard let session = ProjectStore.shared.session(withID: sessionID),
              let project = ProjectStore.shared.project(forSessionID: sessionID) else {
            return .failure(MoveError(message: "The session no longer exists."))
        }

        guard session.kind == account.provider else {
            let kind = session.kind.displayName
            return .failure(MoveError(message: "A \(kind) conversation can only move to another \(kind) account."))
        }

        guard let source = sourceTranscript(for: session, in: project) else {
            return .failure(MoveError(message: "This conversation has nothing recorded to move yet."))
        }

        guard let current = AgentAccountDiscovery.account(for: session.kind, handle: session.accountHandle),
              source.path.hasPrefix(current.configPath) else {
            return .failure(MoveError(message: "Could not locate the conversation on disk."))
        }

        // The layout under a config directory is identical between accounts, so the destination
        // is the source with its account-directory prefix swapped. This holds for Claude's
        // `projects/<slug>/` and Codex's dated `sessions/` path alike.
        let relative = String(source.path.dropFirst(current.configPath.count))
        let destination = URL(fileURLWithPath: account.configPath + relative)

        // A live process still belongs to the old account and is still writing the transcript,
        // so it is torn down before the file is copied.
        AgentRuntime.shared.discard(sessionID: sessionID)

        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            return .failure(MoveError(message: "Could not copy the conversation: \(error.localizedDescription)"))
        }

        ProjectStore.shared.update(sessionID: sessionID) {
            $0.accountHandle = account.handle
        }

        SkalmanLogger.agent.info("Migrated session \(sessionID) to account \(account.handle, privacy: .public)")
        return .success(())
    }

    // MARK: - Private Methods

    private static func normalizedHandle(_ account: AgentAccount) -> AccountHandle {
        account.handle
    }
}

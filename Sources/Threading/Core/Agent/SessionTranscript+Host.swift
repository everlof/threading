import Foundation

extension SessionTranscript {
    // MARK: - Public Methods

    /// The transcript for a conversation under a known account.
    ///
    /// Nil where the runtime keeps no transcript Threading can read. That is a statement about
    /// the reader, not about the runtime's own storage: OpenCode and Grok both persist their
    /// conversations, and neither has a format this app parses.
    @MainActor
    static func readRequest(
        sessionID: TranscriptID,
        for session: AgentSession,
        in project: Project,
        account: AgentAccount,
        locations: ClaudeTranscriptLocations = .shared
    ) -> ReadRequest? {
        guard account.provider == session.kind, account.handle == session.accountHandle else { return nil }
        if session.kind.supports(.transcriptReplay),
           let mirror = RemoteTranscriptMirror.shared.mirrorURL(for: session, transcriptID: sessionID, in: project) {
            return .file(mirror)
        }
        switch session.kind {
        case .claude:
            // A session on a remote host keeps its transcript there; every reader on this Mac
            // reads the mirror of it instead (`RemoteTranscriptMirror`). The local account's
            // directory is not a fallback: a file there is this Mac's, from before the project had
            // a host, and reading it would describe a different conversation.
            if sessionID == session.resumeState.transcriptID,
               let observed = locations.url(for: session, account: account) {
                return .file(observed)
            }
            return ClaudeTranscript.storageSlot(
                sessionID: sessionID, account: account, in: project
            ).map(ReadRequest.claudeStorage)
        case .codex:
            return .codexRollout(sessionID, account)
        case .grok, .openCode, .cursor:
            return nil
        }
    }

    @MainActor
    static func url(
        sessionID: TranscriptID,
        for session: AgentSession,
        in project: Project,
        account: AgentAccount,
        effort: TranscriptLookupEffort = .discovering
    ) -> URL? {
        readRequest(sessionID: sessionID, for: session, in: project, account: account)?
            .resolve(effort: effort)
    }
}

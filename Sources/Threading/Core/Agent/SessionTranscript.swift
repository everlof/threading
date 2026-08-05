import Foundation

/// Where a session's transcript lives on disk, whichever runtime wrote it.
///
/// Two call sites carried their own `switch session.kind` over the same two readers — the
/// replayer, which had an account in hand, and the migration check, which had to resolve one
/// and then test the file. They agreed, which is the point: a third runtime with a transcript
/// would have had to be added to both, and the compiler would have said so in neither.
///
/// `ClaudeTranscript` and `CodexTranscript` remain the readers. This is only the dispatch, so
/// a runtime's own path rules, caching and slug scheme stay with the runtime that owns them.
///
/// Not every transcript lookup belongs here. `SessionNaming` builds a `Transcript` value that
/// defers the Codex rollout search rather than paying for it up front, and the terminal's model
/// reading asks only for a runtime with `.transcriptModelRecord`. Both are narrower questions
/// than "where is this session's file", and flattening them into this one would cost the first
/// its laziness and the second its capability check.
enum SessionTranscript {

    // MARK: - Public Methods

    /// The transcript for a conversation under a known account.
    ///
    /// Nil where the runtime keeps no transcript Threading can read. That is a statement about
    /// the reader, not about the runtime's own storage: OpenCode and Grok both persist their
    /// conversations, and neither has a format this app parses.
    static func url(
        sessionID: TranscriptID,
        for session: AgentSession,
        in project: Project,
        account: AgentAccount
    ) -> URL? {
        switch session.kind {
        case .claude:
            return ClaudeTranscript.url(sessionID: sessionID, account: account, in: project)
        case .codex:
            return CodexTranscript.url(sessionID: sessionID, account: account)
        case .grok, .openCode:
            return nil
        }
    }

    /// The same, for a session that has a conversation and an account of its own.
    ///
    /// Nil when the session has yet to be given an identifier, when its account cannot be
    /// found, or when its runtime keeps no readable transcript.
    ///
    /// Main-actor, unlike the overload above: resolving the session's account reads the
    /// discovery cache. A caller already off the main thread — the replayer, reading a file on
    /// a background queue — passes the account it resolved before it left.
    @MainActor
    static func url(for session: AgentSession, in project: Project) -> URL? {
        guard let sessionID = session.resumeState.transcriptID,
              let account = AgentAccountDiscovery.account(
                for: session.kind,
                handle: session.accountHandle
              )
        else { return nil }

        return url(sessionID: sessionID, for: session, in: project, account: account)
    }

    /// The transcript that is on disk right now, or nil.
    ///
    /// A path is not a file: an identifier is minted before the CLI has written anything, so a
    /// caller that means "there is a conversation to move" has to ask the filesystem.
    @MainActor
    static func existingURL(for session: AgentSession, in project: Project) -> URL? {
        guard let url = url(for: session, in: project),
              FileManager.default.fileExists(atPath: url.path)
        else { return nil }

        return url
    }
}

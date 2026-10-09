import Foundation

extension ClaudeTranscript {
    /// The transcript for a session, whether or not it exists yet.
    @MainActor
    static func url(sessionID: TranscriptID, for session: AgentSession, in project: Project) -> URL? {
        guard session.kind.supports(.checkoutScopedConversationStorage),
              let account = AgentAccountDiscovery.account(
            for: session.kind,
            handle: session.accountHandle
        ) else { return nil }

        return SessionTranscript.url(
            sessionID: sessionID, for: session, in: project, account: account
        )
    }

    /// Whether a conversation has been recorded, which is what makes a resume possible.
    ///
    /// An identifier alone is not enough: Claude's is minted before the conversation exists,
    /// so a session that exited without exchanging anything has an id and no transcript.
    @MainActor
    static func exists(sessionID: TranscriptID, for session: AgentSession, in project: Project) -> Bool {
        guard let url = url(sessionID: sessionID, for: session, in: project) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

}

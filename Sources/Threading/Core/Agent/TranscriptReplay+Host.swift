import Foundation

extension TranscriptReplay {
    /// Reads a session's transcript off the main thread and calls back with what to render.
    ///
    /// `isTruncated` reports that older turns were dropped, so the view can say so rather than
    /// implying the conversation began where the replay does.
    @MainActor
    static func load(
        for session: AgentSession,
        in project: Project,
        completion: @escaping @MainActor @Sendable (
            _ events: [StreamEvent], _ isTruncated: Bool
        ) -> Void
    ) {
        guard TranscriptReplayFormat(kind: session.kind) != nil,
              let agentSessionID = session.resumeState.transcriptID else {
            completion([], false)
            return
        }

        guard let account = AgentAccountDiscovery.account(
            for: session.kind,
            handle: session.accountHandle
        ), let request = SessionTranscript.readRequest(
            sessionID: agentSessionID, for: session, in: project, account: account
        ) else {
            completion([], false)
            return
        }

        load(request, kind: session.kind, completion: completion)
    }

}

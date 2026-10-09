import Foundation

extension CodexTranscript {
    @MainActor
    static func url(sessionID: TranscriptID, for session: AgentSession) -> URL? {
        guard let account = AgentAccountDiscovery.account(
            for: session.kind,
            handle: session.accountHandle
        ) else { return nil }

        return url(sessionID: sessionID, account: account)
    }
}

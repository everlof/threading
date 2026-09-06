import Foundation

/// The file a live Claude process actually writes, which can remain in its original project
/// directory after a checkout move. The copied file at the new slug is not evidence of new output.
///
/// One bounded path per allocated runtime (normally 1–40, stress 1,000); hook updates and lookups
/// are O(1) in session count and perform no discovery or filesystem work. Discard removes the entry.
@MainActor
final class ClaudeTranscriptLocations {
    static let shared = ClaudeTranscriptLocations()
    private static let maximumPathBytes = 4_096

    private struct Location: Equatable {
        let accountHandle: AccountHandle
        let transcriptID: TranscriptID
        let path: String
    }

    private var locations: [SessionID: Location] = [:]

    /// An opaque source version for async observations. Repeated identical hooks do not revoke
    /// a read; changing or discarding its source does.
    private var revisions: [SessionID: UUID] = [:]

    func revision(for sessionID: SessionID) -> UUID? { revisions[sessionID] }

    func observe(
        _ report: HookLifecycleReport,
        for session: AgentSession,
        ownershipEpoch: UInt64
    ) {
        guard session.kind.supports(.checkoutScopedConversationStorage),
              report.sessionID == session.id,
              report.event != .subagentStarted, report.event != .subagentStopped,
              report.capturedOwnershipEpoch == nil
                || report.capturedOwnershipEpoch == ownershipEpoch,
              let transcriptID = session.resumeState.transcriptID,
              report.agentSessionID == transcriptID,
              let path = report.transcriptPath,
              path.hasPrefix("/"),
              path.utf8.prefix(Self.maximumPathBytes + 1).count <= Self.maximumPathBytes
        else { return }

        let location = Location(
            accountHandle: session.accountHandle,
            transcriptID: transcriptID,
            path: path
        )
        guard locations[session.id] != location else { return }
        locations[session.id] = location
        revisions[session.id] = UUID()
        EventLog.shared.record(.hooks, "Claude root transcript location reported", [
            "session": session.id.uuidString,
            "transcript": path
        ])
    }

    /// Validate against the caller's already-resolved account. A hook cannot redirect a read to
    /// another account, another session, or a child transcript.
    func url(for session: AgentSession, account: AgentAccount) -> URL? {
        guard session.kind.supports(.checkoutScopedConversationStorage),
              let location = locations[session.id],
              location.accountHandle == session.accountHandle,
              location.accountHandle == account.handle,
              location.transcriptID == session.resumeState.transcriptID,
              session.kind == account.provider
        else { return nil }

        let url = URL(fileURLWithPath: location.path, isDirectory: false).standardizedFileURL
        let projects = URL(fileURLWithPath: account.configPath, isDirectory: true)
            .appendingPathComponent(AgentDefaults.claudeProjectsSubdirectory, isDirectory: true)
            .standardizedFileURL
        guard url.lastPathComponent == location.transcriptID.rawValue + ".jsonl",
              url.deletingLastPathComponent().deletingLastPathComponent().path == projects.path
        else { return nil }
        return url
    }

    func forget(_ sessionID: SessionID) {
        locations.removeValue(forKey: sessionID)
        revisions.removeValue(forKey: sessionID)
    }
}

import Foundation

/// Locates the conversation transcripts Claude Code keeps on disk.
///
/// They live at `<config-dir>/projects/<project-path-with-dashes>/<session-id>.jsonl`, and are
/// wanted in three places — deciding whether a resume can work, importing conversations
/// started elsewhere, and replaying one into the conversation view. The path is derived here
/// so those three cannot drift apart.
enum ClaudeTranscript {

    /// The transcript for a session, whether or not it exists yet.
    @MainActor
    static func url(sessionID: TranscriptID, for session: AgentSession, in project: Project) -> URL? {
        guard let account = AgentAccountDiscovery.account(
            for: session.kind,
            handle: session.accountHandle
        ) else { return nil }

        return url(sessionID: sessionID, account: account, in: project)
    }

    static func url(sessionID: TranscriptID, account: AgentAccount, in project: Project) -> URL? {
        guard sessionID.isSafePathComponent else { return nil }
        return URL(fileURLWithPath: account.configPath)
            .appendingPathComponent(AgentDefaults.claudeProjectsSubdirectory)
            .appendingPathComponent(projectSlug(for: project))
            .appendingPathComponent(sessionID.rawValue)
            .appendingPathExtension(AgentDefaults.transcriptExtension)
    }

    /// The independently persisted child transcripts for one root conversation.
    ///
    /// Claude places the root at `<session-id>.jsonl` and children beneath
    /// `<session-id>/subagents/`, with a small `.meta.json` index beside each child JSONL.
    static func subagentsDirectory(
        sessionID: TranscriptID,
        account: AgentAccount,
        in project: Project
    ) -> URL? {
        url(sessionID: sessionID, account: account, in: project)?
            .deletingPathExtension()
            .appendingPathComponent(AgentDefaults.claudeSubagentsSubdirectory)
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

    /// Claude's directory name for a project: its absolute path with separators replaced.
    static func projectSlug(for project: Project) -> String {
        project.folderPath.replacingOccurrences(
            of: "/",
            with: AgentDefaults.projectSlugSeparator
        )
    }
}

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

    /// Claude's directory name for the folder a session runs in.
    ///
    /// `Project.folderPath` because callers hand this type an *execution* project — the copy
    /// `AgentLauncher.plan` and `ProjectStore.executionProject` make, whose folder is the
    /// session's own checkout. A managed workspace's transcripts are filed under the worktree
    /// it ran in, not under the repository it will merge back into.
    static func projectSlug(for project: Project) -> String {
        projectSlug(forPath: project.folderPath)
    }

    /// A path encoded the way Claude names the directory it files that path's transcripts under.
    ///
    /// Every character outside `[a-zA-Z0-9]` becomes a dash — not only the separators. Replacing
    /// `/` alone is right for the usual `/Users/me/repo/thing` and silently wrong for anything
    /// else, and the wrongness is invisible: a missing directory reads as "no conversation
    /// recorded", so `AgentLauncher` dropped to its fresh-launch branch and relaunched with
    /// `--session-id` naming an id Claude had already used. Claude exits 1 on that, in under a
    /// second, which on screen is a Resume button that does nothing. Every managed workspace hit
    /// this — they live under `Application Support` — as did any project folder with a dot in it.
    ///
    /// Per UTF-16 code unit rather than per character, which is what makes an astral scalar two
    /// dashes rather than one. Measured against the CLI: a folder named `slug probe_v1.2 åäö-🎉`
    /// is filed under `slug-probe-v1-2-------`.
    static func projectSlug(forPath path: String) -> String {
        var slug = ""
        slug.reserveCapacity(path.utf16.count)

        for unit in path.utf16 {
            if preservedSlugCodeUnits.contains(unit), let scalar = Unicode.Scalar(unit) {
                slug.unicodeScalars.append(scalar)
            } else {
                slug.append(AgentDefaults.projectSlugSeparator)
            }
        }

        return slug
    }

    /// Spelled out rather than compared against numeric bounds: the set is the rule, and an
    /// ASCII range written as `0x61...0x7A` is a place for a mistake to hide.
    private static let preservedSlugCodeUnits: Set<UInt16> = Set(
        AgentDefaults.projectSlugPreservedCharacters.utf16
    )
}

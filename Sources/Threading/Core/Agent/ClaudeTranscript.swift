import Foundation
import os

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
        guard session.kind.supports(.checkoutScopedConversationStorage),
              let account = AgentAccountDiscovery.account(
            for: session.kind,
            handle: session.accountHandle
        ) else { return nil }

        return SessionTranscript.url(
            sessionID: sessionID, for: session, in: project, account: account
        )
    }

    /// A storage slot for a checkout, used for copy destinations. Readers select their source
    /// through `SessionTranscript`, which asks `StorageSlot` instead; this slot may be a stale copy.
    ///
    /// The physical folder's slot, because that is where Claude files a conversation it starts,
    /// and so the copy its `--resume` finds first.
    static func storageURL(sessionID: TranscriptID, account: AgentAccount, in project: Project) -> URL? {
        storageSlot(sessionID: sessionID, account: account, in: project)?.candidates().first
    }

    /// Where a conversation filed under a checkout may be, captured without touching the
    /// filesystem, so that a caller on the main actor can hand it to the worker that reads it.
    static func storageSlot(
        sessionID: TranscriptID,
        account: AgentAccount,
        in project: Project
    ) -> StorageSlot? {
        guard sessionID.isSafePathComponent else { return nil }
        return StorageSlot(
            sessionID: sessionID,
            configPath: account.configPath,
            folderPath: project.folderPath
        )
    }

    /// A conversation's file under each spelling of the folder it ran in.
    struct StorageSlot: Sendable, Equatable {
        let sessionID: TranscriptID
        let configPath: String
        let folderPath: String

        /// Every place the file may be, the one Claude files a new conversation in first.
        func candidates(effort: TranscriptLookupEffort = .discovering) -> [URL] {
            ClaudeTranscript.projectSlugs(forPath: folderPath, effort: effort).map { slug in
                URL(fileURLWithPath: configPath, isDirectory: true)
                    .appendingPathComponent(AgentDefaults.claudeProjectsSubdirectory, isDirectory: true)
                    .appendingPathComponent(slug, isDirectory: true)
                    .appendingPathComponent(sessionID.rawValue, isDirectory: false)
                    .appendingPathExtension(AgentDefaults.transcriptExtension)
            }
        }

        /// The candidate that exists, else the one Claude would write. `.known` answers from
        /// memory alone, so it names the preferred candidate without asking which one is there.
        func resolve(effort: TranscriptLookupEffort = .discovering) -> URL {
            let urls = candidates(effort: effort)
            guard effort == .discovering, urls.count > 1 else { return urls[0] }
            return urls.first { FileManager.default.fileExists(atPath: $0.path) } ?? urls[0]
        }
    }

    /// The independently persisted child transcripts for one root conversation.
    ///
    /// Claude places the root at `<session-id>.jsonl` and children beneath
    /// `<session-id>/subagents/`, with a small `.meta.json` index beside each child JSONL.
    static func subagentsDirectory(forRoot root: URL) -> URL {
        root
            .deletingPathExtension()
            .appendingPathComponent(AgentDefaults.claudeSubagentsSubdirectory, isDirectory: true)
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
        projectSlugs(forPath: project.folderPath)[0]
    }

    /// Claude's directory names for a folder, the one it files new conversations under first.
    ///
    /// Two when a symlink sits on the path, which includes every folder under `/tmp` and `/var`
    /// (both links into `/private`), and one otherwise. Claude names the directory after the
    /// physical path, which is what `getcwd` reports inside the folder. Deriving the name from
    /// the path as stored misses the directory, and a missing directory reads as "no
    /// conversation recorded": `AgentLauncher` relaunched with `--session-id` naming an id
    /// Claude already held, and Claude refused it with exit 1. A project at `/tmp/takto-pr60`
    /// stopped resuming this way, because its conversation was in `-private-tmp-takto-pr60`.
    ///
    /// The stated spelling stays second rather than being dropped. Threading's own copies (an
    /// account migration, a checkout move) were filed under it before this was known, and Claude
    /// resumes a copy from whichever directory holds it, so for those conversations it is where
    /// the live file is.
    static func projectSlugs(
        forPath path: String,
        effort: TranscriptLookupEffort = .discovering
    ) -> [String] {
        let stated = projectSlug(forPath: path)
        let physical = projectSlug(forPath: physicalPath(of: path, effort: effort))
        return physical == stated ? [stated] : [physical, stated]
    }

    /// The folder with every symlink on its path resolved, the way `getcwd` reports it.
    ///
    /// Not `URL.resolvingSymlinksInPath()`, which is the obvious call and gives the one answer
    /// that is never right here: Foundation strips a leading `/private` whenever the rest still
    /// exists, turning `/private/tmp/x` back into `/tmp/x`. `realpath(3)` keeps it.
    ///
    /// Remembered per folder, because a catalogue asks once per session on the main actor and
    /// the answer changes only when a link on the path is replaced (seen after a relaunch). One
    /// entry per distinct checkout folder asked about. `.known` answers from memory alone and
    /// falls back to the path as given; so does a folder that cannot be resolved, such as one
    /// that has been removed, which is not remembered, so it is resolved once it exists.
    static func physicalPath(
        of path: String,
        effort: TranscriptLookupEffort = .discovering
    ) -> String {
        if let known = physicalPaths.withLock({ $0[path] }) { return known }
        guard effort == .discovering, let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        let physical = String(cString: resolved)
        physicalPaths.withLock { $0[path] = physical }
        return physical
    }

    private static let physicalPaths = OSAllocatedUnfairLock(initialState: [String: String]())

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
        ClaudeTranscriptPath.projectSlug(forPath: path)
    }
}

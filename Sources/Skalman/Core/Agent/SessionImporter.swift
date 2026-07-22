import Foundation

// MARK: - Importable Session

/// A conversation found on disk that Skalman does not yet track.
struct ImportableSession: Identifiable {
    let agentSessionID: TranscriptID
    let kind: AgentKind
    let accountHandle: AccountHandle
    let title: String
    let lastActiveAt: Date

    var id: String { "\(kind.rawValue):\(agentSessionID)" }
}

// MARK: - Session Importer

/// Finds conversations started outside Skalman — from a plain terminal, usually — so they can
/// be adopted into a project and resumed like any other session.
///
/// Scanning reads transcript files, so it runs off the main queue and reads each one only as
/// far as it must. Both agents already store everything needed; nothing is inferred.
///
/// Only conversations with something the user typed are offered: a transcript holding nothing
/// but the CLI's own scaffolding has nothing to resume.
enum SessionImporter {

    // MARK: - Public Methods

    /// Discovers conversations belonging to a project's folder, newest first.
    ///
    /// Sessions already tracked by the project are excluded, so the list only ever offers
    /// something new.
    @MainActor
    static func discover(
        for project: Project,
        completion: @escaping @MainActor @Sendable ([ImportableSession]) -> Void
    ) {
        let folder = normalized(project.folderPath)
        let known = Set(project.sessions.compactMap { $0.resumeState.transcriptID })
        let claudeAccounts = AgentAccountDiscovery.accounts(for: .claude)
        let codexAccounts = AgentAccountDiscovery.accounts(for: .codex)

        DispatchQueue.global(qos: .userInitiated).async {
            // Resolve the project's worktree once, so a chat is attributed by which checkout
            // it ran in rather than by a raw path match. This is what keeps a separate
            // worktree nested inside the folder out of it — a different checkout, its own id.
            let worktree = GitInfo.worktreeIdentity(for: folder)

            var found = claudeSessions(
                inFolder: folder,
                worktree: worktree,
                accounts: claudeAccounts
            )
            found.append(contentsOf: codexSessions(
                inFolder: folder,
                worktree: worktree,
                accounts: codexAccounts
            ))

            let result = found
                .filter { !known.contains($0.agentSessionID) }
                .sorted { $0.lastActiveAt > $1.lastActiveAt }

            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Whether a chat launched in `cwd` belongs to a project's checkout.
    ///
    /// A path within the folder counts only when it resolves to the *same* worktree: an
    /// ordinary subdirectory does, a worktree nested inside the folder does not — the latter
    /// is a separate checkout with its own git directory, on its own branch. The equal-path
    /// case is settled without touching disk, which is almost every rollout.
    private static func belongs(cwd: String, folder: String, worktree: String?) -> Bool {
        let path = normalized(cwd)
        if path == folder { return true }
        guard path.hasPrefix(folder + "/") else { return false }
        return GitInfo.worktreeIdentity(for: path) == worktree
    }

    // MARK: - Claude

    /// Claude files transcripts under a directory named after the launch path, so the folder's
    /// slug maps straight to it. Each transcript also records its own `cwd`, which is checked
    /// against the project's worktree — the directory name is a lossy encoding (two different
    /// paths can slug alike), so the recorded path is the authority on membership.
    private static func claudeSessions(
        inFolder folder: String,
        worktree: String?,
        accounts: [AgentAccount]
    ) -> [ImportableSession] {
        let slug = folder.replacingOccurrences(
            of: "/",
            with: AgentDefaults.projectSlugSeparator
        )

        return accounts.flatMap { account -> [ImportableSession] in
            let directory = URL(fileURLWithPath: account.configPath)
                .appendingPathComponent(AgentDefaults.claudeProjectsSubdirectory)
                .appendingPathComponent(slug)

            guard let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey]
            ) else { return [] }

            return files.compactMap { url -> ImportableSession? in
                guard url.pathExtension == AgentDefaults.transcriptExtension else { return nil }

                let info = claudeInfo(at: url)
                guard let title = info.title else { return nil }

                // A recorded cwd is authoritative; its absence leaves the slug directory —
                // which is derived from this very folder — to vouch for membership.
                if let cwd = info.cwd, !belongs(cwd: cwd, folder: folder, worktree: worktree) {
                    return nil
                }

                return ImportableSession(
                    agentSessionID: TranscriptID(url.deletingPathExtension().lastPathComponent),
                    kind: .claude,
                    accountHandle: account.handle,
                    title: title,
                    lastActiveAt: modificationDate(of: url)
                )
            }
        }
    }

    /// A transcript's title and the directory it was launched in.
    ///
    /// Claude writes an `ai-title` record and rewrites it as the conversation develops, so the
    /// last one is the current title; the opening message is the fallback until one exists.
    /// `cwd` sits on every record, so the first is enough.
    private static func claudeInfo(at url: URL) -> (title: String?, cwd: String?) {
        var title: String?
        var firstMessage: String?
        var cwd: String?

        // Read on to the limit rather than stopping early: the title is rewritten as the
        // conversation develops, so only the last one is current.
        JSONLReader.forEachRecord(at: url, limit: ImportDefaults.claudeScanLimit) { record in
            if cwd == nil, let value = record["cwd"] as? String, !value.isEmpty {
                cwd = value
            }

            if record["type"] as? String == ImportDefaults.claudeTitleType,
               let value = record["aiTitle"] as? String, !value.isEmpty {
                title = value
            }

            if firstMessage == nil,
               record["type"] as? String == ImportDefaults.claudeUserType,
               let message = record["message"] as? [String: Any] {
                firstMessage = userText(from: message["content"])
            }

            return true
        }

        return (title ?? firstMessage, cwd)
    }

    // MARK: - Codex

    /// Codex files rollouts by date, recording the launch directory inside each, so matching
    /// means reading the header of every rollout.
    private static func codexSessions(
        inFolder folder: String,
        worktree: String?,
        accounts: [AgentAccount]
    ) -> [ImportableSession] {
        return accounts.flatMap { account -> [ImportableSession] in
            let root = URL(fileURLWithPath: account.configPath)
                .appendingPathComponent(AgentAccountDefaults.sessionsSubdirectory)

            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { return [] }

            return enumerator.compactMap { element -> ImportableSession? in
                guard let url = element as? URL,
                      url.pathExtension == CodexDiscoveryDefaults.rolloutExtension,
                      url.lastPathComponent.hasPrefix(CodexDiscoveryDefaults.rolloutPrefix)
                else { return nil }

                // Two-phase read. Codex keeps every rollout it has ever written in one tree,
                // so most files belong to other projects; reading each in full to discover
                // that made scanning take seconds. `session_meta` is the first record, so its
                // recorded `cwd` decides membership and only matches are read further.
                guard let header = codexHeader(at: url),
                      belongs(cwd: header.cwd, folder: folder, worktree: worktree)
                else { return nil }

                // No user turn means no conversation to resume. Codex records its own
                // sub-sessions here too — the approval assessor writes a rollout per review,
                // in the same directory, with the project as its working directory — and
                // those are machine turns the user never had and cannot meaningfully reopen.
                guard let title = codexTitle(at: url) else { return nil }

                return ImportableSession(
                    agentSessionID: header.id,
                    kind: .codex,
                    accountHandle: account.handle,
                    title: title,
                    lastActiveAt: modificationDate(of: url)
                )
            }
        }
    }

    /// Reads a rollout's `session_meta` header — its identifier and launch directory.
    ///
    /// The header cannot be read with a fixed byte cap: `session_meta` carries the session's
    /// instructions, so the record runs to tens of kilobytes and varies per project. Reading
    /// whole records and stopping after the first keeps this correct whatever its length.
    private static func codexHeader(at url: URL) -> (id: TranscriptID, cwd: String)? {
        var header: (id: TranscriptID, cwd: String)?

        JSONLReader.forEachRecord(at: url, limit: ImportDefaults.headerScanLimit) { record in
            guard record["type"] as? String == CodexDiscoveryDefaults.sessionMetaType,
                  let payload = record["payload"] as? [String: Any],
                  let id = payload["id"] as? String,
                  let cwd = payload["cwd"] as? String
            else { return false }

            header = (TranscriptID(id), cwd)
            return false
        }

        return header
    }

    /// Names a rollout after the first thing the user actually typed.
    ///
    /// Codex records a dedicated `user_message` event per turn, which is the only place the
    /// user's own words appear unmixed; the conversation also replays them as `user`-role
    /// messages, but behind the instruction blocks both CLIs prepend. The event is preferred
    /// and the replayed message kept as a fallback, since older rollouts predate the event.
    private static func codexTitle(at url: URL) -> String? {
        var typed: String?
        var replayed: String?

        JSONLReader.forEachRecord(at: url, limit: ImportDefaults.codexScanLimit) { record in
            guard let payload = record["payload"] as? [String: Any] else { return true }

            if payload["type"] as? String == CodexDiscoveryDefaults.userMessageType,
               let text = userText(from: payload["message"]) {
                typed = text
                return false
            }

            if replayed == nil, payload["role"] as? String == "user" {
                replayed = userText(from: payload["content"])
            }

            return true
        }

        return typed ?? replayed
    }

    // MARK: - Parsing

    /// Streams a transcript's records in order, stopping when `handle` returns false or the
    /// byte limit is reached.
    ///
    /// Transcripts grow without bound — a busy session reaches megabytes — so reading them
    /// whole would make scanning a project unreasonably slow. Reading incrementally and
    /// letting the caller stop means the usual file costs one chunk, while a session that
    /// buries what we need behind a long preamble is still found rather than silently missed.
    /// Extracts readable text from a message body, skipping the blocks both CLIs inject
    /// ahead of the user's own words — instructions, environment context, command caveats.
    private static func userText(from content: Any?) -> String? {
        let raw: String?

        switch content {
        case let text as String:
            raw = text
        case let blocks as [[String: Any]]:
            raw = blocks.compactMap { block in
                block["text"] as? String
            }.first
        default:
            raw = nil
        }

        guard let raw else { return nil }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !ImportDefaults.injectedPrefixes.contains(where: { trimmed.hasPrefix($0) })
        else { return nil }

        let firstLine = trimmed.split(separator: "\n").first.map(String.init) ?? trimmed
        return String(firstLine.prefix(ImportDefaults.titleLimit))
    }

    private static func modificationDate(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
    }

    private static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}

// MARK: - Import Defaults

enum ImportDefaults {
    /// Read granularity while streaming a transcript.
    static let chunkBytes = 64 * 1024

    /// Bound for a rollout header. Reading stops at the first record regardless, so this only
    /// guards against a file that is not a transcript at all.
    static let headerScanLimit = 1024 * 1024

    /// Enough to reach the title without reading a long conversation entire.
    static let claudeScanLimit = 512 * 1024

    /// Codex buries the opening turn behind its telemetry, and compaction pushes it further
    /// still, so the search has to reach well past where the record usually sits. Reading
    /// stops at the opening turn, so this ceiling is only paid by a session that has none.
    static let codexScanLimit = 8 * 1024 * 1024

    static let titleLimit = 80
    static let claudeTitleType = "ai-title"
    static let claudeUserType = "user"

    /// Openings that are scaffolding rather than something the user typed. Both CLIs prepend
    /// several of these, and a resumed Codex session replays its history behind one more.
    static let injectedPrefixes = [
        "<local-command-caveat>",
        "<command-name>",
        "<environment_context>",
        "<user_instructions>",
        "<recommended_plugins>",
        "<INSTRUCTIONS>",
        "# AGENTS.md",
        "Caveat:",
        "The following is the Codex agent history"
    ]
}

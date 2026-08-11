import Foundation

// MARK: - Importable Session

/// A conversation found on disk that Threading does not yet track.
struct ImportableSession: Identifiable {
    let agentSessionID: TranscriptID
    let kind: AgentKind
    let accountHandle: AccountHandle
    let title: String
    let lastActiveAt: Date

    var id: String { "\(kind.rawValue):\(agentSessionID)" }
}

// MARK: - Session Importer

/// Finds conversations started outside Threading — from a plain terminal, usually — so they can
/// be adopted into a project and resumed like any other session.
///
/// Scanning reads transcript files, so it runs off the main queue and reads each one only as
/// far as it must. Both agents already store everything needed; nothing is inferred.
///
/// Only conversations with something the user typed are offered: a transcript holding nothing
/// but the CLI's own scaffolding has nothing to resume.
enum SessionImporter {

    private struct ScanBatch {
        var sessions: [ImportableSession]
        var failures: Int
    }

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
        let startedAt = Date()
        let folder = normalized(project.folderPath)
        let known = Set(project.sessions.compactMap { $0.resumeState.transcriptID })
        let replaySources = TranscriptReplayFormat.allCases.map { format in
            (format: format, accounts: AgentAccountDiscovery.accounts(for: format.kind))
        }
        let accountCount = replaySources.reduce(0) { $0 + $1.accounts.count }
        ThreadingLogger.agent.info(
            "Project session import scan started project=\(project.id.uuidString, privacy: .public) formats=\(replaySources.count, privacy: .public) accounts=\(accountCount, privacy: .public)"
        )

        DispatchQueue.global(qos: .userInitiated).async {
            // Resolve the project's worktree once, so a chat is attributed by which checkout
            // it ran in rather than by a raw path match. This is what keeps a separate
            // worktree nested inside the folder out of it — a different checkout, its own id.
            let worktree = GitInfo.worktreeIdentity(for: folder)

            let batches = replaySources.map { source in
                sessions(
                    inFolder: folder,
                    worktree: worktree,
                    format: source.format,
                    accounts: source.accounts
                )
            }
            let found = batches.flatMap(\.sessions)
            let failures = batches.reduce(0) { $0 + $1.failures }

            let result = deduplicated(
                found
                    .filter { !known.contains($0.agentSessionID) }
                    .sorted { $0.lastActiveAt > $1.lastActiveAt }
            )

            let durationMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1_000)
            if failures > 0 {
                ThreadingLogger.agent.warning(
                    "Project session import scan completed project=\(project.id.uuidString, privacy: .public) results=\(result.count, privacy: .public) failures=\(failures, privacy: .public) duration_ms=\(durationMilliseconds, privacy: .public)"
                )
            } else {
                ThreadingLogger.agent.info(
                    "Project session import scan completed project=\(project.id.uuidString, privacy: .public) results=\(result.count, privacy: .public) failures=0 duration_ms=\(durationMilliseconds, privacy: .public)"
                )
            }

            DispatchQueue.main.async { completion(result) }
        }
    }

    /// One row per conversation, from a list already ordered newest first.
    ///
    /// The same conversation is on disk under more than one account whenever it has been moved
    /// between logins, and each account's copy is found separately: 13 of this project's own
    /// conversations were offered twice, identical but for which copy the accounts had written
    /// to last. Both rows resume the same transcript, so the second is a row the reader has to
    /// tell apart from the first and then discard.
    ///
    /// Identity is `kind` and transcript id — `ImportableSession.id`, the same rule the
    /// whole-disk scan dedupes on. The surviving row is the newest, which is the account whose
    /// copy of the conversation has the most in it.
    static func deduplicated(_ sessions: [ImportableSession]) -> [ImportableSession] {
        var seen = Set<String>()
        return sessions.filter { seen.insert($0.id).inserted }
    }

    /// Dispatches only after the closed replay-format set has admitted the runtime. A new
    /// runtime cannot be added to transcript replay without the compiler asking which import
    /// format walks its files; callers no longer maintain a parallel provider allow-list.
    private static func sessions(
        inFolder folder: String,
        worktree: String?,
        format: TranscriptReplayFormat,
        accounts: [AgentAccount]
    ) -> ScanBatch {
        switch format {
        case .claude:
            return claudeSessions(inFolder: folder, worktree: worktree, accounts: accounts)
        case .codex:
            return codexSessions(inFolder: folder, worktree: worktree, accounts: accounts)
        }
    }

    /// Whether a chat launched in `cwd` belongs to a project's checkout.
    ///
    /// A path within the folder counts only when it resolves to the *same* worktree: an
    /// ordinary subdirectory does, a worktree nested inside the folder does not — the latter
    /// is a separate checkout with its own git directory, on its own branch. The equal-path
    /// case is settled without touching disk, which is almost every rollout.
    ///
    /// Internal rather than private so `SessionImportBelongingTests` can put it against a real
    /// `git worktree` layout. The rule is the one thing standing between a project and another
    /// checkout's conversations, and it had been proven by hand rather than by anything that
    /// runs.
    static func belongs(cwd: String, folder: String, worktree: String?) -> Bool {
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
    ) -> ScanBatch {
        let slug = folder.replacingOccurrences(
            of: "/",
            with: AgentDefaults.projectSlugSeparator
        )

        let fileManager = FileManager.default
        var found: [ImportableSession] = []
        var failures = 0
        for account in accounts {
            let directory = URL(fileURLWithPath: account.configPath)
                .appendingPathComponent(AgentDefaults.claudeProjectsSubdirectory)
                .appendingPathComponent(slug)

            let files: [URL]
            do {
                files = try fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.contentModificationDateKey]
                )
            } catch {
                let cocoa = error as NSError
                if cocoa.domain != NSCocoaErrorDomain
                    || cocoa.code != CocoaError.fileReadNoSuchFile.rawValue {
                    failures += 1
                }
                continue
            }

            found.append(contentsOf: files.compactMap { url -> ImportableSession? in
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
                    lastActiveAt: lastActivity(at: url)
                )
            })
        }
        return ScanBatch(sessions: found, failures: failures)
    }

    /// A transcript's title and the directory it was launched in.
    ///
    /// The title is the agent's own — the transcript's title records, which Claude re-appends
    /// every turn, so `SessionNaming` reads them from the file's *tail* where the current pair
    /// sits. The opening message is the fallback until one exists. `cwd` sits on every record,
    /// so the front scan stops as soon as it has both of its answers.
    static func claudeInfo(at url: URL) -> (title: String?, cwd: String?) {
        var firstMessage: String?
        var cwd: String?

        JSONLReader.forEachRecord(at: url, limit: ImportDefaults.claudeScanLimit) { record in
            if cwd == nil, let value = record["cwd"] as? String, !value.isEmpty {
                cwd = value
            }

            if firstMessage == nil,
               record["type"] as? String == ImportDefaults.claudeUserType,
               let message = record["message"] as? [String: Any] {
                firstMessage = userText(from: message["content"])
            }

            return cwd == nil || firstMessage == nil
        }

        return (SessionNaming.claudeTranscriptTitle(at: url) ?? firstMessage, cwd)
    }

    /// The first thing the user typed into a Claude transcript, for naming a session whose
    /// agent never titled it.
    static func claudeFirstPrompt(at url: URL) -> String? {
        var first: String?

        JSONLReader.forEachRecord(at: url, limit: ImportDefaults.claudeScanLimit) { record in
            guard record["type"] as? String == ImportDefaults.claudeUserType,
                  let message = record["message"] as? [String: Any],
                  let text = userText(from: message["content"])
            else { return true }

            first = text
            return false
        }

        return first
    }

    // MARK: - Codex

    /// Codex files rollouts by date, recording the launch directory inside each, so matching
    /// means reading the header of every rollout.
    private static func codexSessions(
        inFolder folder: String,
        worktree: String?,
        accounts: [AgentAccount]
    ) -> ScanBatch {
        let fileManager = FileManager.default
        var found: [ImportableSession] = []
        var failures = 0
        for account in accounts {
            // One small account-wide read before the rollout walk. A retained Codex name lives
            // here rather than in the rollout, and using it during import avoids making a
            // dormant conversation wait for its first resume (or the next app launch) before
            // the sidebar learns the name the provider already knows.
            let providerTitles = CodexTranscript.titles(account: account)
            let root = URL(fileURLWithPath: account.configPath)
                .appendingPathComponent(AgentAccountDefaults.sessionsSubdirectory)

            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else {
                if fileManager.fileExists(atPath: root.path) { failures += 1 }
                continue
            }

            found.append(contentsOf: enumerator.compactMap { element -> ImportableSession? in
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
                guard let promptTitle = codexTitle(at: url) else { return nil }

                return ImportableSession(
                    agentSessionID: header.id,
                    kind: .codex,
                    accountHandle: account.handle,
                    title: providerTitles[header.id] ?? promptTitle,
                    lastActiveAt: lastActivity(at: url)
                )
            })
        }
        return ScanBatch(sessions: found, failures: failures)
    }

    /// Reads a rollout's `session_meta` header — its identifier and launch directory.
    ///
    /// The header cannot be read with a fixed byte cap: `session_meta` carries the session's
    /// instructions, so the record runs to tens of kilobytes and varies per project. Reading
    /// whole records and stopping after the first keeps this correct whatever its length.
    static func codexHeader(at url: URL) -> (id: TranscriptID, cwd: String)? {
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
    static func codexTitle(at url: URL) -> String? {
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
    /// Extracts readable text from a message body and turns it into a title through
    /// `SessionNaming.promptTitle`, which skips the blocks both CLIs inject ahead of the
    /// user's own words — instructions, environment context, command caveats.
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
        return SessionNaming.promptTitle(from: raw)
    }

    /// When the conversation itself last moved.
    ///
    /// The file's modification date is the obvious answer and is wrong in the ordinary case.
    /// Both CLIs write bookkeeping into a transcript long after its conversation ended — Claude
    /// re-appends `last-prompt` and `bridge-session` records, and a launch rewrites them across
    /// a whole directory at once — so the mtimes of a project's transcripts collapse onto
    /// whenever an agent was last started. This project had seven conversations all reading
    /// "4 min ago" in the import sheet, sorted above each other by nothing: their last real
    /// turns were eight to nine hours apart, and exactly one of them was live.
    ///
    /// The tail carries the answer, because those bookkeeping records are the ones that carry
    /// no timestamp: the newest record that *has* one is the last thing that actually happened.
    /// Reading backwards is what makes this cheap — 273 of this project's 276 transcripts
    /// answer within 7 KB of the end, so the usual file costs one chunk however large it is.
    ///
    /// The scan is bounded and falls back to the modification date, so a transcript whose tail
    /// is nothing but bookkeeping answers the old way rather than being read to the top.
    static func lastActivity(at url: URL) -> Date {
        var found: Date?

        JSONLReader.forEachRecordFromEnd(at: url, limit: ImportDefaults.activityTailLimit) {
            record in
            guard let date = TranscriptTimestamp.of(record) else { return true }

            found = date
            return false
        }

        return found ?? modificationDate(of: url)
    }

    static func modificationDate(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
    }

    static func normalized(_ path: String) -> String {
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

    /// How far back from the end `lastActivity` looks for a timestamped record. Generous
    /// against what the corpus needs — the deepest Codex rollout here answers within 220 KB and
    /// almost every Claude transcript within 7 KB — because the cost is only paid by a file
    /// that has no answer, and reading stops at the first record that does.
    static let activityTailLimit = 512 * 1024

    /// Codex buries the opening turn behind its telemetry, and compaction pushes it further
    /// still, so the search has to reach well past where the record usually sits. Reading
    /// stops at the opening turn, so this ceiling is only paid by a session that has none.
    static let codexScanLimit = 8 * 1024 * 1024

    static let titleLimit = 80
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

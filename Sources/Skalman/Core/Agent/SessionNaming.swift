import Foundation

/// Derives session names from the places a name actually exists: the user's explicit rename,
/// the title the agent gives its own conversation, and the first thing the user asked.
///
/// The rule this encodes: **a session is never named after its agent or account.** The sidebar
/// already says which agent and which login a row belongs to — the icon slot and the account
/// chip exist for exactly that — so "Claude Code 2" as a *name* repeats what two other elements
/// show while saying nothing about the conversation. Names that are really the agent's product
/// name, the account's alias or the project's own name are treated as absent wherever they
/// arrive, and the display falls through to something that describes the conversation.
///
/// Claude records both kinds of title in the transcript, as different record types — measured
/// across this machine's transcripts rather than assumed:
///
/// - `ai-title` is the CLI's own name for the conversation, re-appended every turn and
///   occasionally rewritten as the conversation develops, so the *last* one is current.
/// - `custom-title` is written by `/rename` — and by a `--name` launch flag, which is why
///   `AgentSession.launchName` only forwards a name the user chose. A conversation with a
///   custom title stops generating `ai-title` records (9 of 10 launch-named transcripts here
///   held none), so passing a default name at launch would switch the agent's own naming off.
/// - After a mid-conversation `/rename` both records keep being re-appended, interleaved, so
///   presence decides: any custom title outranks any AI title, regardless of order.
///
/// Codex records no title at all; its sessions are named from the first prompt.
enum SessionNaming {

    // MARK: - Prompt Titles

    /// A default name derived from what the user asked: the first line, capped, or nil when
    /// the text is empty or one of the blocks the CLIs inject ahead of the user's own words.
    static func promptTitle(from prompt: String) -> String? {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !ImportDefaults.injectedPrefixes.contains(where: { trimmed.hasPrefix($0) })
        else { return nil }

        let firstLine = trimmed.split(separator: "\n").first.map(String.init) ?? trimmed
        return String(firstLine.prefix(ImportDefaults.titleLimit))
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Placeholder and Noise Detection

    /// Whether a stored creation title says nothing about the conversation: empty, the old
    /// agent-or-account naming scheme ("Claude Code 2", "claudedb 3"), or a generic label.
    /// Such a title may be replaced by one derived from the first prompt.
    static func isPlaceholderTitle(
        _ title: String,
        kind: AgentKind,
        accountDisplayName: String?
    ) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        return placeholderBases(kind: kind, accountDisplayName: accountDisplayName)
            .contains(strippingCounter(trimmed).lowercased())
    }

    /// The narrower question: whether a title *is* the agent's or account's name — the part
    /// of the old scheme worth actively removing. A generic label ("Side Chat") is also a
    /// placeholder, but it beats the fallback it would be cleared to, so it is only ever
    /// *replaced* by something better, never dropped.
    static func isAgentDerivedTitle(
        _ title: String,
        kind: AgentKind,
        accountDisplayName: String?
    ) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        var bases: Set<String> = [kind.displayName.lowercased()]
        if let accountDisplayName, !accountDisplayName.isEmpty {
            bases.insert(accountDisplayName.lowercased())
        }

        return bases.contains(strippingCounter(trimmed).lowercased())
    }

    /// Whether an agent-reported title is the product, account or project name rather than a
    /// name for the conversation. Claude's TUI titles itself "Claude Code" until it has an AI
    /// title; Codex titles itself after the working directory; older launches echoed the
    /// `--name` this app used to pass. None of those name the conversation, so none is worth
    /// displacing a real title — or the prompt-derived fallback — for.
    static func isNoiseTitle(
        _ title: String,
        kind: AgentKind,
        accountDisplayName: String?,
        projectName: String,
        folderBasename: String
    ) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        var bases = placeholderBases(kind: kind, accountDisplayName: accountDisplayName)
        bases.insert(kind.executableName.lowercased())
        bases.insert(projectName.lowercased())
        bases.insert(folderBasename.lowercased())

        return bases.contains(strippingCounter(trimmed).lowercased())
    }

    /// The names the old creation scheme produced, lowercased: the agent's product name, the
    /// account's display name, and the generic labels a session starts with.
    private static func placeholderBases(
        kind: AgentKind,
        accountDisplayName: String?
    ) -> Set<String> {
        var bases: Set<String> = [
            kind.displayName.lowercased(),
            AgentDefaults.untitledSessionName.lowercased(),
            AgentDefaults.sideChatTitle.lowercased()
        ]

        if let accountDisplayName, !accountDisplayName.isEmpty {
            bases.insert(accountDisplayName.lowercased())
        }

        return bases
    }

    /// Drops the trailing counter the old scheme numbered repeats with ("Claude Code 2").
    private static func strippingCounter(_ title: String) -> String {
        guard let lastSpace = title.lastIndex(of: " "),
              Int(title[title.index(after: lastSpace)...]) != nil
        else { return title }

        return String(title[..<lastSpace])
    }

    // MARK: - Claude Transcript Titles

    /// The agent's current name for a Claude conversation, read from its transcript: the last
    /// `custom-title` if any exists (a `/rename` is the user's explicit choice), else the last
    /// `ai-title`.
    ///
    /// Both records are re-appended every turn, so the current pair sits near the file's end
    /// and a tail read finds it without paying for the conversation. The full scan behind it
    /// covers the one shape the tail misses — a single enormous turn appended since the last
    /// title record — and transcripts that predate per-turn re-appending.
    static func claudeTranscriptTitle(at url: URL) -> String? {
        if let title = titleRecords(inTailOf: url) { return title }
        return titleRecords(scanningWholeOf: url)
    }

    private static func titleRecords(inTailOf url: URL) -> String? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }

        guard let size = try? file.seekToEnd(), size > 0 else { return nil }

        let tailBytes = UInt64(SessionNamingDefaults.titleTailBytes)
        let offset = size > tailBytes ? size - tailBytes : 0
        try? file.seek(toOffset: offset)

        guard let data = try? file.readToEnd(), !data.isEmpty else { return nil }

        var lines = data.split(separator: UInt8(ascii: "\n"))
        if offset > 0, !lines.isEmpty {
            // The window almost certainly opened mid-record; the fragment is not JSON.
            lines.removeFirst()
        }

        var aiTitle: String?
        var customTitle: String?

        for line in lines {
            guard let record = try? JSONSerialization.jsonObject(with: Data(line))
                    as? [String: Any] else { continue }
            readTitleRecord(record, aiTitle: &aiTitle, customTitle: &customTitle)
        }

        return customTitle ?? aiTitle
    }

    private static func titleRecords(scanningWholeOf url: URL) -> String? {
        var aiTitle: String?
        var customTitle: String?

        JSONLReader.forEachRecord(at: url, limit: SessionNamingDefaults.titleScanLimit) { record in
            readTitleRecord(record, aiTitle: &aiTitle, customTitle: &customTitle)
            return true
        }

        return customTitle ?? aiTitle
    }

    private static func readTitleRecord(
        _ record: [String: Any],
        aiTitle: inout String?,
        customTitle: inout String?
    ) {
        switch record["type"] as? String {
        case SessionNamingDefaults.claudeAITitleType:
            if let value = record["aiTitle"] as? String, !value.isEmpty { aiTitle = value }
        case SessionNamingDefaults.claudeCustomTitleType:
            if let value = record["customTitle"] as? String, !value.isEmpty { customTitle = value }
        default:
            break
        }
    }

    // MARK: - Refresh

    /// Re-reads a Claude session's transcript title, called when the session stops working —
    /// the same edge that re-reads the branch, and for the same reason: the turn that just
    /// ended is when the name is most likely to have moved.
    ///
    /// This is what names a *native* session, which has no terminal to report a title over,
    /// and what carries a title across a surface switch. Codex has no transcript title to
    /// read, so its sessions keep their prompt-derived name.
    @MainActor
    static func refreshAgentTitle(forSessionID sessionID: SessionID) {
        guard let session = ProjectStore.shared.session(withID: sessionID),
              session.kind == .claude,
              let transcriptID = session.resumeState.transcriptID,
              let project = ProjectStore.shared.project(forSessionID: sessionID),
              let url = ClaudeTranscript.url(sessionID: transcriptID, for: session, in: project)
        else { return }

        DispatchQueue.global(qos: .utility).async {
            guard let title = claudeTranscriptTitle(at: url) else { return }

            DispatchQueue.main.async {
                ProjectStore.shared.updateAgentTitle(title, for: sessionID)
            }
        }
    }

    // MARK: - Backfill

    /// One pass over the stored sessions, replacing names the old creation scheme left behind.
    ///
    /// Sessions used to be *named* after their agent or account and launched with that name as
    /// a `--name` flag, so existing records hold "Claude Code 2" as a title and echo it as an
    /// agent title. This clears the echoes, drops agent-derived titles to empty (the display
    /// falls back to a generic label, never the agent's name), and re-derives what the
    /// transcripts can still provide — the agent's own title, and a first-prompt name. A
    /// merely *generic* title ("Side Chat") is kept until something better exists: it beats
    /// the label it would be cleared to.
    ///
    /// The reads run off the main queue — resolving a Codex rollout path enumerates the whole
    /// sessions tree, which is exactly the kind of walk a launch must not wait on — and every
    /// write re-checks the session on arrival, so a title the user or a live agent supplied
    /// in the meantime is never overwritten.
    @MainActor
    static func backfillLegacyNames() {
        struct Reading {
            let sessionID: SessionID
            let kind: AgentKind
            let accountDisplayName: String?
            let transcript: Transcript
        }

        enum Transcript {
            case at(URL)
            case codexRollout(AgentAccount, TranscriptID)
        }

        var readings: [Reading] = []

        for project in ProjectStore.shared.projects {
            let folderBasename = project.folderURL.lastPathComponent

            for session in project.sessions {
                let account = AgentAccountDiscovery.account(
                    for: session.kind,
                    handle: session.accountHandle
                )

                // Echoes of the old `--name` flag, and Codex titling itself after the
                // working directory: not names, whatever else happens below.
                if let agentTitle = session.agentTitle, isNoiseTitle(
                    agentTitle,
                    kind: session.kind,
                    accountDisplayName: account?.displayName,
                    projectName: project.name,
                    folderBasename: folderBasename
                ) {
                    ProjectStore.shared.update(sessionID: session.id) { $0.agentTitle = nil }
                }

                // An explicit rename wins over everything a backfill could derive.
                guard session.customTitle == nil else { continue }

                guard isPlaceholderTitle(
                    session.title,
                    kind: session.kind,
                    accountDisplayName: account?.displayName
                ) else { continue }

                // Only a title that *is* the agent's or account's name goes unconditionally:
                // an empty slot displays as a generic label, which is an improvement on
                // "Claude Code 2" and a downgrade from "Side Chat".
                if isAgentDerivedTitle(
                    session.title,
                    kind: session.kind,
                    accountDisplayName: account?.displayName
                ) {
                    ProjectStore.shared.update(sessionID: session.id) { $0.title = "" }
                }

                guard let transcriptID = session.resumeState.transcriptID else { continue }

                let transcript: Transcript?
                switch session.kind {
                case .claude:
                    transcript = ClaudeTranscript
                        .url(sessionID: transcriptID, for: session, in: project)
                        .map(Transcript.at)
                case .codex:
                    transcript = account.map { .codexRollout($0, transcriptID) }
                }

                guard let transcript else { continue }
                readings.append(Reading(
                    sessionID: session.id,
                    kind: session.kind,
                    accountDisplayName: account?.displayName,
                    transcript: transcript
                ))
            }
        }

        guard !readings.isEmpty else { return }

        DispatchQueue.global(qos: .utility).async {
            for reading in readings {
                let url: URL?
                switch reading.transcript {
                case .at(let known):
                    url = known
                case .codexRollout(let account, let transcriptID):
                    url = CodexTranscript.url(sessionID: transcriptID, account: account)
                }
                guard let url else { continue }

                let agentTitle = reading.kind == .claude ? claudeTranscriptTitle(at: url) : nil
                let promptTitle: String?
                switch reading.kind {
                case .claude: promptTitle = SessionImporter.claudeFirstPrompt(at: url)
                case .codex: promptTitle = SessionImporter.codexTitle(at: url)
                }

                guard agentTitle != nil || promptTitle != nil else { continue }

                DispatchQueue.main.async {
                    ProjectStore.shared.update(sessionID: reading.sessionID) { session in
                        if let agentTitle, session.agentTitle == nil {
                            session.agentTitle = agentTitle
                        }

                        // Re-checked on arrival: still nothing but a placeholder, and still
                        // no name the user chose in the meantime.
                        if let promptTitle, session.customTitle == nil, isPlaceholderTitle(
                            session.title,
                            kind: session.kind,
                            accountDisplayName: reading.accountDisplayName
                        ) {
                            session.title = promptTitle
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Defaults

enum SessionNamingDefaults {
    /// Window read from a transcript's end when looking for its current title records. Claude
    /// re-appends them every turn, so one turn's worth of records is nearly always enough.
    static let titleTailBytes = 256 * 1024

    /// Bound for the fallback whole-file scan, guarding against a pathological file rather
    /// than any real transcript.
    static let titleScanLimit = 256 * 1024 * 1024

    static let claudeAITitleType = "ai-title"
    static let claudeCustomTitleType = "custom-title"
}

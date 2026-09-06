import Foundation

/// How far a transcript lookup may go to answer.
///
/// A Claude transcript uses its reported live path or a computed fallback, so the effort makes
/// no difference to it. A Codex rollout is *found*: its name carries a timestamp
/// nobody recorded, so placing one means reading the account's whole sessions tree, and that
/// is the work a caller with a catalogue of conversations must not do once per conversation
/// on the main actor.
enum TranscriptLookupEffort: Sendable {
    /// Read the filesystem when nothing is known yet. The answer for one conversation.
    case discovering
    /// Answer only from what earlier lookups already found. The answer for a projection of the
    /// whole catalogue on the main actor, which has `CodexTranscript.rolloutIndex` read each
    /// account's tree once, off it, and then asks again.
    case known
}

/// The single source-selection boundary for transcript readers. Capture live location state
/// before background work, and keep computed storage destinations separate from read sources.
/// Capability-specific readers may ask through ClaudeTranscript's convenience API; it delegates
/// here too. Codex discovery remains deferred for background replay and catalogue prewarming.
enum SessionTranscript {

    /// Capture on the main actor, resolve on the worker that will read the file. Claude's live
    /// location must be captured before leaving the actor; Codex's directory walk stays deferred.
    enum ReadRequest: Sendable {
        case file(URL)
        case codexRollout(TranscriptID, AgentAccount)

        func resolve(effort: TranscriptLookupEffort = .discovering) -> URL? {
            switch self {
            case .file(let url):
                return url
            case .codexRollout(let id, let account):
                switch effort {
                case .discovering: return CodexTranscript.url(sessionID: id, account: account)
                case .known: return CodexTranscript.knownURL(sessionID: id, account: account)
                }
            }
        }
    }

    // MARK: - Public Methods

    /// The transcript for a conversation under a known account.
    ///
    /// Nil where the runtime keeps no transcript Threading can read. That is a statement about
    /// the reader, not about the runtime's own storage: OpenCode and Grok both persist their
    /// conversations, and neither has a format this app parses.
    @MainActor
    static func readRequest(
        sessionID: TranscriptID,
        for session: AgentSession,
        in project: Project,
        account: AgentAccount,
        locations: ClaudeTranscriptLocations = .shared
    ) -> ReadRequest? {
        guard account.provider == session.kind, account.handle == session.accountHandle else { return nil }
        switch session.kind {
        case .claude:
            let observed = sessionID == session.resumeState.transcriptID
                ? locations.url(for: session, account: account) : nil
            guard let url = observed ?? ClaudeTranscript.storageURL(
                sessionID: sessionID, account: account, in: project
            ) else { return nil }
            return .file(url)
        case .codex:
            return .codexRollout(sessionID, account)
        case .grok, .openCode, .cursor:
            return nil
        }
    }

    @MainActor
    static func url(
        sessionID: TranscriptID,
        for session: AgentSession,
        in project: Project,
        account: AgentAccount,
        effort: TranscriptLookupEffort = .discovering
    ) -> URL? {
        readRequest(sessionID: sessionID, for: session, in: project, account: account)?
            .resolve(effort: effort)
    }

    /// Whether the runtime's transcript is found by reading a directory rather than by
    /// computing a path — the runtimes for which `.known` can answer differently from
    /// `.discovering`, and whose sessions tree a catalogue projection reads once, off the
    /// main actor, before it asks.
    static func locatesTranscriptByWalking(_ kind: AgentKind) -> Bool {
        switch kind {
        case .codex:
            return true
        case .claude, .grok, .openCode, .cursor:
            return false
        }
    }

    /// The same, for a session that has a conversation and an account of its own.
    ///
    /// Nil when the session has yet to be given an identifier, when its account cannot be
    /// found, or when its runtime keeps no readable transcript.
    ///
    /// Account discovery and source selection stay on the main actor. A background reader
    /// captures a `ReadRequest` before dispatching rather than recomputing a storage path there.
    @MainActor
    static func url(for session: AgentSession, in project: Project) -> URL? {
        guard let sessionID = session.resumeState.transcriptID,
              let account = AgentAccountDiscovery.account(
                for: session.kind,
                handle: session.accountHandle
              )
        else { return nil }

        return url(sessionID: sessionID, for: session, in: project, account: account)
    }

    /// The transcript that is on disk right now, or nil.
    ///
    /// A path is not a file: an identifier is minted before the CLI has written anything, so a
    /// caller that means "there is a conversation to move" has to ask the filesystem.
    @MainActor
    static func existingURL(for session: AgentSession, in project: Project) -> URL? {
        guard let url = url(for: session, in: project),
              FileManager.default.fileExists(atPath: url.path)
        else { return nil }

        return url
    }
}

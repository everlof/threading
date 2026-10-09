import Foundation

/// How far a transcript lookup may go to answer.
///
/// A Claude transcript uses its reported live path or a computed fallback, and the effort only
/// decides whether that fallback may resolve the folder's symlinks and ask which of its two
/// spellings holds the file (`ClaudeTranscript.StorageSlot`). A Codex rollout is *found*: its
/// name carries a timestamp nobody recorded, so placing one means reading the account's whole
/// sessions tree, and that is the work a caller with a catalogue of conversations must not do
/// once per conversation on the main actor.
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
        case claudeStorage(ClaudeTranscript.StorageSlot)
        case codexRollout(TranscriptID, AgentAccount)

        func resolve(effort: TranscriptLookupEffort = .discovering) -> URL? {
            switch self {
            case .file(let url):
                return url
            case .claudeStorage(let slot):
                return slot.resolve(effort: effort)
            case .codexRollout(let id, let account):
                switch effort {
                case .discovering: return CodexTranscript.url(sessionID: id, account: account)
                case .known: return CodexTranscript.knownURL(sessionID: id, account: account)
                }
            }
        }
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
}

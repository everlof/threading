import Foundation

// MARK: - Claude Turn Interruption

/// A Claude terminal turn the user stopped by hand, as the CLI writes it into the session's own
/// transcript.
struct ClaudeTurnInterruption: Equatable, Sendable {

    /// The interrupting record's own identity — its `uuid`.
    ///
    /// Carried for the reason `ClaudeTurnRefusal.recordID` is: `TranscriptFactReader` calls back
    /// only when the answer *moves*, and two turns interrupted in a row are otherwise identical
    /// records. Without an identity per occurrence the second interrupt equals the first, no
    /// callback fires, and that session strands `working` — which is the failure this reader
    /// exists to end.
    let recordID: String

    /// The assistant message the interrupt cut off, where the CLI named one. Nil when nothing had
    /// been said yet — measured on 2.1.222, where a prompt stopped before the first token wrote
    /// the marker with no `interruptedMessageId` beside it, because there was no message to name.
    let interruptedMessageID: String?
}

// MARK: - Claude Transcript Interruption

/// Reads whether a Claude **terminal** session's conversation ends on a turn the user interrupted.
///
/// Nothing else tells the app. Claude fires `UserPromptSubmit`, the user presses Escape, and the
/// CLI appends the marker below and returns to its prompt **without firing `Stop`** — measured on
/// 2.1.238, where the last record of session `a056a54c` was written at 06:17:52Z and no further
/// hook arrived for the two hours the row went on drawing a spinner:
///
/// ```json
/// {"type":"user","uuid":"5ec9af64-…","interruptedMessageId":"msg_011CeFQXqQY5Z7Ur3FJfZckF",
///  "message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}
/// ```
///
/// The turn start has already latched `reportsOwnActivity`, so the tracker correctly refuses to
/// fall back to counting terminal bytes, and the session draws a spinner for a conversation the
/// user stopped themselves — in the sidebar, and for `watch_session` and every waiting sibling
/// delivery as well.
///
/// This is the fourth instance of that one shape, and the second of it Claude has.
/// `ClaudeTranscriptUsageLimit` covers the refusal whose reason is the spent allowance,
/// `ClaudeTranscriptTurnRefusal` covers the request that failed outright,
/// `CodexTranscriptTurnBoundary` covers the same Escape on the other runtime, and this covers the
/// Escape here. All four close the same hole: a reported session whose last turn boundary never
/// arrived.
///
/// **Both signals in the record are read, and either alone is enough**, for the reason
/// `ClaudeTranscriptAPIError` reads both of its own: the id is the structured half and is what a
/// reader should prefer, but the CLI writes no id at all when the interrupt beats the first token,
/// and a reader insisting on it answers nothing for a turn stopped early — which is the interrupt
/// a user is most likely to press.
///
/// The caching, the size gate and the background hop are `TranscriptFactReader`'s. The scan is
/// `ClaudeTranscriptAPIError`'s newest-message walk, shared with the two failure readers so the
/// three cannot drift about which record ends a turn.
@MainActor
enum ClaudeTranscriptInterruption {

    // MARK: - Properties

    private static let reader = TranscriptFactReader<ClaudeTurnInterruption> { url in
        newestInterruption(at: url)
    }

    // MARK: - Public Methods

    /// Re-reads in the background when the transcript has grown, calling back only if the answer
    /// changed.
    static func revalidate(
        at url: URL,
        completion: @escaping @MainActor @Sendable (ClaudeTurnInterruption?) -> Void
    ) {
        reader.revalidate(at: url, completion: completion)
    }

    /// Forgets what has been read. For tests, and for a reset that should re-ask.
    static func forgetAll() {
        reader.forgetAll()
    }

    /// The interruption the conversation ends on, or nil when it ended on anything else.
    ///
    /// The boundary is the newest *message*, not the newest line: the CLI appends bookkeeping
    /// after an interrupt — `file-history-snapshot`, `attachment`, `system` — and none of it is
    /// the conversation speaking. What does clear the answer is either side speaking again, which
    /// is why a session resumed onto a transcript that still ends on last week's Escape is not
    /// stopped by it.
    ///
    /// Kept off the actor so the read itself is testable without a queue — the same split the
    /// readers beside it keep. Callers in the app should ask `revalidate`; this touches the disk.
    nonisolated static func newestInterruption(at url: URL) -> ClaudeTurnInterruption? {
        guard let record = ClaudeTranscriptAPIError.newestMessage(
            at: url,
            limit: ClaudeInterruptionDefaults.scanBytes
        ) else { return nil }

        return interruption(in: record)
    }

    /// The interruption one transcript record states, or nil when it states none. Kept visible to
    /// focused wire tests.
    ///
    /// A user record whose whole content is the marker is admitted even without the id. That
    /// leaves one shape this cannot tell apart: a user who types the marker sentence verbatim as
    /// their own prompt. It ends the turn that prompt just started, a beat early and with the
    /// session correctly idle afterwards, which is a smaller cost than declining every interrupt
    /// pressed before the model spoke.
    nonisolated static func interruption(in record: [String: Any]) -> ClaudeTurnInterruption? {
        guard record[ClaudeAPIErrorDefaults.typeKey] as? String
            == ClaudeInterruptionDefaults.userType else { return nil }

        let interruptedMessageID = text(record[ClaudeInterruptionDefaults.interruptedMessageKey])
        guard interruptedMessageID != nil || statesTheMarker(record) else { return nil }

        return ClaudeTurnInterruption(
            recordID: ClaudeTranscriptAPIError.identity(of: record),
            interruptedMessageID: interruptedMessageID
        )
    }

    // MARK: - Private Methods

    /// Whether the record's whole message is the CLI's interrupt marker.
    ///
    /// One text block and nothing else. A tool result carrying the sentence in its output is a
    /// `tool_result` block, and a prompt that merely quotes it has the quote alongside the rest of
    /// what was typed; neither is this.
    ///
    /// **Deliberately all-or-nothing**, unlike every other `content` read on this side. The
    /// classification *is* "and nothing else": recovering the readable elements would make
    /// `blocks.count == 1` mean "one block we could read" rather than "one block", so a message
    /// holding the marker beside something unreadable would be reported as an interrupt the user
    /// never pressed. Refusing costs an interrupt annotation on a record that is already
    /// malformed; recovering would invent a fact about what somebody did.
    private nonisolated static func statesTheMarker(_ record: [String: Any]) -> Bool {
        guard let message = record[ClaudeAPIErrorDefaults.messageKey] as? [String: Any],
              let blocks = message[ClaudeAPIErrorDefaults.contentKey] as? [[String: Any]],
              blocks.count == 1,
              let text = blocks[0][ClaudeAPIErrorDefaults.textKey] as? String
        else { return false }

        return text.hasPrefix(ClaudeInterruptionDefaults.markerPrefix)
    }

    /// A field's string, or nil when the key is absent *or* present and empty — the same fact,
    /// kept the same way `ClaudeTranscriptAPIError` keeps it.
    private nonisolated static func text(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }
}

// MARK: - Defaults

enum ClaudeInterruptionDefaults {
    /// No quiet delay of its own: this fact and the refusal share one scheduler on one output
    /// burst, and the beat they wait for is `ClaudeRefusalDefaults.quietDelay`.
    ///
    /// One chunk of tail, like every other bounded transcript scan here. A boundary hidden behind
    /// an exceptional record larger than this is left to the ordinary hook rather than turning a
    /// terminal-output callback into a whole-transcript read.
    static let scanBytes = JSONLDefaults.chunkBytes

    /// The interrupt is written as the user speaking, because that is what pressing Escape is.
    static let userType = "user"

    /// The assistant message the interrupt cut off. Absent when it cut off nothing.
    static let interruptedMessageKey = "interruptedMessageId"

    /// Matched as a prefix rather than in full: 2.1.220 onward writes
    /// `[Request interrupted by user for tool use]` for the same Escape pressed during a tool
    /// call, and the two mean one thing to this reader.
    static let markerPrefix = "[Request interrupted by user"
}

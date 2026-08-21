import Foundation

// MARK: - Claude Turn Refusal

/// A turn Claude's CLI gave up on for something other than the account's allowance.
struct ClaudeTurnRefusal: Equatable, Sendable {

    /// The failing record's own identity — its `uuid`.
    ///
    /// Carried because `TranscriptFactReader` calls back only when the answer *moves*, and two
    /// consecutive turns refused by an expired login write the same class and the same sentence.
    /// Without an identity per occurrence the second refusal is equal to the first, no callback
    /// fires, and the session it belongs to strands `working` — the exact failure this reader
    /// exists to end. The turn's own user record ordinarily lands between them and moves the
    /// answer to nil, but a login failure arrives half a second after the prompt, well inside one
    /// settled output burst, so that gap cannot be relied on.
    let recordID: String

    /// The provider's class for the failure, for the journal: `authentication_failed`,
    /// `connection_error`.
    let reason: String

    /// The sentence the CLI printed, for the journal. Empty where it printed none.
    let message: String
}

// MARK: - Claude Transcript Turn Refusal

/// Reads whether a Claude **terminal** session's last exchange ended in a failure that is not a
/// usage limit — an expired login, a dropped connection, an overloaded endpoint.
///
/// Nothing else tells the app. Claude fires `UserPromptSubmit`, discovers it cannot make the
/// request, prints a sentence and returns to its prompt **without firing `Stop`** — measured on
/// 2.1.226, where a login that had expired produced an `error: "authentication_failed"` record
/// 481 ms after the prompt, a `turn_duration` of 23 ms beside it, and no further hook. The turn
/// start has already latched `reportsOwnActivity`, so the tracker correctly refuses to fall back
/// to counting terminal bytes, and the session draws a spinner for a conversation that stopped —
/// for hours, and for `watch_session` and every waiting sibling delivery as well.
///
/// This is the third instance of that one shape. `ClaudeTranscriptUsageLimit` covers the refusal
/// whose reason is the spent allowance, `CodexTranscriptInterruption` covers a Codex turn the
/// user stopped by hand, and this covers what is left: the request that failed. The three read
/// different records and settle differently — a spent account is `limitReached` and has a
/// recovery, an interrupt and a failure are simply turns that ended — but they close the same
/// hole, which is a reported session whose last boundary never arrived.
///
/// The caching, the size gate and the background hop are `TranscriptFactReader`'s. The scan is
/// `ClaudeTranscriptAPIError`'s newest-message walk, shared with the limit reader so the two
/// cannot drift about which failures belong to which.
@MainActor
enum ClaudeTranscriptTurnRefusal {

    // MARK: - Properties

    private static let reader = TranscriptFactReader<ClaudeTurnRefusal> { url in
        newestRefusal(at: url)
    }

    // MARK: - Public Methods

    /// Re-reads in the background when the transcript has grown, calling back only if the answer
    /// changed.
    static func revalidate(
        at url: URL,
        completion: @escaping @MainActor @Sendable (ClaudeTurnRefusal?) -> Void
    ) {
        reader.revalidate(at: url, completion: completion)
    }

    /// Forgets what has been read. For tests, and for a reset that should re-ask.
    static func forgetAll() {
        reader.forgetAll()
    }

    /// The failure the conversation ends on, or nil when it ended on anything else.
    ///
    /// A rate-limit refusal answers nil here on purpose: it is the same record shape, but it has
    /// a park, a reset and a recovery policy of its own, and admitting it twice would end the
    /// turn from under `LimitRecoveryCoordinator` before it could read the chooser.
    ///
    /// Kept off the actor so the read itself is testable without a queue — the same split the
    /// readers beside it keep. Callers in the app should ask `revalidate`; this touches the disk.
    nonisolated static func newestRefusal(at url: URL) -> ClaudeTurnRefusal? {
        guard let record = ClaudeTranscriptAPIError.newestMessage(
            at: url,
            limit: ClaudeRefusalDefaults.scanBytes
        ),
            let failure = ClaudeTranscriptAPIError.parse(record),
            !failure.isRateLimit
        else { return nil }

        return ClaudeTurnRefusal(
            recordID: ClaudeTranscriptAPIError.identity(of: record),
            reason: failure.reason ?? ClaudeRefusalDefaults.unstatedReason,
            message: failure.text ?? ""
        )
    }
}

// MARK: - Defaults

enum ClaudeRefusalDefaults {
    /// How long an output burst must settle before the transcript is revalidated. The CLI paints
    /// its error and its prompt in several frames, and one read after they stop is the whole
    /// cost — the same beat `CodexInterruptionDefaults` keeps for the same reason.
    ///
    /// It is the beat for both of Claude's boundary reads: `scheduleClaudeBoundaryRefresh` asks
    /// this reader and `ClaudeTranscriptInterruption` on one quiet edge, since they answer off the
    /// same tail of the same file on the same burst.
    static let quietDelay: TimeInterval = 0.5

    /// One chunk of tail, like every other bounded transcript scan here. A boundary hidden behind
    /// an exceptional record larger than this is left to the ordinary hook rather than turning a
    /// terminal-output callback into a whole-transcript read.
    static let scanBytes = JSONLDefaults.chunkBytes

    /// Journalled where the record carried a status but no class for it.
    static let unstatedReason = "unstated"
}

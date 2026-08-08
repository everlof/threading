import Foundation

// MARK: - Claude Transcript Usage Limit

/// Whether a Claude **terminal** session's last exchange was refused for a spent usage limit,
/// read back from its own transcript.
///
/// Nothing else tells the app. A refused request raises no lifecycle hook — there is no turn to
/// start and none to finish — and the CLI answers the user by printing a sentence into its TUI,
/// which the host sees only as bytes. So a session that stopped at its limit went on drawing
/// whatever it was drawing before: a spinner, for hours, for a conversation that had already
/// stopped. See [`session-activity.md`](../../../../docs/architecture/session-activity.md).
///
/// Claude writes the refusal down as a synthetic assistant record:
///
/// ```json
/// {"type":"assistant","isApiErrorMessage":true,"error":"rate_limit","apiErrorStatus":429,
///  "message":{"model":"<synthetic>","content":[{"type":"text",
///  "text":"You've hit your session limit · resets 1:20pm (Europe/Rome)"}]}}
/// ```
///
/// Three properties of that record decide the shape of this reader.
///
/// **The flag is the fact; the text is only the words.** `error` and `apiErrorStatus` say a
/// request was refused for the limit whatever the sentence reads like, so a CLI that rewords
/// itself still stops the session — `UsageLimitStop.recognised(in:)` is asked for the reset hint
/// and not for permission.
///
/// **It is the newest *message*, not the newest line.** The CLI appends bookkeeping after it —
/// `turn_duration`, queue operations, file-history snapshots — so the scan walks back past
/// anything that is not a message and lets the first `assistant`/`user` record it meets decide.
/// That is also what clears the stop: the next thing the conversation says, in either direction,
/// is proof it is talking again, so nothing has to remember when the refusal was.
///
/// **A sidechain's refusal is not the session's.** A subagent that runs out of limit is reported
/// to its parent as a failed task, and the parent goes on working — as this app's own
/// `f3ad7546` session did, for five minutes, before the main thread was refused too. Sidechain
/// records are therefore skipped rather than allowed to decide.
///
/// The caching, the size gate and the background hop are `TranscriptFactReader`'s, shared with
/// `ClaudeTranscriptModel` and `ClaudeTranscriptPermissionMode`. Callers in the app should ask
/// `ObservedUsageLimit`, which is where the choice of *which* runtime can answer is made.
@MainActor
enum ClaudeTranscriptUsageLimit {

    // MARK: - Properties

    private static let reader = TranscriptFactReader<UsageLimitStop> { url in
        newestStop(at: url)
    }

    // MARK: - Public Methods

    /// What has already been read for this transcript. Touches no disk, so a caller painting a
    /// view can ask on the main thread.
    static func known(at url: URL) -> UsageLimitStop? {
        reader.known(at: url)
    }

    /// Re-reads in the background when the transcript has grown, calling back only if the answer
    /// changed.
    static func revalidate(
        at url: URL,
        completion: @escaping @MainActor @Sendable (UsageLimitStop?) -> Void
    ) {
        reader.revalidate(at: url, completion: completion)
    }

    /// Forgets what has been read. For tests, and for a reset that should re-ask.
    static func forgetAll() {
        reader.forgetAll()
    }

    /// The refusal the transcript ends on, or nil when the conversation has said anything since.
    ///
    /// Kept out of the memo and off the actor so the read itself is testable without a queue —
    /// the same split the two readers beside it keep. Callers in the app should ask
    /// `known`/`revalidate` instead; this touches the disk.
    nonisolated static func newestStop(at url: URL) -> UsageLimitStop? {
        var stop: UsageLimitStop?
        JSONLReader.forEachRecordFromEnd(at: url, limit: UsageLimitDefaults.scanBytes) { record in
            guard let type = record[TranscriptUsageLimitDefaults.typeKey] as? String,
                  TranscriptUsageLimitDefaults.messageTypes.contains(type),
                  record[TranscriptUsageLimitDefaults.sidechainKey] as? Bool != true
            else { return true }

            guard isRefusal(record) else { return false }

            let text = messageText(in: record)
            stop = UsageLimitStop.recognised(in: text)
                ?? UsageLimitStop(message: text ?? TranscriptUsageLimitDefaults.unstatedRefusal)
            return false
        }
        return stop
    }

    // MARK: - Private Methods

    /// Whether the record is the CLI's own note that a request was refused for the limit.
    ///
    /// Both fields are consulted because they are written by different CLI versions, and either
    /// alone is enough: `error` names the class of failure, `apiErrorStatus` is the status the
    /// endpoint answered. A `429` for any other reason is still an account out of allowance as
    /// far as the session is concerned — it stopped, and nobody typed.
    private nonisolated static func isRefusal(_ record: [String: Any]) -> Bool {
        guard record[TranscriptUsageLimitDefaults.apiErrorKey] as? Bool == true else {
            return false
        }
        if record[TranscriptUsageLimitDefaults.errorKey] as? String
            == TranscriptUsageLimitDefaults.rateLimitError {
            return true
        }
        return status(in: record) == TranscriptUsageLimitDefaults.rateLimitStatus
    }

    /// The status, whether the CLI wrote it as a number or as a string.
    private nonisolated static func status(in record: [String: Any]) -> Int? {
        let value = record[TranscriptUsageLimitDefaults.statusKey]
        if let number = value as? Int { return number }
        return (value as? String).flatMap(Int.init)
    }

    /// The sentence the CLI showed the user, joined across text blocks.
    private nonisolated static func messageText(in record: [String: Any]) -> String? {
        guard let message = record[TranscriptUsageLimitDefaults.messageKey] as? [String: Any],
              let blocks = message[TranscriptUsageLimitDefaults.contentKey] as? [[String: Any]]
        else { return nil }

        let text = blocks
            .compactMap { $0[TranscriptUsageLimitDefaults.textKey] as? String }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

// MARK: - Defaults

enum TranscriptUsageLimitDefaults {
    static let typeKey = "type"
    static let sidechainKey = "isSidechain"
    static let apiErrorKey = "isApiErrorMessage"
    static let errorKey = "error"
    static let statusKey = "apiErrorStatus"
    static let messageKey = "message"
    static let contentKey = "content"
    static let textKey = "text"

    /// The record types that count as the conversation speaking. Everything else the CLI
    /// appends — `system`, `queue-operation`, `summary`, `file-history-snapshot` — is
    /// bookkeeping written *around* a message and says nothing about whether one was refused.
    static let messageTypes: Set<String> = ["assistant", "user"]

    static let rateLimitError = "rate_limit"
    static let rateLimitStatus = 429

    /// Shown when the CLI recorded the refusal but no sentence with it, so a mark still has
    /// something to say rather than an empty line.
    static let unstatedRefusal = L10n.string("Usage limit reached")
}

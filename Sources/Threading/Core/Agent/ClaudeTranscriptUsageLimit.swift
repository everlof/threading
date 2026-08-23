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
/// Claude normally writes the refusal down as a synthetic assistant record:
///
/// ```json
/// {"type":"assistant","isApiErrorMessage":true,"error":"rate_limit","apiErrorStatus":429,
///  "message":{"model":"<synthetic>","content":[{"type":"text",
///  "text":"You've hit your session limit · resets 1:20pm (Europe/Rome)"}]}}
/// ```
///
/// **The flag is the fact; the text is only the words.** `error` and `apiErrorStatus` say a
/// request was refused for the limit whatever the sentence reads like, so a CLI that rewords
/// itself still stops the session — `UsageLimitStop.recognised(in:)` is asked for the reset hint
/// and not for permission.
///
/// The record's shape, the newest-provider-outcome walk and the rule that a sidechain's refusal
/// is not the session's are `ClaudeTranscriptAPIError`'s, shared with
/// `ClaudeTranscriptTurnRefusal` — which reads the *other* half of the same record: the failures
/// that are not the allowance. This reader answers only for `isRateLimit`, and that one predicate
/// is the whole boundary between them.
///
/// The caching, the size gate and the background hop are `TranscriptFactReader`'s, shared with
/// `ClaudeTranscriptModel` and `ClaudeTranscriptPermissionMode`. Callers in the app should ask
/// `ObservedUsageLimit`, which is where the choice of *which* runtime can answer is made.
///
/// One second shape exists after delegated work: a completed root turn can receive a failed
/// `<task-notification>` whose summary carries the limit failure, while the CLI leaves the root
/// terminal at its limit chooser without appending another assistant record. That child failure
/// is only a candidate here. `UsageLimitObservation` requires the live terminal chooser or notice
/// before the coordinator is allowed to turn it into a session stop.
@MainActor
enum ClaudeTranscriptUsageLimit {

    // MARK: - Properties

    private static let reader = TranscriptFactReader<UsageLimitObservation> { url in
        newestObservation(at: url)
    }

    // MARK: - Public Methods

    /// What has already been read for this transcript. Touches no disk, so a caller painting a
    /// view can ask on the main thread.
    static func known(at url: URL) -> UsageLimitStop? {
        knownObservation(at: url)?.stop
    }

    static func knownObservation(at url: URL) -> UsageLimitObservation? {
        reader.known(at: url)
    }

    /// Re-reads in the background when the transcript has grown, calling back only if the answer
    /// changed.
    static func revalidate(
        at url: URL,
        completion: @escaping @MainActor @Sendable (UsageLimitStop?) -> Void
    ) {
        revalidateObservation(at: url) { observation in
            completion(observation?.stop)
        }
    }

    static func revalidateObservation(
        at url: URL,
        completion: @escaping @MainActor @Sendable (UsageLimitObservation?) -> Void
    ) {
        reader.revalidate(at: url, completion: completion)
    }

    /// Carries the reader's size boundary across an account migration without carrying the stop.
    ///
    /// The destination is an exact copy, so its old tail is already observed. The refusal itself
    /// belonged to the account the conversation left, though: treating it as a live refusal on the
    /// destination immediately offers a second migration before that account has attempted a turn.
    static func acknowledgeAccountMigration(to destination: URL, copiedByteCount: Int) {
        reader.seedCopiedTranscript(at: destination, byteCount: copiedByteCount, value: nil)
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
        newestObservation(at: url)?.stop
    }

    /// The newest root refusal, or a background-task limit candidate following a completed root
    /// turn. One bounded backwards walk keeps the relative ordering of those two record shapes.
    nonisolated static func newestObservation(at url: URL) -> UsageLimitObservation? {
        var candidate: UsageLimitObservation?
        var answer: UsageLimitObservation?

        JSONLReader.forEachRecordFromEnd(at: url, limit: UsageLimitDefaults.scanBytes) { record in
            guard record[ClaudeAPIErrorDefaults.sidechainKey] as? Bool != true else { return true }

            if candidate == nil,
               let notification = taskNotification(in: record),
               notification.isFailed,
               let recognised = UsageLimitStop.recognised(in: notification.summary) {
                let identity = notification.identity
                    ?? ClaudeTranscriptAPIError.identity(of: record)
                candidate = UsageLimitObservation(
                    stop: UsageLimitStop(
                        message: recognised.message,
                        resetHint: recognised.resetHint,
                        recordID: "task-notification:\(identity)"
                    ),
                    evidence: .failedBackgroundTask
                )
            }

            guard record[ClaudeAPIErrorDefaults.typeKey] as? String == "assistant" else {
                return true
            }

            if let failure = ClaudeTranscriptAPIError.parse(record), failure.isRateLimit {
                let recognised = UsageLimitStop.recognised(in: failure.text)
                answer = UsageLimitObservation(
                    stop: UsageLimitStop(
                        message: recognised?.message
                            ?? failure.text
                            ?? TranscriptUsageLimitDefaults.unstatedRefusal,
                        resetHint: recognised?.resetHint,
                        recordID: ClaudeTranscriptAPIError.identity(of: record)
                    ),
                    evidence: .providerRefusal
                )
            } else if assistantCompletedTurn(record) {
                answer = candidate
            }
            return false
        }

        return answer
    }

    private nonisolated static func taskNotification(
        in record: [String: Any]
    ) -> ClaudeTaskNotification? {
        guard record[ClaudeAPIErrorDefaults.typeKey] as? String == "queue-operation",
              record["operation"] as? String == "enqueue",
              let content = record[ClaudeAPIErrorDefaults.contentKey] as? String
        else { return nil }
        return ClaudeTaskNotification.parse(content)
    }

    private nonisolated static func assistantCompletedTurn(_ record: [String: Any]) -> Bool {
        guard let message = record[ClaudeAPIErrorDefaults.messageKey] as? [String: Any] else {
            return false
        }
        return message["stop_reason"] as? String == "end_turn"
    }
}

// MARK: - Defaults

enum TranscriptUsageLimitDefaults {
    /// Shown when the CLI recorded the refusal but no sentence with it, so a mark still has
    /// something to say rather than an empty line.
    static let unstatedRefusal = L10n.string("Usage limit reached")
}

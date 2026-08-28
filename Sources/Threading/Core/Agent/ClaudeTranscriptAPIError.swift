import Foundation

// MARK: - Claude Transcript API Error

/// A request the CLI made and never got an answer to, as Claude writes the failure into the
/// session's own transcript.
///
/// ```json
/// {"type":"assistant","isApiErrorMessage":true,"error":"authentication_failed",
///  "message":{"model":"<synthetic>","content":[{"type":"text",
///  "text":"Login expired · Please run /login"}]}}
/// ```
///
/// **One record shape carries two different facts**, which is why the parse lives here rather
/// than inside either reader. `ClaudeTranscriptUsageLimit` wants the failures whose class is the
/// spent allowance — those have a reset time, a chooser to answer and a recovery policy.
/// `ClaudeTranscriptTurnRefusal` wants every *other* one, because those end a turn the CLI never
/// fired `Stop` for and nothing else would ever close. Parsed twice, the two readers would
/// disagree about what counts as a rate limit the first time a CLI version moved a key — and
/// disagreeing means either a login failure recovered as if the account were spent, or a spent
/// account quietly marked unread.
///
/// **Both `error` and `apiErrorStatus` are read, and either alone is enough.** Different CLI
/// versions write different ones: 2.1.226 recorded `error: "authentication_failed"` with no
/// status at all, so a reader insisting on the pair answers nothing for the record this exists
/// for.
struct ClaudeTranscriptAPIError: Equatable, Sendable {

    // MARK: - Properties

    /// The provider's own class for the failure — `rate_limit`, `authentication_failed`,
    /// `connection_error`. Nil where the record stated only a status.
    let reason: String?

    /// The status the endpoint answered, where the CLI recorded one.
    let status: Int?

    /// The sentence the CLI showed the user, joined across text blocks. Nil where the record
    /// stated the failure but no words for it.
    let text: String?

    /// Whether the account's spent allowance is what stopped it.
    ///
    /// A `429` for any other reason is still an account out of allowance as far as the session is
    /// concerned — it stopped, and nobody typed.
    var isRateLimit: Bool {
        reason == ClaudeAPIErrorDefaults.rateLimitReason
            || status == ClaudeAPIErrorDefaults.rateLimitStatus
    }

    // MARK: - Public Methods

    /// The failure one transcript record states, or nil when it states none.
    ///
    /// `isApiErrorMessage` is the fact; the text is only the words. A CLI that rewords itself
    /// still stops the session, because nothing here is decided by reading the sentence.
    static func parse(_ record: [String: Any]) -> ClaudeTranscriptAPIError? {
        guard record[ClaudeAPIErrorDefaults.apiErrorKey] as? Bool == true else { return nil }

        return ClaudeTranscriptAPIError(
            reason: text(record[ClaudeAPIErrorDefaults.reasonKey]),
            status: status(in: record),
            text: messageText(in: record)
        )
    }

    /// The newest thing the conversation itself said within the scanned tail, or nil when it said
    /// nothing there.
    ///
    /// **It is the newest *message*, not the newest line.** The CLI appends bookkeeping after a
    /// failure — `turn_duration`, queue operations, file-history snapshots — so the walk steps
    /// over anything that is not a message and lets the first `assistant`/`user` record it meets
    /// decide. General turn-refusal reading uses that boundary because either side speaking ends
    /// the failed turn. Usage-limit reading deliberately asks `newestAssistantMessage` instead:
    /// a locally recorded retry is not proof that the provider accepted it.
    ///
    /// **A sidechain's failure is not the session's.** A subagent that runs out of limit is
    /// reported to its parent as a failed task and the parent goes on working — as this app's own
    /// `f3ad7546` session did, for five minutes, before the main thread was refused too. Sidechain
    /// records are stepped over rather than allowed to decide.
    static func newestMessage(at url: URL, limit: Int) -> [String: Any]? {
        newestMessage(
            at: url,
            limit: limit,
            admitting: ClaudeAPIErrorDefaults.messageTypes
        )
    }

    /// The newest provider outcome, ignoring a newer user prompt that has not been answered yet.
    ///
    /// Limit recovery uses this stricter boundary because writing a retry into the transcript is
    /// not evidence that the provider accepted it. The standing refusal remains authoritative
    /// until a newer assistant record either repeats it or proves the conversation spoke again.
    static func newestAssistantMessage(at url: URL, limit: Int) -> [String: Any]? {
        newestMessage(
            at: url,
            limit: limit,
            admitting: ClaudeAPIErrorDefaults.assistantMessageTypes
        )
    }

    private static func newestMessage(
        at url: URL,
        limit: Int,
        admitting messageTypes: Set<String>
    ) -> [String: Any]? {
        var newest: [String: Any]?

        JSONLReader.forEachRecordFromEnd(at: url, limit: limit) { record in
            guard let type = record[ClaudeAPIErrorDefaults.typeKey] as? String,
                  messageTypes.contains(type),
                  record[ClaudeAPIErrorDefaults.sidechainKey] as? Bool != true
            else { return true }

            newest = record
            return false
        }

        return newest
    }

    /// The record's own identity, which is how a second failure with identical words is told from
    /// the first one still standing. See `ClaudeTurnRefusal.recordID`.
    static func identity(of record: [String: Any]) -> String {
        text(record[ClaudeAPIErrorDefaults.uuidKey])
            ?? text(record[ClaudeAPIErrorDefaults.timestampKey])
            ?? ClaudeAPIErrorDefaults.unidentifiedRecord
    }

    // MARK: - Private Methods

    /// The status, whether the CLI wrote it as a number or as a string.
    private static func status(in record: [String: Any]) -> Int? {
        let value = record[ClaudeAPIErrorDefaults.statusKey]
        if let number = value as? Int { return number }
        return (value as? String).flatMap(Int.init)
    }

    private static func messageText(in record: [String: Any]) -> String? {
        guard let message = record[ClaudeAPIErrorDefaults.messageKey] as? [String: Any],
              // Per element. The record still states the failure without its words, so the
              // strict cast did not hide the stop — it deleted the only sentence explaining it,
              // which is the whole reason this text is read.
              let blocks = WireList.objects(
                message[ClaudeAPIErrorDefaults.contentKey],
                site: WireListSite.claudeAPIErrorContent,
                log: ThreadingLogger.agent
              )
        else { return nil }

        let joined = blocks
            .compactMap { $0[ClaudeAPIErrorDefaults.textKey] as? String }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    /// A field's string, or nil when the key is absent *or* present and empty. The two are the
    /// same fact — the record named nothing — and separating them downstream only gives every
    /// read site the chance to disagree about which counts.
    private static func text(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }
}

// MARK: - Defaults

enum ClaudeAPIErrorDefaults {
    static let typeKey = "type"
    static let sidechainKey = "isSidechain"
    static let apiErrorKey = "isApiErrorMessage"
    static let reasonKey = "error"
    static let statusKey = "apiErrorStatus"
    static let messageKey = "message"
    static let contentKey = "content"
    static let textKey = "text"
    static let uuidKey = "uuid"
    static let timestampKey = "timestamp"

    /// The record types that count as the conversation speaking. Everything else the CLI
    /// appends — `system`, `queue-operation`, `summary`, `file-history-snapshot` — is
    /// bookkeeping written *around* a message and says nothing about whether one failed.
    static let messageTypes: Set<String> = ["assistant", "user"]
    static let assistantMessageTypes: Set<String> = ["assistant"]

    static let rateLimitReason = "rate_limit"
    static let rateLimitStatus = 429

    /// Stands in for a record that named neither a uuid nor a timestamp, so an unidentified
    /// failure still has a stable identity rather than an accidentally shared one.
    static let unidentifiedRecord = "unidentified-record"
}

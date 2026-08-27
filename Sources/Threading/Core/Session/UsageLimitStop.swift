import Foundation

// MARK: - Usage Limit Stop

/// An agent that stopped because its account's usage limit is spent, in the provider's own
/// words.
///
/// This is a *stop*, not a reading. `AccountUsageService` answers "how much of the window is
/// left" for the toolbar pill — a number about an account, polled. This answers "this
/// conversation asked, and was refused", which is a fact about one session at one moment and
/// arrives only from whatever the runtime wrote when it happened.
///
/// **The reset is kept as text.** Claude states it as `resets 1:20pm (Europe/Rome)` — a wall
/// clock in a zone that is the *account's*, not necessarily the Mac's, and with no date. Turning
/// that into a `Date` means guessing which day and which zone, and a mark that says "resets 1:20
/// pm" when the provider said something else is worse than one that quotes it. Where a runtime
/// states an instant instead (`…|1754575200`), the number is formatted once, here, and the
/// result is again text: the surfaces showing this have nothing to compute with a `Date`.
struct UsageLimitStop: Equatable, Sendable {

    // MARK: - Properties

    /// The provider's own sentence, with any machine-readable tail stripped.
    let message: String

    /// When the provider said work can resume, in the provider's own words — `1:20pm
    /// (Europe/Rome)`, `Tuesday at 9am`. Nil when it refused without saying.
    let resetHint: String?

    /// The provider record that stated this refusal, when the runtime has one.
    ///
    /// The reader's callback is changed-only, and a provider commonly refuses several retries
    /// with exactly the same sentence. The record identity is therefore part of the fact: the
    /// second refusal is a new stop even when its words and reset hint are byte-for-byte equal.
    /// Structured runtimes that deliver one refusal event at a time may leave this nil.
    let recordID: String?

    // MARK: - Initialization

    init(message: String, resetHint: String? = nil, recordID: String? = nil) {
        self.message = message
        self.resetHint = resetHint
        self.recordID = recordID
    }

    // MARK: - Public Methods

    /// Recognises a usage-limit refusal in text a provider wrote, or nil when it is about
    /// something else.
    ///
    /// Deliberately only ever applied to text a runtime already marked as a failure — a
    /// transcript record carrying `error: "rate_limit"`, a turn that settled `.failed`. An agent
    /// can write "your usage limit" in ordinary prose, and matching phrases anywhere else would
    /// stop a session on the strength of it having *talked* about limits.
    static func recognised(in text: String?) -> UsageLimitStop? {
        guard let text else { return nil }

        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }

        let folded = cleaned.lowercased()
        guard UsageLimitDefaults.phrases.contains(where: folded.contains) else { return nil }

        let (sentence, instant) = splittingMachineTail(cleaned)
        return UsageLimitStop(
            message: sentence,
            resetHint: resetHint(in: sentence) ?? instant.map(shortTime(for:))
        )
    }

    // MARK: - Private Methods

    /// Splits `Claude AI usage limit reached|1754575200` into its sentence and its instant.
    ///
    /// The tail is a wire detail rather than something to show: pasted into a status line it
    /// reads as a corrupted message, and it is the one form that *can* be turned into a time
    /// without guessing.
    private static func splittingMachineTail(_ text: String) -> (String, Date?) {
        guard let separator = text.lastIndex(of: UsageLimitDefaults.machineTailSeparator) else {
            return (text, nil)
        }

        let tail = text[text.index(after: separator)...]
            .trimmingCharacters(in: .whitespaces)
        guard !tail.isEmpty,
              tail.allSatisfy({ $0.isNumber }),
              let seconds = TimeInterval(tail)
        else { return (text, nil) }

        let sentence = text[..<separator].trimmingCharacters(in: .whitespaces)
        return (sentence, Date(timeIntervalSince1970: seconds))
    }

    /// The words after the runtime's own "resets"/"try again" marker.
    private static func resetHint(in text: String) -> String? {
        for marker in UsageLimitDefaults.resetMarkers {
            guard let range = text.range(of: marker, options: .caseInsensitive) else { continue }

            let hint = text[range.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: UsageLimitDefaults.trailingPunctuation)
            if !hint.isEmpty { return hint }
        }
        return nil
    }

    /// A stated instant in the user's own locale. Built per call rather than cached: this runs
    /// once per refusal, and a stored formatter would keep the locale it was created under
    /// across a system change.
    private static func shortTime(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = Calendar.current.isDateInToday(date) ? .none : .short
        return formatter.string(from: date)
    }
}

// MARK: - Usage Limit Defaults

enum UsageLimitDefaults {
    /// What a refusal for a spent limit says, across the forms observed: `You've hit your
    /// session limit · resets 1:20pm (Europe/Rome)`, `Claude AI usage limit reached|…`,
    /// `5-hour limit reached ∙ resets 3pm`, `You've hit your weekly limit`, and Codex's
    /// `Your workspace is out of credits`.
    ///
    /// Matched on words rather than on punctuation: the separator alone has been a middle dot,
    /// a bullet operator and a pipe across three CLI versions.
    static let phrases = [
        "usage limit",
        "session limit",
        "weekly limit",
        "hour limit",
        "rate limit",
        "limit reached",
        "out of credits",
        "credits depleted"
    ]

    /// Where the provider stops describing the refusal and starts describing the resumption.
    static let resetMarkers = ["resets ", "try again "]

    /// Separates a prose refusal from the epoch second some versions append to it.
    static let machineTailSeparator: Character = "|"

    static let trailingPunctuation = CharacterSet(charactersIn: ".;,")

    /// How often a live session's own record is re-read for a refusal. The read behind it is a
    /// `stat` unless the file grew, so this is closer to free than the interval suggests; it is
    /// how long a spent session can keep drawing a spinner, which is the cost being paid.
    static let pollInterval: TimeInterval = 5

    /// How far back a transcript scan looks for the newest message record. One chunk: the
    /// refusal is written *as* the last message, and everything after it is bookkeeping.
    static let scanBytes = 64 * 1024
}

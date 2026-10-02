import Foundation

// MARK: - Curfew Rule

/// What a record says about ending a session's spending — and nothing about when it was said.
///
/// Absent on a record means **inherit, not none**: the chain in `CurfewResolution` then asks the
/// checkout and finally the standing quiet hours, the rule every scoped setting here follows.
/// `.exempt` is therefore a real answer rather than the absence of one — it is how a session
/// says *do not hold me tonight* while the app-wide window stays on for everything else.
///
/// `.until` carries a wall-clock moment rather than a duration. A duration would have to be
/// re-anchored every time the app relaunched, and the whole feature exists because the user is
/// asleep across the moment that matters.
enum CurfewRule: Equatable, Sendable {
    case exempt
    case until(Date)

    /// Hold at this window's expected boundary, or at an earlier provider-proven reset of it.
    ///
    /// The estimate is the latest deadline. `SessionCurfewCenter` can materialize an earlier one
    /// from `UsageLimitResetEvent.detectedAt`, then the ordinary hold and interrupt ladder takes
    /// over. Account and window are captured when the choice is armed, so an unrelated login,
    /// 5h/Spark window, or older reset cannot satisfy a weekly choice.
    case untilUsageReset(
        expectedAt: Date,
        armedAt: Date,
        accountID: AccountID,
        windowID: String
    )

    /// A one-shot ceiling on the named account/window's total reported usage.
    /// It has no clock deadline until a fresh reading reaches the percentage.
    case atUsage(percent: Int, armedAt: Date, accountID: AccountID, windowID: String)

    // MARK: - Stored Shape

    /// The tagged form on disk.
    ///
    /// A tagged record rather than an enum with associated values, because this is the shape a
    /// *later* build has to stay able to read: a kind this version has never heard of decodes as
    /// a `Stored` with an unfamiliar tag, which `init?(stored:)` answers with nil — "never
    /// chose" — instead of throwing the surrounding session record away over one setting. That
    /// is the same rule `AgentSession` applies to `limitRecoveryPolicy`, for the same reason,
    /// and the conservative direction: a session that cannot read its own curfew inherits one.
    struct Stored: Codable, Equatable, Sendable {
        let kind: String
        let deadline: Date?
        let armedAt: Date?
        let accountID: AccountID?
        let windowID: String?
        let percent: Int?

        init(
            kind: String,
            deadline: Date?,
            armedAt: Date? = nil,
            accountID: AccountID? = nil,
            windowID: String? = nil,
            percent: Int? = nil
        ) {
            self.kind = kind
            self.deadline = deadline
            self.armedAt = armedAt
            self.accountID = accountID
            self.windowID = windowID
            self.percent = percent
        }
    }

    /// The tags written to disk. Raw strings, never `Int`, so a reader can be diagnosed by
    /// looking at the JSON.
    enum Kind: String {
        case exempt
        case until
        case untilUsageReset
        case atUsage
    }

    /// Reads a stored rule, answering nil for anything this build does not recognise.
    init?(stored: Stored) {
        switch Kind(rawValue: stored.kind) {
        case .exempt:
            self = .exempt
        case .until:
            // A deadline is what `.until` *is*. A tag that arrives without one is unreadable
            // rather than "until never", which would be a curfew that silently holds forever.
            guard let deadline = stored.deadline else { return nil }
            self = .until(deadline)
        case .untilUsageReset:
            guard let expectedAt = stored.deadline,
                  let armedAt = stored.armedAt,
                  let accountID = stored.accountID,
                  let windowID = stored.windowID,
                  !windowID.isEmpty else {
                return nil
            }
            self = .untilUsageReset(
                expectedAt: expectedAt,
                armedAt: armedAt,
                accountID: accountID,
                windowID: windowID
            )
        case .atUsage:
            guard let percent = stored.percent,
                  CurfewDefaults.usagePercentRange.contains(percent),
                  let armedAt = stored.armedAt,
                  let accountID = stored.accountID,
                  let windowID = stored.windowID, !windowID.isEmpty else { return nil }
            self = .atUsage(
                percent: percent, armedAt: armedAt, accountID: accountID, windowID: windowID
            )
        case nil:
            return nil
        }
    }

    var stored: Stored {
        switch self {
        case .atUsage(let percent, let armedAt, let accountID, let windowID):
            return Stored(
                kind: Kind.atUsage.rawValue, deadline: nil, armedAt: armedAt,
                accountID: accountID, windowID: windowID, percent: percent
            )
        case .exempt:
            return Stored(kind: Kind.exempt.rawValue, deadline: nil)
        case .until(let deadline):
            return Stored(kind: Kind.until.rawValue, deadline: deadline)
        case .untilUsageReset(let expectedAt, let armedAt, let accountID, let windowID):
            return Stored(
                kind: Kind.untilUsageReset.rawValue,
                deadline: expectedAt,
                armedAt: armedAt,
                accountID: accountID,
                windowID: windowID
            )
        }
    }

    /// The fixed deadline, or the latest expected deadline for a reset-conditioned rule.
    var deadline: Date? {
        switch self {
        case .until(let deadline), .untilUsageReset(let deadline, _, _, _):
            return deadline
        case .exempt, .atUsage:
            return nil
        }
    }
}

// MARK: - Curfew Rule Coding

extension CurfewRule: Codable {

    /// Encoded and decoded *through* `Stored`, so the wire shape has exactly one definition and
    /// the lenient reader above and this conformance cannot drift apart.
    ///
    /// This conformance still throws on an unknown kind — a record that holds a `CurfewRule`
    /// non-optionally has nothing else it could mean. The place that must survive one is the
    /// session record, which decodes `Stored` and asks `init?(stored:)`.
    init(from decoder: Decoder) throws {
        let stored = try Stored(from: decoder)
        guard let rule = CurfewRule(stored: stored) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unreadable curfew rule kind \"\(stored.kind)\""
                )
            )
        }
        self = rule
    }

    func encode(to encoder: Encoder) throws {
        try stored.encode(to: encoder)
    }
}

// MARK: - Curfew Origin

/// Who set the deadline a session is currently running under.
///
/// Not the same question as `CurfewScope`, which names the *record* that answered. Origin is
/// what the session's own state remembers, and it is what tells a standing nightly window from a
/// one-shot "end this at 22:00": a quiet-hours instance ends by itself when its window closes,
/// which is the only curfew that lifts without the user saying so.
enum CurfewOrigin: Codable, Equatable, Sendable {
    case session
    case quietHours(endsAt: Date)

    /// A provider observation proved that used capacity on the armed account was restored.
    /// `armedAt` links the state to the exact conditional rule that produced it.
    case usageReset(armedAt: Date, accountID: AccountID, windowID: String)
    case usageThreshold(percent: Int, armedAt: Date, accountID: AccountID, windowID: String)
}

// MARK: - Curfew Receipt

/// One thing the curfew did, when, and any detail worth reading later.
///
/// A curfew acts while nobody is watching, so the log is not diagnostics: it is the answer to
/// "what happened to my session overnight", printed in the strip the next morning.
struct CurfewReceipt: Codable, Equatable, Sendable {

    /// What happened. Raw strings so a receipt written by a later build is readable by eye, and
    /// so an event this build has never heard of costs one receipt rather than the whole log —
    /// see `lenientArray(from:forKey:)`.
    enum Event: String, Codable, Sendable, CaseIterable {
        case windDownSent
        case windDownSkippedIdle
        case windDownFailed
        case held
        case interrupted
        case gaveUp

        /// The opt-in escalation ended the agent.
        ///
        /// Only ever after `gaveUp`, and only where the user asked for it in Settings: the
        /// default is to notify and leave the session alone. The process is *terminated* rather
        /// than discarded, so the terminal's final screen stays visible and the session resumes
        /// by its ordinary affordance — the whole feature exists because somebody wants to read
        /// the conversation in the morning.
        case stoppedAgent

        case lifted
        case ended
    }

    let event: Event
    let at: Date
    let detail: String?

    init(event: Event, at: Date, detail: String? = nil) {
        self.event = event
        self.at = at
        self.detail = detail
    }

    // MARK: - Lenient Decoding

    /// An element that never throws: it reads a receipt if it can and answers nil if it cannot.
    ///
    /// The nil case is what makes the loop below safe. An unkeyed container advances only when
    /// its `decode` succeeds, so catching *inside* the element type — rather than around the
    /// call — is what keeps the reader moving through the rest of the array.
    private struct Readable: Decodable {
        let receipt: CurfewReceipt?

        init(from decoder: Decoder) throws {
            receipt = try? CurfewReceipt(from: decoder)
        }
    }

    /// Decodes a stored array, dropping the entries this build cannot read.
    ///
    /// The synthesized conformance would throw on the first unknown `Event`, and the throw would
    /// not stop at the receipt: it would take the whole `SessionCurfewState` with it, which is
    /// how a session under a curfew set by a newer build would come back holding nothing — no
    /// deadline, no hold, no record that it ever had one. Losing one line of a log is a much
    /// smaller loss than losing the fence.
    static func lenientArray<Key: CodingKey>(
        from container: KeyedDecodingContainer<Key>,
        forKey key: Key
    ) throws -> [CurfewReceipt] {
        guard container.contains(key),
              var unkeyed = try? container.nestedUnkeyedContainer(forKey: key) else {
            return []
        }
        var receipts: [CurfewReceipt] = []
        while !unkeyed.isAtEnd {
            let entry = try unkeyed.decode(Readable.self)
            if let receipt = entry.receipt {
                receipts.append(receipt)
            }
        }
        return receipts
    }
}

// MARK: - Session Curfew State

/// What one session's curfew has already done, kept beside the session on disk.
///
/// **`deadline` is the instance's identity.** A new deadline is a new curfew, not an edit of the
/// old one: the wind-down is owed again, the hold is announced again, the interrupt budget
/// starts at zero. That is why it is a `let` — the engine replaces the whole record rather than
/// moving the moment under the receipts that describe a different one.
struct SessionCurfewState: Codable, Equatable, Sendable {

    // MARK: - Properties

    let deadline: Date
    var origin: CurfewOrigin

    /// The wrap-up filed as an ordinary scheduled message, so its custody, its delivery and its
    /// failure sentence are the ones every other scheduled send already has.
    var windDownMessageID: ScheduledMessageID?

    var interruptCount: Int

    /// When the last interrupt landed — the spacing gate reads it, and the strip prints it
    /// beside the count.
    var lastInterruptAt: Date?

    var liftedAt: Date?
    var gaveUpAt: Date?

    var receipts: [CurfewReceipt]

    // MARK: - Initialization

    init(
        deadline: Date,
        origin: CurfewOrigin,
        windDownMessageID: ScheduledMessageID? = nil,
        interruptCount: Int = 0,
        lastInterruptAt: Date? = nil,
        liftedAt: Date? = nil,
        gaveUpAt: Date? = nil,
        receipts: [CurfewReceipt] = []
    ) {
        self.deadline = deadline
        self.origin = origin
        self.windDownMessageID = windDownMessageID
        self.interruptCount = interruptCount
        self.lastInterruptAt = lastInterruptAt
        self.liftedAt = liftedAt
        self.gaveUpAt = gaveUpAt
        self.receipts = receipts
    }

    // MARK: - Public Methods

    /// Records one thing the curfew did.
    ///
    /// The log is capped at `CurfewDefaults.maximumReceipts` and drops the **oldest**, because
    /// the surfaces that read it — the strip, the popover — are asking what happened most
    /// recently, and because this rides in the session's JSON payload beside everything else the
    /// record has to carry.
    ///
    /// `lastInterruptAt` moves with an `.interrupted` receipt: the moment and the receipt are
    /// one fact, and a spacing gate reading a stale moment would interrupt twice in a second.
    /// The *count*, the lift and the give-up stay the engine's to set — they are decisions, not
    /// readings, and `SessionCurfewCenter` is where a decision is made.
    mutating func record(_ event: CurfewReceipt.Event, at date: Date, detail: String? = nil) {
        receipts.append(CurfewReceipt(event: event, at: date, detail: detail))
        if receipts.count > CurfewDefaults.maximumReceipts {
            receipts.removeFirst(receipts.count - CurfewDefaults.maximumReceipts)
        }
        if event == .interrupted {
            lastInterruptAt = date
        }
    }

    /// Whether this instance has already done something once — the guard that keeps the engine's
    /// per-session evaluation idempotent when it runs again a second later.
    func has(_ event: CurfewReceipt.Event) -> Bool {
        receipts.contains { $0.event == event }
    }

    /// When something happened, for a sentence that prints the moment as well as the fact.
    func momentOf(_ event: CurfewReceipt.Event) -> Date? {
        receipts.last { $0.event == event }?.at
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case deadline
        case origin
        case windDownMessageID
        case interruptCount
        case lastInterruptAt
        case liftedAt
        case gaveUpAt
        case receipts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deadline = try container.decode(Date.self, forKey: .deadline)
        origin = try container.decode(CurfewOrigin.self, forKey: .origin)
        windDownMessageID = try container.decodeIfPresent(
            ScheduledMessageID.self,
            forKey: .windDownMessageID
        )
        interruptCount = try container.decodeIfPresent(Int.self, forKey: .interruptCount) ?? 0
        lastInterruptAt = try container.decodeIfPresent(Date.self, forKey: .lastInterruptAt)
        liftedAt = try container.decodeIfPresent(Date.self, forKey: .liftedAt)
        gaveUpAt = try container.decodeIfPresent(Date.self, forKey: .gaveUpAt)
        receipts = try CurfewReceipt.lenientArray(from: container, forKey: .receipts)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(deadline, forKey: .deadline)
        try container.encode(origin, forKey: .origin)
        try container.encodeIfPresent(windDownMessageID, forKey: .windDownMessageID)
        try container.encode(interruptCount, forKey: .interruptCount)
        try container.encodeIfPresent(lastInterruptAt, forKey: .lastInterruptAt)
        try container.encodeIfPresent(liftedAt, forKey: .liftedAt)
        try container.encodeIfPresent(gaveUpAt, forKey: .gaveUpAt)
        try container.encode(receipts, forKey: .receipts)
    }
}

// MARK: - Curfew Defaults

/// Every number and fixed string the curfew feature runs on.
enum CurfewDefaults {

    static let usagePercentRange = 1...100
    static let defaultUsagePercent = 80
    static let usagePercentPresets = [50, 60, 70, 80, 90, 95, 100]
    static let maximumUsageAge = UsageDefaults.refreshInterval

    /// How long before the deadline the agent is asked to wrap up. Ten minutes is enough for a
    /// commit and a handoff note and short enough that it is still the same piece of work.
    static let windDownMargin: TimeInterval = 10 * 60

    /// How long after the deadline a turn is left alone before it is interrupted. The deadline
    /// stops Threading from spending the session; the grace is what a turn already in flight
    /// gets to finish in.
    static let grace: TimeInterval = 5 * 60

    /// How many times a session that keeps starting new turns is interrupted before the curfew
    /// gives up and asks the user instead. A provider loop re-submits from inside the CLI, so
    /// one interrupt is not always the end — but an app that types into somebody's terminal
    /// without a bound is a worse failure than a loop that outlived its curfew.
    static let maximumInterrupts = 3

    /// The shortest gap between two interrupts. Also what keeps a second Escape away from an
    /// idle prompt, where Claude reads it as "open the rewind chooser".
    static let reinterruptSpacing: TimeInterval = 30

    /// While a reset-conditioned curfew is armed, ask for a fresh reading at the service's
    /// existing per-account floor. AccountUsageService still single-flights accounts, caps
    /// provider concurrency, and honours provider Retry-After responses.
    static let usageResetPollInterval = UsageDefaults.minimumRefreshSpacing

    /// How much of the log rides in the session's payload. See `SessionCurfewState.record`.
    static let maximumReceipts = 8

    /// What the wrap-up template replaces with the curfew's own time.
    static let timePlaceholder = "{time}"

    /// The default wrap-up, in English and deliberately not localized: it is a message typed to
    /// a coding agent rather than copy shown to the user, it is editable in Settings, and a user
    /// who wants it in their own language writes it there.
    static let windDownText = """
        Your curfew is at {time}. End any loop or goal you are running, commit what is safe, \
        write what is left to a handoff note, then stop.
        """

    /// The mark every curfew surface draws — menu, chip, strip, row.
    static let symbol = "moon.zzz"

    /// What the Settings popup offers for the wind-down. `nil` is "off": no wrap-up at all,
    /// which is a legitimate choice for a session that is not running a loop.
    static let windDownMarginChoices: [TimeInterval?] = [nil, 5 * 60, 10 * 60, 15 * 60, 30 * 60]

    /// What the Settings popup offers for the grace. `nil` is "never interrupt" — the hold still
    /// applies, so the session stops being spent, but nothing is typed into it. `0` is "at the
    /// curfew", with no grace at all.
    static let graceChoices: [TimeInterval?] = [nil, 0, 5 * 60, 10 * 60, 15 * 60]

    /// Where the standing nightly window starts and ends when the user first switches it on —
    /// the case the feature was written for, a five-hour window resetting at 04:00 while its
    /// owner is asleep.
    static let quietHoursStartMinute = 4 * 60
    static let quietHoursEndMinute = 8 * 60

    /// Bounds for the stored preferences. Minutes are a time of day; the text is one message.
    static let minutesPerDay = 24 * 60
    static let minutesPerHour = 60
    static let maximumWindDownTextBytes = 2_000

    /// What separates the clauses of a receipt line: "Curfew since 04:00 · wrap-up sent 03:50".
    static let receiptSeparator = " · "
}

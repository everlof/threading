import Foundation

// MARK: - Scheduled Message Identity

/// One scheduled send's stable identity, intentionally incompatible with the session and
/// project identifiers it sits beside.
struct ScheduledMessageID: Hashable, Sendable, Codable, CustomStringConvertible {
    let rawValue: UUID

    init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    init?(uuidString: String) {
        guard let value = UUID(uuidString: uuidString) else { return nil }
        self.rawValue = value
    }

    var uuidString: String { rawValue.uuidString }
    var description: String { uuidString }

    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UUID.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - Scheduled Session Plan

/// Everything a session start needs, frozen at the moment it was scheduled.
///
/// A copy of the composer's decisions rather than a reference to the composer: the chips will
/// have moved on by the time this fires, and a plan that read them at fire time would launch
/// whatever happened to be selected on Monday morning.
///
/// `accountHandleName` is a string because `AccountHandle` is deliberately not `Codable` — the
/// standard login is a real case rather than an absent string, and `persistedSessionName` /
/// `init(storedName:)` is the spelling every other persisted copy of it uses.
struct ScheduledSessionPlan: Codable, Sendable, Equatable {
    /// The conversation reserved when the schedule is created.
    ///
    /// Older records have no value and keep their original create-at-fire behaviour. New
    /// records use this identity for the waiting sidebar row and for the eventual launch, so
    /// the thing somebody inspected before its trigger is the thing that actually starts.
    let reservedSessionID: SessionID?
    let projectID: ProjectID
    let kind: AgentKind
    let accountHandleName: String?
    let model: String?
    let reasoningEffort: String?
    let fastMode: Bool?
    let branch: String?
    let usesNativeUI: Bool
    let permissionMode: AgentPermissionMode?
    let managedWorkspacePlan: ManagedWorkspacePlan?

    var accountHandle: AccountHandle { AccountHandle(storedName: accountHandleName) }

    init(
        reservedSessionID: SessionID? = nil,
        projectID: ProjectID,
        kind: AgentKind,
        accountHandle: AccountHandle,
        model: String?,
        reasoningEffort: String?,
        fastMode: Bool? = nil,
        branch: String?,
        usesNativeUI: Bool,
        permissionMode: AgentPermissionMode?,
        managedWorkspacePlan: ManagedWorkspacePlan? = nil
    ) {
        self.reservedSessionID = reservedSessionID
        self.projectID = projectID
        self.kind = kind
        self.accountHandleName = accountHandle.persistedSessionName
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.fastMode = fastMode
        self.branch = branch
        self.usesNativeUI = usesNativeUI
        self.permissionMode = permissionMode
        self.managedWorkspacePlan = managedWorkspacePlan
    }
}

// MARK: - Scheduled Message

/// A message the user wrote now and asked to be sent later.
///
/// Two payloads, one record: a reply to a session that exists, and the brief that starts one
/// that does not. They share a store, a strip and every rule about what happens when their
/// trigger fires, so splitting them into two types would be two of everything below.
///
/// **Images are deliberately absent.** A pasted screenshot is a file in a temporary directory,
/// and a path written down now can name nothing by Monday — which is why `DraftStore` already
/// refuses to draft them. Scheduling is that hazard at its worst, so the composer refuses to
/// schedule while any are attached rather than sending a brief whose pictures are gone.
struct ScheduledMessage: Codable, Sendable, Equatable, Identifiable {

    // MARK: - Target

    enum Target: Codable, Sendable, Equatable {
        /// A reply to a session that already exists.
        case session(SessionID)

        /// A session that does not exist yet, and the configuration to start it with.
        case newSession(ScheduledSessionPlan)

        var sessionID: SessionID? {
            switch self {
            case .session(let id): return id
            case .newSession(let plan): return plan.reservedSessionID
            }
        }

        var projectID: ProjectID? {
            guard case .newSession(let plan) = self else { return nil }
            return plan.projectID
        }
    }

    // MARK: - State

    enum State: Codable, Sendable, Equatable {
        /// Waiting for its moment.
        case armed

        /// Its moment arrived while the app was running, and the surface could not take it
        /// yet — a terminal mid-turn, or a woken session that has not proven it is ready.
        /// Keeps trying for as long as the app runs, and stays visible while it does.
        case waiting(String)

        /// Its moment passed while the app was not running. Never sent automatically; the
        /// next launch asks what to do with it. See `docs/architecture/scheduled-messages.md`.
        case missed

        /// Tried, and could not be delivered for a reason that will not resolve itself.
        case failed(String)

        var isArmed: Bool { self == .armed }

        /// Whether the app still owes this send an attempt.
        ///
        /// `waiting` counts. It is the state of a send whose moment *has* arrived and whose
        /// surface could not take it yet, so leaving it out of the due set — which is what
        /// filtering on `armed` alone did — would have meant a send that found its session busy
        /// once was never offered again, and sat in the strip claiming to be waiting for
        /// something that would never come.
        var isOwed: Bool {
            switch self {
            case .armed, .waiting: return true
            case .missed, .failed: return false
            }
        }

        /// Whether the user still has a decision to make about this one.
        var needsAttention: Bool { !isOwed }
    }

    // MARK: - Anchor

    /// What the chosen moment was *about*, so a reading that has moved can be re-read.
    ///
    /// A wall-clock time is its own reason and needs no re-reading. A usage window's reset is a
    /// reading — refreshed on an interval, sometimes served from a local cache — so a send
    /// anchored to one has to be able to ask again at fire time. See `ScheduledResetPolicy`.
    enum Anchor: Codable, Sendable, Equatable {
        case wallClock

        /// The identifier of the `AccountUsage.Window` this was aimed at — `5h`, `7d`, or a
        /// model-scoped window's own id.
        case usageWindowReset(windowID: String)

        var usageWindowID: String? {
            guard case .usageWindowReset(let id) = self else { return nil }
            return id
        }
    }

    // MARK: - Trigger

    /// What has to happen before the send is owed.
    ///
    /// A finish trigger is deliberately a session id rather than a snapshot of its title or
    /// activity. The title may change while this waits, and the live activity edge is the only
    /// authority on whether the current turn — including work it left running — has ended.
    enum Trigger: Codable, Sendable, Equatable {
        case time(TimeTrigger)
        case sessionFinished(SessionID)

        var dueAt: Date? {
            guard case .time(let value) = self else { return nil }
            return value.dueAt
        }

        var watchedSessionID: SessionID? {
            guard case .sessionFinished(let id) = self else { return nil }
            return id
        }

        var time: TimeTrigger? {
            guard case .time(let value) = self else { return nil }
            return value
        }
    }

    /// The complete promise behind a clock-based trigger.
    ///
    /// Keeping these values together prevents a finish-triggered record from carrying a dummy
    /// date or time zone. It also makes the persistence migration explicit: old records stored
    /// these four fields at the top level and decode into this value below.
    struct TimeTrigger: Codable, Sendable, Equatable {
        var dueAt: Date
        let intendedTimeZoneIdentifier: String
        let intendedWallClock: DateComponents
        let anchor: Anchor

        var intendedTimeZone: TimeZone {
            TimeZone(identifier: intendedTimeZoneIdentifier) ?? .current
        }
    }

    // MARK: - Properties

    let id: ScheduledMessageID
    let createdAt: Date

    var target: Target
    var text: String
    var context: [ConversationContextAttachment]
    var trigger: Trigger
    var state: State

    /// How many times a reset-anchored send has already stood aside for a window that had not
    /// actually reset. Bounded by `ScheduledResetPolicy`; see `ScheduledMessageDefaults`.
    var resetRearmCount: Int

    var dueAt: Date? { trigger.dueAt }
    var anchor: Anchor? { trigger.time?.anchor }
    var intendedTimeZone: TimeZone? { trigger.time?.intendedTimeZone }
    var intendedWallClock: DateComponents? { trigger.time?.intendedWallClock }

    // MARK: - Initialization

    init(
        id: ScheduledMessageID = ScheduledMessageID(),
        createdAt: Date = Date(),
        dueAt: Date,
        timeZone: TimeZone = .current,
        calendar: Calendar = .current,
        target: Target,
        text: String,
        context: [ConversationContextAttachment] = [],
        anchor: Anchor = .wallClock,
        state: State = .armed,
        resetRearmCount: Int = 0
    ) {
        var wallClockCalendar = calendar
        wallClockCalendar.timeZone = timeZone

        self.id = id
        self.createdAt = createdAt
        self.trigger = .time(TimeTrigger(
            dueAt: dueAt,
            intendedTimeZoneIdentifier: timeZone.identifier,
            intendedWallClock: wallClockCalendar.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: dueAt
            ),
            anchor: anchor
        ))
        self.target = target
        self.text = text
        self.context = context
        self.state = state
        self.resetRearmCount = resetRearmCount
    }

    /// Builds a send that becomes owed when another conversation's current turn finishes.
    init(
        id: ScheduledMessageID = ScheduledMessageID(),
        createdAt: Date = Date(),
        whenSessionFinishes watchedSessionID: SessionID,
        target: Target,
        text: String,
        context: [ConversationContextAttachment] = [],
        state: State = .armed
    ) {
        self.id = id
        self.createdAt = createdAt
        self.target = target
        self.text = text
        self.context = context
        self.trigger = .sessionFinished(watchedSessionID)
        self.state = state
        self.resetRearmCount = 0
    }

    // MARK: - Codable

    /// New records keep the trigger as one value. The remaining keys are the pre-trigger shape,
    /// decoded so an update never quarantines messages somebody already scheduled by time.
    private enum CodingKeys: String, CodingKey {
        case id
        case createdAt
        case target
        case text
        case context
        case trigger
        case state
        case resetRearmCount
        case dueAt
        case intendedTimeZoneIdentifier
        case intendedWallClock
        case anchor
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(ScheduledMessageID.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        target = try container.decode(Target.self, forKey: .target)
        text = try container.decode(String.self, forKey: .text)
        context = try container.decodeIfPresent(
            [ConversationContextAttachment].self,
            forKey: .context
        ) ?? []
        state = try container.decode(State.self, forKey: .state)
        resetRearmCount = try container.decodeIfPresent(Int.self, forKey: .resetRearmCount) ?? 0

        if let stored = try container.decodeIfPresent(Trigger.self, forKey: .trigger) {
            trigger = stored
        } else {
            trigger = .time(TimeTrigger(
                dueAt: try container.decode(Date.self, forKey: .dueAt),
                intendedTimeZoneIdentifier: try container.decode(
                    String.self,
                    forKey: .intendedTimeZoneIdentifier
                ),
                intendedWallClock: try container.decode(
                    DateComponents.self,
                    forKey: .intendedWallClock
                ),
                anchor: try container.decode(Anchor.self, forKey: .anchor)
            ))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(target, forKey: .target)
        try container.encode(text, forKey: .text)
        try container.encode(context, forKey: .context)
        try container.encode(trigger, forKey: .trigger)
        try container.encode(state, forKey: .state)
        try container.encode(resetRearmCount, forKey: .resetRearmCount)
    }

    // MARK: - Reading

    /// What a row shows. Empty prose with staged context still reads as something, for the same
    /// reason `ConversationOutbox.Item.summary` does.
    var summary: String {
        ConversationPrompt(text: text, context: context).visibleText
    }

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && context.isEmpty
    }

    func isDue(at now: Date) -> Bool {
        guard let dueAt else { return false }
        return dueAt <= now
    }

    /// The prompt this becomes when it is finally sent.
    var prompt: ConversationPrompt {
        ConversationPrompt(text: text, context: context)
    }

    /// The same record, aimed at a new moment — used by Reschedule and by a reset anchor
    /// standing aside for a window that had not reset yet.
    func rescheduled(
        to newDueAt: Date,
        timeZone: TimeZone = .current,
        calendar: Calendar = .current,
        countingRearm: Bool = false
    ) -> ScheduledMessage {
        guard case .time(let current) = trigger else { return self }

        return ScheduledMessage(
            id: id,
            createdAt: createdAt,
            dueAt: newDueAt,
            timeZone: timeZone,
            calendar: calendar,
            target: target,
            text: text,
            context: context,
            anchor: current.anchor,
            state: .armed,
            resetRearmCount: countingRearm ? resetRearmCount + 1 : resetRearmCount
        )
    }
}

// MARK: - Defaults

enum ScheduledMessageDefaults {

    /// The file, beside the drafts it is a longer-dated cousin of.
    static let fileName = "scheduled-messages.json"

    /// How many sends may wait for one target at once.
    ///
    /// The outbox's own ceiling, for the outbox's own reason: past a screenful the list stops
    /// being something a person reads before it sends and becomes a script they have lost track
    /// of. A refusal is stated rather than silently dropping the oldest.
    static let maximumPerTarget = ConversationOutboxDefaults.maximumItems

    /// How many may wait across the whole app. A second ceiling because the first one is
    /// per-target and a store with forty projects could pass any sane total without ever
    /// tripping it.
    static let maximumTotal = 100

    /// How long a `waiting` send keeps trying a busy surface before it stops asking and says so.
    ///
    /// Only ever spent while the app is running and only against a session that reports its own
    /// turns, so this bounds politeness rather than correctness — a target that is busy for a
    /// solid hour is one the user should be told about rather than typed into eventually.
    static let waitingRetryWindow: TimeInterval = 60 * 60

    /// How many times a reset-anchored send may stand aside for a window that turned out not to
    /// have reset, under `ScheduledResetPolicy.waitUntilReset`.
    ///
    /// A ceiling rather than a target: the setting says "wait until it resets", and this is what
    /// stops a misreported window turning one scheduled message into an unbounded chase.
    static let maximumResetRearms = 12
}

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
/// that does not. They share a clock, a store, a strip and every rule about what happens when
/// the moment arrives, so splitting them into two types would be two of everything below.
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
            guard case .session(let id) = self else { return nil }
            return id
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

    // MARK: - Properties

    let id: ScheduledMessageID
    let createdAt: Date

    /// The instant, and what the user actually said.
    ///
    /// Both, because they disagree the moment a machine changes time zone: scheduling "tomorrow
    /// at 09:00" in Stockholm and opening the laptop in New York fires at 03:00 while every
    /// label relabels itself to 03:00 — which would make the sheet's named time zone a promise
    /// the record could not keep. `ScheduledMessageScheduler` recomputes `dueAt` from the two
    /// fields below when the system time zone changes.
    var dueAt: Date
    let intendedTimeZoneIdentifier: String
    let intendedWallClock: DateComponents

    var target: Target
    var text: String
    var context: [ConversationContextAttachment]
    var anchor: Anchor
    var state: State

    /// How many times a reset-anchored send has already stood aside for a window that had not
    /// actually reset. Bounded by `ScheduledResetPolicy`; see `ScheduledMessageDefaults`.
    var resetRearmCount: Int

    var intendedTimeZone: TimeZone {
        TimeZone(identifier: intendedTimeZoneIdentifier) ?? .current
    }

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
        self.dueAt = dueAt
        self.intendedTimeZoneIdentifier = timeZone.identifier
        self.intendedWallClock = wallClockCalendar.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: dueAt
        )
        self.target = target
        self.text = text
        self.context = context
        self.anchor = anchor
        self.state = state
        self.resetRearmCount = resetRearmCount
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

    func isDue(at now: Date) -> Bool { dueAt <= now }

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
        ScheduledMessage(
            id: id,
            createdAt: createdAt,
            dueAt: newDueAt,
            timeZone: timeZone,
            calendar: calendar,
            target: target,
            text: text,
            context: context,
            anchor: anchor,
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

import AppKit

// MARK: - Scheduled Message Scheduler

/// Watches clock and session-finish triggers in `ScheduledMessageStore`.
///
/// `SessionArchiveScheduler`'s shape, one feature along: it knows when, and nothing else. It
/// announces a due send (`ScheduledMessageDidBecomeDue`) and `SessionCoordinator` — which already
/// owns every other lifecycle decision — performs it. Nothing here knows about sidebars, surfaces
/// or launching, which is what keeps `check_architecture_boundaries.sh` satisfied and what makes
/// the rules below testable with no live agent.
///
/// **`Date()` is the only authority.** A timer does not fire while the machine sleeps, and one
/// armed against uptime is wrong after an NTP step, so nothing here counts elapsed intervals:
/// every decision compares a stored instant against the current one. The triggers exist to make
/// the comparison happen often enough, not to measure anything.
///
/// **Two notification centres, and the second one is not optional.**
/// Workspace sleep and wake notifications are posted on `NSWorkspace.shared.notificationCenter`,
/// never on `.default`. A scheduler that observed only the default centre would compile, run,
/// and silently deliver a clock send late after sleep.
@MainActor
final class ScheduledMessageScheduler {

    // MARK: - Singleton

    static let shared = ScheduledMessageScheduler()

    // MARK: - Properties

    private let store: ScheduledMessageStore
    private let center: NotificationCenter
    private let workspaceCenter: NotificationCenter
    private let now: @MainActor () -> Date
    private let activity: @MainActor (SessionID) -> SessionActivity
    private let reportsOwnTurns: @MainActor (SessionID) -> Bool
    private let sessionExists: @MainActor (SessionID) -> Bool

    private var observations: AppEventObservations?
    private var workspaceObservations: AppEventObservations?
    private var timer: Timer?
    private var hasStarted = false
    private var isWorkspaceSleeping = false

    /// When each `waiting` send first found its surface busy, so politeness can be bounded
    /// without the record on disk growing a field only this class would read.
    private var waitingSince: [ScheduledMessageID: Date] = [:]

    /// Watched turns this run of Threading has actually seen in flight.
    ///
    /// `SessionActivityDidChange` intentionally carries only an id, and `SessionStart` posts it
    /// even when activity stays idle. Requiring this receipt turns a current idle snapshot into
    /// the edge it claims to be and prevents a relaunch from spending an old condition.
    private var finishTurnsObservedInFlight: Set<SessionID> = []

    // MARK: - Initialization

    /// Everything is injected for `SessionArchiveScheduler`'s reason: the rules have to be
    /// exercisable without a live agent, a window, or the running app's own event traffic.
    init(
        store: ScheduledMessageStore = .shared,
        center: NotificationCenter = .default,
        workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        now: @escaping @MainActor () -> Date = { Date() },
        activity: @escaping @MainActor (SessionID) -> SessionActivity = {
            AgentRuntime.shared.activity(sessionID: $0)
        },
        reportsOwnTurns: @escaping @MainActor (SessionID) -> Bool = {
            AgentRuntime.shared.reportsOwnTurns(sessionID: $0)
        },
        sessionExists: @escaping @MainActor (SessionID) -> Bool = {
            ProjectStore.shared.session(withID: $0) != nil
        }
    ) {
        self.store = store
        self.center = center
        self.workspaceCenter = workspaceCenter
        self.now = now
        self.activity = activity
        self.reportsOwnTurns = reportsOwnTurns
        self.sessionExists = sessionExists
    }

    // MARK: - Public Methods

    /// Begins watching, and settles what the app missed while it was not running.
    ///
    /// Called from the same place and behind the same two gates as the startup relaunch
    /// (`mcpServerHasStarted && !isOnboardingActive`), not from `applicationDidFinishLaunching`:
    /// a launch reads the MCP port for `--mcp-config`, and a session started into a window that
    /// is still deferring gets a PTY in a pane nobody will ever see.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        let observations = AppEventObservations(center: center)
        observations.observe(ScheduledMessagesDidChange.self) { [weak self] _ in
            self?.rearm()
        }
        // A send that found its target busy is owed another try the moment that target settles.
        observations.observe(SessionActivityDidChange.self) { [weak self] event in
            // Retry sends whose own trigger already happened first. If the same activity edge
            // satisfies a new finish trigger and its destination is busy, the performer changes
            // that record to `waiting`; evaluating after that would offer it twice on one edge.
            self?.evaluate()
            self?.evaluateCompletion(of: event.sessionID)
        }
        // A send held by a session's curfew is waiting on nothing the clock or an activity edge
        // announces: it is released when the user lifts the curfew, or when a standing quiet
        // window closes. Without this the message would sit until the next unrelated tick.
        observations.observe(CurfewDidChange.self) { [weak self] _ in
            self?.evaluate()
        }
        observations.observe(NSApplication.didBecomeActiveNotification) { [weak self] in
            self?.evaluate()
        }
        // A clock step moves every instant relative to now; a time-zone change moves what the
        // user's own words meant. Both are re-read rather than trusted.
        observations.observe(NSNotification.Name.NSSystemClockDidChange) { [weak self] in
            self?.evaluate()
        }
        observations.observe(NSNotification.Name.NSSystemTimeZoneDidChange) { [weak self] in
            self?.reanchorAndEvaluate()
        }
        self.observations = observations

        let workspaceObservations = AppEventObservations(center: workspaceCenter)
        workspaceObservations.observe(NSWorkspace.willSleepNotification) { [weak self] in
            self?.workspaceWillSleep()
        }
        workspaceObservations.observe(NSWorkspace.didWakeNotification) { [weak self] in
            self?.catchUpAfterWake()
        }
        self.workspaceObservations = workspaceObservations

        catchUpAfterLaunch()
        evaluate()
    }

    /// Settles everything whose moment passed while the app was not running.
    ///
    /// **Nothing is delivered.** There is no grace window and no late send: the app is not a
    /// server, and the one rule is that it never sends what the clock passed while it was not
    /// watching. The whole batch is announced once so the window can ask about them together.
    func catchUpAfterLaunch() {
        reportMissedClockMessages(
            before: now(),
            eventMessage: "Scheduled sends missed while quit"
        )
    }

    private func catchUpAfterWake() {
        reportMissedClockMessages(
            before: now(),
            eventMessage: "Scheduled sends missed during sleep"
        )
        isWorkspaceSleeping = false
        evaluate()
    }

    private func reportMissedClockMessages(before moment: Date, eventMessage: String) {
        let missed = store.markMissed(before: moment)
        guard !missed.isEmpty else { return }

        for message in missed { waitingSince.removeValue(forKey: message.id) }
        EventLog.shared.record(.composer, eventMessage, [
            "count": String(missed.count)
        ])
        center.post(ScheduledMessagesWereMissed(ids: missed.map(\.id)))
    }

    /// Announces everything due right now, and re-arms for whatever is next.
    func evaluate() {
        guard hasStarted, !isWorkspaceSleeping else { return }

        let moment = now()
        for message in store.due(at: moment) {
            guard canAttemptNow(message, at: moment) else { continue }
            center.post(ScheduledMessageDidBecomeDue(id: message.id))
        }
        rearm()
    }

    /// Announces sends waiting for this conversation's current turn to finish.
    ///
    /// Activity changes call this on the authoritative edge. A scheduling surface also calls it
    /// immediately after filing a record with `acceptsSettledSnapshot`: the selected turn can
    /// finish while its picker sheet is open, between the last activity event and the durable
    /// write, and that race should send now rather than wait for an unrelated later turn.
    func evaluateCompletion(
        of sessionID: SessionID,
        acceptsSettledSnapshot: Bool = false
    ) {
        guard hasStarted else { return }
        let messages = store.dueWhenSessionFinishes(sessionID)
        guard !messages.isEmpty else { return }

        guard sessionExists(sessionID) else {
            for message in messages {
                store.fail(
                    message.id,
                    reason: L10n.string("The conversation this was waiting for was deleted.")
                )
            }
            return
        }

        if activity(sessionID).hasTurnInFlight {
            guard reportsOwnTurns(sessionID) else { return }
            finishTurnsObservedInFlight.insert(sessionID)
            return
        }
        guard acceptsSettledSnapshot || reportsOwnTurns(sessionID) else { return }
        guard acceptsSettledSnapshot
                || finishTurnsObservedInFlight.remove(sessionID) != nil else { return }

        for message in messages {
            center.post(ScheduledMessageDidBecomeDue(id: message.id))
        }
        rearm()
    }

    /// Records that a send is still waiting on a surface that could not take it.
    ///
    /// Kept here rather than on disk: how long something has been waiting is a fact about this
    /// run of the app, and a `waiting` record reloaded tomorrow starts its patience over, which
    /// is the right answer anyway.
    func noteWaiting(_ id: ScheduledMessageID) {
        if waitingSince[id] == nil { waitingSince[id] = now() }
    }

    func forgetWaiting(_ id: ScheduledMessageID) {
        waitingSince.removeValue(forKey: id)
    }

    // MARK: - Private Methods

    /// Whether a due send should be offered to the performer at all yet.
    ///
    /// Only ever *delays* — the performer decides what a surface can take. This exists so a
    /// target that is mid-turn is not re-announced on every keystroke of output, and so a send
    /// that has been patient for long enough stops asking and says so.
    private func canAttemptNow(_ message: ScheduledMessage, at moment: Date) -> Bool {
        guard case .waiting = message.state else { return true }
        guard let since = waitingSince[message.id] else { return true }

        guard moment.timeIntervalSince(since) < ScheduledMessageDefaults.waitingRetryWindow else {
            store.fail(
                message.id,
                reason: L10n.string("Its session stayed busy, so this was never sent.")
            )
            waitingSince.removeValue(forKey: message.id)
            return false
        }

        // A target whose agent does not report its own turns has no idle edge worth believing
        // — `SessionActivity` says so itself. Waiting on a guess and then typing on it is the
        // one thing an unattended send must not do.
        guard let sessionID = message.target.sessionID else { return true }
        return reportsOwnTurns(sessionID)
    }

    private func reanchorAndEvaluate() {
        _ = store.reanchorWallClockMoments()
        evaluate()
    }

    private func workspaceWillSleep() {
        isWorkspaceSleeping = true
        timer?.invalidate()
        timer = nil
    }

    /// Points one timer at the next moment anything is waiting for.
    ///
    /// One timer rather than one per send, and re-armed from scratch on every change: a timer
    /// per record would multiply the ways a schedule can be armed twice or not at all.
    private func rearm() {
        timer?.invalidate()
        timer = nil

        rememberFinishTurnsInFlight()

        guard hasStarted, !isWorkspaceSleeping, store.hasClockWorkPending else { return }

        let moment = now()
        let interval: TimeInterval
        if let next = store.nextDueDate(after: moment) {
            interval = max(ScheduledSchedulerDefaults.minimumInterval, next.timeIntervalSince(moment))
        } else {
            // No timed trigger is armed, but a delivery is waiting on a busy surface. The
            // activity edge is the real signal; this only lets its patience run out. Armed
            // finish triggers do not reach here — their authoritative edge needs no polling.
            interval = ScheduledSchedulerDefaults.heartbeat
        }

        let capped = min(interval, ScheduledSchedulerDefaults.heartbeat)
        let nextTimer = Timer(timeInterval: capped, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }
        // A long wait need not be punctual to the second, and letting the system coalesce it
        // keeps a scheduled send from being a reason the CPU wakes.
        nextTimer.tolerance = capped * ScheduledSchedulerDefaults.toleranceFraction
        timer = nextTimer
        // Menu tracking and modal sheets are still time the app is awake and watching. Common
        // modes keep the five-minute bound valid through both rather than deferring the timer
        // until the default run-loop mode returns.
        RunLoop.main.add(nextTimer, forMode: .common)
    }

    /// Seeds the edge receipt when a condition is added during a turn or the scheduler starts
    /// midway through one. It never spends a condition: an idle snapshot merely stays absent.
    private func rememberFinishTurnsInFlight() {
        let armed = store.armedFinishSessionIDs
        finishTurnsObservedInFlight.formIntersection(armed)
        for sessionID in armed
        where reportsOwnTurns(sessionID) && activity(sessionID).hasTurnInFlight {
            finishTurnsObservedInFlight.insert(sessionID)
        }
    }
}

// MARK: - Defaults

enum ScheduledSchedulerDefaults {

    /// The longest a single arming may run before the clock is consulted again.
    ///
    /// A ceiling on *ignorance*, not a poll: a timer armed for tomorrow morning does not fire
    /// during sleep and would come back whenever the machine happened to wake. Waking every few
    /// minutes to compare two dates costs nothing and means a due send is never more than this
    /// late, whatever the system did with the timer.
    static let heartbeat: TimeInterval = 5 * 60

    /// The floor, so a due-in-a-moment send cannot arm a zero-interval timer in a loop.
    static let minimumInterval: TimeInterval = 1

    static let toleranceFraction = 0.1
}

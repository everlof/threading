import AppKit

// MARK: - Scheduled Message Scheduler

/// Watches the clock for everything waiting in `ScheduledMessageStore`.
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
/// `NSWorkspace.didWakeNotification` is posted on `NSWorkspace.shared.notificationCenter`, never
/// on `.default`. A scheduler that observed only the default centre would compile, run, and
/// silently never re-evaluate after sleep — which is the single case this whole class exists for.
@MainActor
final class ScheduledMessageScheduler {

    // MARK: - Singleton

    static let shared = ScheduledMessageScheduler()

    // MARK: - Properties

    private let store: ScheduledMessageStore
    private let center: NotificationCenter
    private let workspaceCenter: NotificationCenter
    private let now: @MainActor () -> Date
    private let reportsOwnTurns: @MainActor (SessionID) -> Bool

    private var observations: AppEventObservations?
    private var workspaceObservations: AppEventObservations?
    private var timer: Timer?
    private var hasStarted = false

    /// When each `waiting` send first found its surface busy, so politeness can be bounded
    /// without the record on disk growing a field only this class would read.
    private var waitingSince: [ScheduledMessageID: Date] = [:]

    // MARK: - Initialization

    /// Everything is injected for `SessionArchiveScheduler`'s reason: the rules have to be
    /// exercisable without a live agent, a window, or the running app's own event traffic.
    init(
        store: ScheduledMessageStore = .shared,
        center: NotificationCenter = .default,
        workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        now: @escaping @MainActor () -> Date = { Date() },
        reportsOwnTurns: @escaping @MainActor (SessionID) -> Bool = {
            AgentRuntime.shared.reportsOwnTurns(sessionID: $0)
        }
    ) {
        self.store = store
        self.center = center
        self.workspaceCenter = workspaceCenter
        self.now = now
        self.reportsOwnTurns = reportsOwnTurns
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
        observations.observe(SessionActivityDidChange.self) { [weak self] _ in
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
        workspaceObservations.observe(NSWorkspace.didWakeNotification) { [weak self] in
            self?.evaluate()
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
        let missed = store.markMissed(before: now())
        guard !missed.isEmpty else { return }

        EventLog.shared.record(.composer, "Scheduled sends missed while quit", [
            "count": String(missed.count)
        ])
        center.post(ScheduledMessagesWereMissed(ids: missed.map(\.id)))
    }

    /// Announces everything due right now, and re-arms for whatever is next.
    func evaluate() {
        guard hasStarted else { return }

        let moment = now()
        for message in store.due(at: moment) {
            guard canAttemptNow(message, at: moment) else { continue }
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

    /// Points one timer at the next moment anything is waiting for.
    ///
    /// One timer rather than one per send, and re-armed from scratch on every change: a timer
    /// per record would multiply the ways a schedule can be armed twice or not at all.
    private func rearm() {
        timer?.invalidate()
        timer = nil

        guard hasStarted, store.hasAnythingPending else { return }

        let moment = now()
        let interval: TimeInterval
        if let next = store.nextDueDate(after: moment) {
            interval = max(ScheduledSchedulerDefaults.minimumInterval, next.timeIntervalSince(moment))
        } else {
            // Nothing armed, but something is waiting on a busy surface. The activity edge is
            // the real signal; this is only so patience can run out while a session stays busy.
            interval = ScheduledSchedulerDefaults.heartbeat
        }

        let capped = min(interval, ScheduledSchedulerDefaults.heartbeat)
        timer = Timer.scheduledTimer(withTimeInterval: capped, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }
        // A long wait need not be punctual to the second, and letting the system coalesce it
        // keeps a scheduled send from being a reason the CPU wakes.
        timer?.tolerance = capped * ScheduledSchedulerDefaults.toleranceFraction
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

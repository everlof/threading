import AppKit

// MARK: - Startup Session Relaunch

/// Decides which sessions a launch brings back after the app was quit with agents running.
///
/// **Every rule here is a rule about a bound.** `.runningAtLastQuit` is bounded by the live set the
/// quit recorded after idle retention ran; protected unfinished work may exceed the warm-process
/// cap and stays in that record. `.recentlyUsed` is bounded by the cap it is given, because a time
/// window is not a bound at all — a heavy week is a heavy launch.
/// A rule like "every session in the sidebar" has neither: a store with forty dormant
/// conversations would boot forty CLIs nobody asked for, at a couple of hundred megabytes each.
///
/// The two exist together because the first depends on one record, and a reboot, a force quit, or
/// an app that opened and closed again without restoring anything leaves that record saying
/// nothing at all. The second reads the conversations themselves and survives all three.
enum StartupSessionRelaunch {

    /// The launch set, and the reason for every session that is not in it.
    struct Plan: Equatable {
        /// To launch, in order.
        let sessionIDs: [SessionID]

        /// One answer per unarchived session, including the ones being launched.
        let outcomes: [SessionID: SessionRestorationOutcome]

        static let empty = Plan(sessionIDs: [], outcomes: [:])
    }

    /// Orders and filters the sessions into the relaunch plan for one policy.
    ///
    /// The record is navigation state that outlives the sessions it names: anything deleted or
    /// archived since the quit is dropped by lookup rather than trusted. The excluded id is the
    /// one `restoreSelectedSession` is already bringing back on screen — launching it here as
    /// well would race the selection's own launch. Most recently used goes first, because the
    /// stagger means the last in line waits the whole line, and the session touched last is the
    /// one most likely to be wanted first.
    ///
    /// `heldByHost` is what `threading-ptyd` was still running when this launch asked, and it
    /// outranks every policy: a session that never stopped is not a session to start. Relaunching
    /// one would put a second agent on a conversation whose first is still working, so those ids
    /// leave the launch set entirely and are answered `.reattached` instead — which is a
    /// different fact from `.restored` and worth being able to tell apart.
    static func plan(
        policy: SessionRestorePolicy,
        recorded: [SessionID],
        sessions: [AgentSession],
        windowDays: Int = SessionRestoreDefaults.windowDays,
        limit: Int = SessionRestoreDefaults.limit,
        now: Date = Date(),
        excluding excludedID: SessionID? = nil,
        heldByHost: Set<SessionID> = []
    ) -> Plan {
        let planned = policyPlan(
            policy: policy,
            recorded: recorded,
            sessions: sessions,
            windowDays: windowDays,
            limit: limit,
            now: now,
            excluding: excludedID
        )
        guard !heldByHost.isEmpty else { return planned }

        var outcomes = planned.outcomes
        for sessionID in heldByHost where outcomes[sessionID] != nil {
            outcomes[sessionID] = .reattached
        }
        return Plan(
            sessionIDs: planned.sessionIDs.filter { !heldByHost.contains($0) },
            outcomes: outcomes
        )
    }

    private static func policyPlan(
        policy: SessionRestorePolicy,
        recorded: [SessionID],
        sessions: [AgentSession],
        windowDays: Int,
        limit: Int,
        now: Date,
        excluding excludedID: SessionID?
    ) -> Plan {
        // Archived sessions are not dormant rows anybody can see, so they earn no outcome: the
        // sidebar does not list them and Settings ▸ Archived is where they are explained.
        let listed = sessions.filter { !$0.isArchived }

        switch policy {
        case .nothing:
            return Plan(
                sessionIDs: [],
                outcomes: outcomes(for: listed, restored: [], otherwise: { _ in .restoreDisabled })
            )

        case .runningAtLastQuit:
            let byID = Dictionary(
                listed.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let ordered = recorded
                .compactMap { byID[$0] }
                .sorted { $0.lastUsedAt > $1.lastUsedAt }
                .map(\.id)
            // An empty record and a session that simply was not running are different facts, and
            // the difference is the one worth saying out loud: the first means the last quit left
            // nothing to bring back, which is a thing that happens *to* a user rather than a
            // thing they chose.
            let reason: SessionRestorationOutcome =
                recorded.isEmpty ? .nothingRecorded : .notRunningAtLastQuit
            return Plan(
                sessionIDs: ordered.filter { $0 != excludedID },
                outcomes: outcomes(
                    for: listed,
                    restored: Set(ordered).union(excludedID.map { [$0] } ?? []),
                    otherwise: { _ in reason }
                )
            )

        case .recentlyUsed:
            let days = SessionRestoreDefaults.clampWindowDays(windowDays)
            let limit = SessionRestoreDefaults.clampLimit(limit)
            let threshold = now.addingTimeInterval(
                -Double(days) * SessionRestoreDefaults.secondsPerDay
            )
            let inWindow = listed
                .filter { $0.lastUsedAt >= threshold }
                .sorted { $0.lastUsedAt > $1.lastUsedAt }
            let chosen = inWindow.prefix(limit).map(\.id)
            let chosenIDs = Set(chosen)
            return Plan(
                sessionIDs: chosen.filter { $0 != excludedID },
                outcomes: outcomes(
                    for: listed,
                    restored: chosenIDs.union(excludedID.map { [$0] } ?? []),
                    otherwise: { session in
                        session.lastUsedAt >= threshold
                            ? .beyondLimit(limit: limit)
                            : .outsideWindow(days: days, lastUsedAt: session.lastUsedAt)
                    }
                )
            )
        }
    }

    private static func outcomes(
        for sessions: [AgentSession],
        restored: Set<SessionID>,
        otherwise reason: (AgentSession) -> SessionRestorationOutcome
    ) -> [SessionID: SessionRestorationOutcome] {
        sessions.reduce(into: [:]) { outcomes, session in
            outcomes[session.id] = restored.contains(session.id) ? .restored : reason(session)
        }
    }
}

// MARK: - Restoration Outcome

/// Why one session is, or is not, live after a launch.
///
/// Recorded rather than recomputed. The answer belongs to the decision that was actually made,
/// and the row that asks for it may be hovered an hour later, by which time the ranking that
/// produced it has moved — a card that explains today's ranking for yesterday's launch is worse
/// than one that explains nothing. Recomputing per row would also make a pointer-driven surface
/// do work proportional to the whole store, which the scaling gate rules out.
enum SessionRestorationOutcome: Equatable, Sendable {

    /// Brought back live by this launch, or being brought back by the restored selection.
    case restored

    /// It never went away. `threading-ptyd` was still running it when this launch asked, so
    /// there was nothing to bring back — the terminal was reconnected to a process that had been
    /// working the whole time.
    ///
    /// Distinct from `restored` because the two are different facts about the same row, and the
    /// difference is the one a person asks about: a session that came back lost its turn in
    /// flight, and a session that never stopped did not.
    case reattached

    /// Launch restore is switched off.
    case restoreDisabled

    /// It had no live agent at the last quit.
    case notRunningAtLastQuit

    /// The last quit recorded nothing — an unclean exit, or a launch that quit again before it
    /// spent the record. This is the state the guard in `AppDelegate` exists to make rare.
    case nothingRecorded

    /// Last used before the window starts.
    case outsideWindow(days: Int, lastUsedAt: Date)

    /// Inside the window, but the limit was already full of more recent sessions.
    case beyondLimit(limit: Int)
}

// MARK: - Restoration Ledger

/// What this launch decided about each session, kept for as long as the answer is still true.
///
/// In memory only, and deliberately: it describes one launch, and a stale answer read from disk
/// after two days of use would explain a decision nobody is looking at any more.
@MainActor
final class SessionRestorationLedger {

    static let shared = SessionRestorationLedger()

    private var outcomes: [SessionID: SessionRestorationOutcome] = [:]

    func record(_ plan: StartupSessionRelaunch.Plan) {
        outcomes = plan.outcomes
    }

    /// Forgotten the moment the session runs. From then on, dormancy is its own agent having
    /// exited, not a decision this launch made, and the launch's reason would be a lie.
    func forget(sessionID: SessionID) {
        outcomes.removeValue(forKey: sessionID)
    }

    func outcome(for sessionID: SessionID) -> SessionRestorationOutcome? {
        outcomes[sessionID]
    }

    /// For tests, and for a reset that must not leave one launch's answers behind.
    func removeAll() {
        outcomes.removeAll()
    }
}

// MARK: - Startup Session Relauncher

/// Walks the plan one session per tick, so the launches spread out instead of landing at once.
///
/// The stagger is the performance half of the feature. Each launch spawns a login shell that
/// `exec`s an agent CLI, and the CLI's own boot is the expensive part — a burst of CPU per
/// process. Fired together, N of those all contend through the app's first seconds; spread a
/// second apart, each gets the machine roughly to itself, and the per-launch main-thread work
/// (the MCP config writes, building and laying out the surface) stays a small slice of its own
/// run-loop turn instead of N slices of one. The first launch waits a full interval too, which
/// is the restored selected session's head start.
@MainActor
final class StartupSessionRelauncher {

    // MARK: - Properties

    private var pending: [SessionID]
    private let interval: TimeInterval
    private let launch: (SessionID) -> Void
    private let timer = MainRunLoopTimer()

    // MARK: - Initialization

    /// The launch closure re-validates its session against the store at fire time; the plan
    /// was computed at startup and the user may have clicked, archived, or deleted since.
    /// The interval is injectable so a test is not a two-second wait on a wall clock.
    init(
        sessionIDs: [SessionID],
        interval: TimeInterval = StartupRelaunchDefaults.staggerInterval,
        launch: @escaping (SessionID) -> Void
    ) {
        self.pending = sessionIDs
        self.interval = interval
        self.launch = launch
    }

    // MARK: - Public Methods

    /// Begins the stagger. Idempotent while running; the timer retires itself with the plan.
    func start() {
        guard !timer.isInstalled, !pending.isEmpty else { return }

        let timer = Timer.scheduledTimer(
            withTimeInterval: interval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.launchNext()
            }
        }
        timer.tolerance = StartupRelaunchDefaults.staggerTolerance
        self.timer.install(timer)
    }

    // MARK: - Private Methods

    private func launchNext() {
        guard !pending.isEmpty else {
            timer.invalidate()
            return
        }

        launch(pending.removeFirst())

        if pending.isEmpty {
            timer.invalidate()
        }
    }
}

// MARK: - Startup Relaunch Defaults

enum StartupRelaunchDefaults {
    /// How long each relaunch waits behind the previous one. Long enough for an agent CLI's
    /// boot burst to pass its peak; short enough that five sessions are all up within seconds.
    static let staggerInterval: TimeInterval = 1.0

    /// The timing is pacing, not a deadline, so the system may coalesce the wakeups.
    static let staggerTolerance: TimeInterval = 0.25

    /// The frame a background-launched surface is laid out at when the pane cannot be asked.
    /// Matches the remote-browser E2E fixture's terminal, a size every agent TUI handles.
    static let fallbackSize = NSSize(width: 900, height: 620)

    /// Bounds below this are a pane mid-setup, not an answer worth adopting.
    static let minimumPaneDimension: CGFloat = 200
}

extension SessionRestoreDefaults {

    /// The window is stated in days because that is how it is chosen and explained. Calendar
    /// arithmetic would be wrong here for the opposite of the usual reason: this measures elapsed
    /// use, not a date, so a session used 25 hours ago is outside a one-day window whichever side
    /// of midnight it fell on.
    static let secondsPerDay: TimeInterval = 24 * 60 * 60
}

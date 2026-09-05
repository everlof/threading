import Foundation

// MARK: - Session Watch Center

/// Holds one session's request to be told when another session crosses its next activity edge,
/// and spends it once.
///
/// **The point is that nobody polls.** Without this, a session waiting on a sibling's result can
/// only call `list_sessions` again and again — every call spending a turn of its own usage to
/// learn nothing, and the interval between calls deciding how late the answer arrives. A watch
/// costs one delivery, at the moment the fact becomes true.
///
/// **The boundary is the runtime's typed pending-outcome answer in both directions.** A target
/// with an unfinished outcome is watched for its completion; a settled target is watched for the
/// next outcome to begin. The state read and watch insertion are
/// one main-actor operation, so the transition cannot land in between them. Re-arming after each
/// notice gives a caller fail-closed current-state coverage without an unbounded subscription.
///
/// **In memory, one-shot, and bounded.** A watch dies with the app run, fires at most once and is
/// then spent. A caller may put a wall-clock timeout on that wait; omission means the watch lasts
/// until the target settles or this Threading run ends, not until an arbitrary default deadline.
/// One watcher may hold at most `ControlWatchDefaults.maximumPerWatcher` — the bounded-work rule,
/// and a bound on being woken, since every notice spends a turn of the watcher's own usage.
///
/// The notice itself is written here, in Threading's own voice, and deliberately *not* under the
/// `[Cross-session message …]` header: that header states the body was written by the sending
/// session's agent, which for a watch notice would be a lie about who is speaking.
@MainActor
final class SessionWatchCenter {

    // MARK: - Dependencies

    struct Dependencies {
        let activity: (SessionID) -> SessionActivity
        let runtime: (SessionID) -> SessionRuntimeSnapshot
        /// Read at fire time, not at arm time: a session is renamed by its own agent mid-turn,
        /// and a notice naming what the row said half an hour ago names something the watcher
        /// cannot find in `list_sessions`.
        let sessionTitle: (SessionID) -> String?
        /// Hands the notice to the watcher's live surface — the same receipt-backed seam a
        /// cross-session send uses, so an undeliverable notice is known to be undeliverable
        /// rather than assumed to have landed.
        let deliverNotice: (
            String, SessionID, @escaping @MainActor (SessionMessageDelivery.Outcome) -> Void
        ) -> Void
    }

    // MARK: - Arming

    /// What became of an ask to watch, before the plane dresses it in scope.
    enum WatchArmOutcome: Equatable {
        case armed(awaiting: ControlWatchEdge, expiresAfter: TimeInterval?)
        /// This watcher already watches this target. Coalesced rather than doubled: two watches
        /// on one edge would deliver the same notice twice, spending two of the watcher's turns
        /// on one fact.
        case alreadyWatching(awaiting: ControlWatchEdge)
        case watcherAtCapacity(limit: Int)
        case invalidTimeout
    }

    // MARK: - Properties

    /// The live lookups are assembled here rather than as defaults on `Dependencies`, for the
    /// reason `WorkspaceControlPlane.live` is: this type is main-actor isolated, and a static on
    /// the nested struct would be a global holding non-`Sendable` closures.
    static let shared = SessionWatchCenter(
        dependencies: Dependencies(
            activity: { AgentRuntime.shared.activity(sessionID: $0) },
            runtime: { AgentRuntime.shared.runtimeSnapshot(sessionID: $0) },
            sessionTitle: { ProjectStore.shared.session(withID: $0)?.displayTitle },
            deliverNotice: { SessionMessageDelivery.deliver($0, to: $1, completion: $2) }
        )
    )

    private struct WatchKey: Hashable {
        let watcher: SessionID
        let target: SessionID
    }

    private struct Watch {
        let armedAt: Date
        let awaiting: ControlWatchEdge
        let expiresAfter: TimeInterval?
        let timer: Timer?
    }

    private var watches: [WatchKey: Watch] = [:]

    /// Notices that fired while the watcher could not take them — mid-turn at its own
    /// terminal, most commonly, which is exactly when a manager's worker settles. Held rather
    /// than dropped, because the fact a notice carries stays true, and the watcher's own next
    /// settle edge is already on the one event stream this type observes. Only an *ambiguous*
    /// delivery is never retried: `.typedUnconfirmed` means the first copy may have landed,
    /// and a manager handed the same conclusion twice will act on it twice.
    private var heldNotices: [SessionID: [String]] = [:]

    private let observations: AppEventObservations
    private let dependencies: Dependencies
    private let now: () -> Date

    // MARK: - Initialization

    /// The centre, the clock and the lookups are injected so this can be exercised without a
    /// live agent, a store, or the running app's own event traffic.
    init(
        center: NotificationCenter = .default,
        now: @escaping () -> Date = { Date() },
        dependencies: Dependencies
    ) {
        self.dependencies = dependencies
        self.now = now
        self.observations = AppEventObservations(center: center)

        observations.observe(SessionRuntimeDidChange.self) { [weak self] event in
            self?.runtimeChanged(event)
        }
    }

    // MARK: - Public Methods

    /// Arms one watcher's one-shot watch on one target.
    ///
    /// Every answer other than `.armed` is a refusal to pretend: an agent told a watch exists
    /// will stop and wait for it, so a coalesced, settled or over-budget ask has to say so.
    @discardableResult
    func arm(
        watcher: SessionID,
        target: SessionID,
        timeout: TimeInterval? = nil
    ) -> WatchArmOutcome {
        let key = WatchKey(watcher: watcher, target: target)
        if let existing = watches[key] {
            return .alreadyWatching(awaiting: existing.awaiting)
        }

        if let timeout, !ControlWatchDefaults.isValid(timeout: timeout) {
            return .invalidTimeout
        }

        let held = watches.keys.filter { $0.watcher == watcher }.count
        guard held < ControlWatchDefaults.maximumPerWatcher else {
            return .watcherAtCapacity(limit: ControlWatchDefaults.maximumPerWatcher)
        }

        // Main-actor isolation makes this snapshot and the insertion below atomic with respect
        // to `activityChanged`. An edge can happen before the read or after the insertion, never
        // in the gap — the fail-closed property a wait-for-all caller depends on.
        let awaiting: ControlWatchEdge = dependencies.runtime(target).hasPendingOutcome
            ? .turnSettled
            : .turnStarted

        let timer = timeout.map { timeout in
            Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.expire(key) }
            }
        }
        watches[key] = Watch(
            armedAt: now(),
            awaiting: awaiting,
            expiresAfter: timeout,
            timer: timer
        )
        return .armed(awaiting: awaiting, expiresAfter: timeout)
    }

    func isWatching(watcher: SessionID, target: SessionID) -> Bool {
        watches[WatchKey(watcher: watcher, target: target)] != nil
    }

    // MARK: - Private Methods

    /// One session's activity moved. It may be a watched target — several watchers may hold a
    /// watch on it, each spent or retired on its own terms — and it may itself be a watcher
    /// owed notices held from while it was busy; its settle edge is the retry moment.
    private func runtimeChanged(_ event: SessionRuntimeDidChange) {
        let target = event.sessionID
        let runtime = event.transition.current

        // Drain before anything else: a dormant or limit-parked session cannot take a
        // delivery, so those states hold rather than spend an attempt that must fail.
        if runtime.isPromptReady {
            drainHeldNotices(for: target)
        }

        for key in watches.keys.filter({ $0.target == target }) {
            // A watch whose timer has not been serviced — the run loop was blocked, the machine
            // slept — is retired rather than spent on an edge it has already outlived.
            guard let watch = watches[key] else { continue }
            if let expiresAfter = watch.expiresAfter,
               now().timeIntervalSince(watch.armedAt) >= expiresAfter {
                expire(key)
            } else if let transition = Self.transition(
                awaitedBy: watch,
                after: event.transition
            ) {
                fire(
                    key,
                    notice: Self.notice(
                        for: transition,
                        title: title(of: target),
                        target: target
                    )
                )
            }
        }
    }

    /// Delivers a notice and spends the watch. The watch is removed *before* the delivery: a
    /// delivery that synchronously moves the watcher's own activity must not re-enter here and
    /// find the same watch still armed.
    private func fire(_ key: WatchKey, notice: String) {
        watches.removeValue(forKey: key)?.timer?.invalidate()
        attemptDelivery(notice, to: key.watcher)
    }

    private func expire(_ key: WatchKey) {
        guard let watch = watches[key], let expiresAfter = watch.expiresAfter else { return }
        let notice = Self.expiryNotice(
            title: title(of: key.target),
            target: key.target,
            awaiting: watch.awaiting,
            after: expiresAfter
        )
        fire(key, notice: notice)
    }

    /// One try at the watcher's surface, and an honest disposition for each way it can answer.
    ///
    /// A watcher that cannot take the notice *yet* — mid-turn at its terminal, briefly dormant,
    /// its input held — gets the notice held for its own settle edge. Only `.typedUnconfirmed`
    /// ends the story with a ledger record: the first copy may have landed, and the one thing
    /// worse than a manager not hearing a conclusion is a manager acting on it twice.
    private func attemptDelivery(_ notice: String, to watcher: SessionID) {
        dependencies.deliverNotice(notice, watcher) { [weak self] outcome in
            switch outcome {
            case .sentNow, .queuedBehindTurn:
                return
            case .busyTerminal, .noLiveSurface, .notTaken:
                self?.hold(notice, for: watcher, after: outcome)
            case .typedUnconfirmed:
                EventLog.shared.record(.session, "Session watch notice was not delivered", [
                    "watcher": watcher.uuidString.lowercased(),
                    "outcome": String(describing: outcome),
                ])
            }
        }
    }

    private func hold(_ notice: String, for watcher: SessionID, after outcome: SessionMessageDelivery.Outcome) {
        var held = heldNotices[watcher, default: []]
        guard held.count < ControlWatchDefaults.maximumHeldNotices else {
            EventLog.shared.record(.session, "Session watch notice was dropped — held queue full", [
                "watcher": watcher.uuidString.lowercased(),
                "outcome": String(describing: outcome),
            ])
            return
        }
        held.append(notice)
        heldNotices[watcher] = held
    }

    private func drainHeldNotices(for watcher: SessionID) {
        guard let held = heldNotices.removeValue(forKey: watcher), !held.isEmpty else { return }
        // Each failure re-holds itself through `attemptDelivery`; attempts happen only on
        // edges, so a surface that stays unavailable costs one try per settle, not a loop.
        for notice in held {
            attemptDelivery(notice, to: watcher)
        }
    }

    /// The record can be gone by the time the watch fires — deleted while the turn ran. The
    /// notice is still worth delivering, since the fact it carries is that the work ended, so
    /// the id does the naming and the title says plainly that there is no row left to look at.
    private static let missingTitle = "a session no longer in the sidebar"

    private func title(of sessionID: SessionID) -> String {
        dependencies.sessionTitle(sessionID).map(WorkspaceControlPlane.safeHeaderTitle)
            ?? Self.missingTitle
    }

    // MARK: - Wording

    /// The transition the watched session made. Settlement keeps its three endings apart because
    /// "answer it", "resume it" and "wait for the window to reset" are different next moves.
    private enum Transition {
        case turnStarted(SessionActivity)
        case turnFinished
        case agentExited
        case usageLimit
    }

    private static func transition(
        awaitedBy watch: Watch,
        after runtime: SessionRuntimeTransition
    ) -> Transition? {
        let activity = runtime.current.activity
        switch watch.awaiting {
        case .turnStarted:
            return runtime.beganPendingOutcome ? .turnStarted(activity) : nil
        case .turnSettled:
            guard runtime.completedPendingOutcome else { return nil }
            switch activity {
            case .dormant:
                return .agentExited
            case .limitReached:
                return .usageLimit
            case .idle, .needsAttention:
                return .turnFinished
            case .working, .readyWithBackgroundWork, .awaitingUser:
                return nil
            }
        }
    }

    /// Threading's own frame, not the cross-session one.
    ///
    /// `[Cross-session message …]` states that the body was written by the named session's
    /// agent. Nothing here was: the target never asked for this to be sent and may not know a
    /// watch existed. Reusing that header would be a false claim about who is speaking, so the
    /// notice carries its own frame and says outright whose words these are.
    private static func notice(
        for transition: Transition,
        title: String,
        target: SessionID
    ) -> String {
        let body: String
        switch transition {
        case .turnStarted(.awaitingUser):
            body = "started a new turn and is already waiting on input."
        case .turnStarted:
            body = "started a new turn and is working."
        case .turnFinished:
            body = "finished its turn and is idle."
        case .agentExited:
            body = """
                — its agent exited; the session is dormant. Resuming it is the user's decision.
                """
        case .usageLimit:
            body = """
                stopped at its usage limit; nothing runs there until the window resets or the \
                user moves the conversation.
                """
        }

        return """
            [Session watch — Threading] “\(title)” (\(target.uuidString.lowercased())) \(body) \
            One-shot notice from watch_session; the watch is spent. Re-arm it to watch the \
            opposite edge. This is Threading speaking, not that session's agent.
            """
    }

    private static func expiryNotice(
        title: String,
        target: SessionID,
        awaiting: ControlWatchEdge,
        after expiry: TimeInterval
    ) -> String {
        let wait = switch awaiting {
        case .turnStarted: "before a new turn started"
        case .turnSettled: "with the turn still running"
        }
        return """
        [Session watch — Threading] The watch on “\(title)” \
        (\(target.uuidString.lowercased())) expired after \(minutesDescription(for: expiry)) \
        \(wait). Re-arm it if you still need the signal. This is \
        Threading speaking, not that session's agent.
        """
    }

    private static func minutesDescription(for interval: TimeInterval) -> String {
        let minutes = interval / 60
        if minutes.rounded() == minutes, minutes <= Double(Int.max) {
            return "\(Int(minutes)) minutes"
        }
        return "\(minutes) minutes"
    }
}

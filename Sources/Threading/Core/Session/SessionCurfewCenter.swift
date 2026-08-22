import AppKit

// MARK: - Session Curfew Center

/// The clock behind every curfew: one process timer, one persisted truth, and the four things a
/// deadline does to a session.
///
/// `SessionSnoozeCenter`'s shape, one feature along and with sharper teeth. Both keep a single
/// timer for the process rather than one per session, both derive every answer from what is on
/// disk rather than from whether a timer happened to fire, and both materialize what was missed
/// while the app was not running. The difference is what happens at the deadline: a snooze
/// changes what a row looks like, and a curfew stops the app spending somebody's session and —
/// past the grace — types into it.
///
/// **`now` is the only authority.** Nothing here counts elapsed intervals: a timer does not fire
/// while the machine is asleep, and one armed against uptime is wrong after an NTP step. Every
/// decision compares a stored instant against the current one, and the triggers below exist to
/// make that comparison happen often enough rather than to measure anything. `NSWorkspace`'s wake
/// is observed on `NSWorkspace.shared.notificationCenter`, never on `.default` — the mistake
/// `ScheduledMessageScheduler`'s own test exists for, and the single case this class is for.
///
/// **Nothing here names a UI type.** The native interrupt is *announced*
/// (`CurfewInterruptRequested`) and `SessionCoordinator` performs it, the way
/// `LimitAccountResumeRequested` already works: stopping a turn is a gesture on a conversation
/// surface, and Core's ratchet on concrete controllers is exact.
///
/// Expected scale is tens of live sessions and thousands of historical ones. `rebuildAndMaterialize`
/// makes one pass over the already-loaded records; every other entry point is O(1) in the sessions
/// it touches, and the timer is re-armed from a map of pending moments rather than by re-walking
/// the store.
@MainActor
final class SessionCurfewCenter {

    // MARK: - Singleton

    static let shared = SessionCurfewCenter()

    // MARK: - Injected Types

    typealias Clock = @MainActor () -> Date
    typealias Activity = @MainActor (SessionID) -> SessionActivity
    typealias SessionPredicate = @MainActor (SessionID) -> Bool

    // MARK: - Performers

    /// The four things this class can do to a session, handed in rather than reached for.
    ///
    /// Values, not a protocol, for `ScheduledMessageScheduler`'s reason: the rules have to be
    /// exercisable with no live agent, no window and no PTY, and a test that could not stub the
    /// Escape would be a test that typed one.
    struct Performers {

        /// Ends the turn in a natively rendered conversation. Announced, never performed here.
        var interruptNative: @MainActor (SessionID) -> Void

        /// Presses Escape in a terminal, answering whether the keystroke reached one.
        var interruptTerminal: @MainActor (SessionID) -> Bool

        /// Ends the agent, keeping the terminal so its final output stays readable.
        var stopAgent: @MainActor (SessionID) -> Void

        /// Tells the user the ladder ran out, and whether the agent was stopped as well.
        var postGaveUpAlert: @MainActor (SessionID, Int, Bool) -> Void

        /// Takes that notification back when the curfew is lifted.
        var withdrawGaveUpAlert: @MainActor (SessionID) -> Void

        /// What the running app uses.
        ///
        /// `terminate(sessionID:)` and never `discard(sessionID:)`: the point of this whole
        /// feature is that the conversation is still there to read in the morning, and discarding
        /// releases the terminal along with everything the agent last printed.
        static func live(posting center: NotificationCenter) -> Performers {
            Performers(
                interruptNative: { sessionID in
                    center.post(CurfewInterruptRequested(sessionID: sessionID))
                },
                interruptTerminal: { sessionID in
                    guard let surface = AgentRuntime.shared
                        .runningTerminalInputSurface(for: sessionID) else { return false }
                    surface.insertTerminalText(TerminalDefaults.interruptSequence)
                    return true
                },
                stopAgent: { sessionID in
                    AgentRuntime.shared.terminate(sessionID: sessionID)
                },
                postGaveUpAlert: { sessionID, interrupts, stopped in
                    AttentionAlertCenter.shared.postCurfewGaveUp(
                        sessionID: sessionID,
                        interrupts: interrupts,
                        stopped: stopped
                    )
                },
                withdrawGaveUpAlert: { sessionID in
                    AttentionAlertCenter.shared.withdrawCurfewAlert(sessionID: sessionID)
                }
            )
        }
    }

    // MARK: - Properties

    private let projectStore: ProjectStore
    private let scheduledMessages: ScheduledMessageStore
    private let settings: CurfewSettings
    private let now: Clock
    private let calendar: Calendar
    private let activity: Activity
    private let reportsOwnTurns: SessionPredicate
    private let supportsEscape: @MainActor (AgentKind) -> Bool
    private let isWatched: SessionPredicate
    private let performers: Performers
    private let notificationCenter: NotificationCenter
    private let workspaceCenter: NotificationCenter
    private let eventLog: EventLog

    /// Whether this instance acts on the running app's own sessions.
    ///
    /// True only for `shared`. It is what `start()` reads before refusing under a hosted test
    /// bundle: see the comment there.
    private let typesIntoLiveSessions: Bool

    private var observations: AppEventObservations?
    private var workspaceObservations: AppEventObservations?
    private var timer: Timer?

    private(set) var isStarted = false

    /// The next moment each session has something to do, so the timer can be re-armed from a
    /// map rather than by walking every project again on every activity edge.
    private var pendingMoments: [SessionID: Date] = [:]

    /// Whether the turn now in flight began in front of the user.
    ///
    /// In memory only, and deliberately: it is a fact about *this* turn in *this* run of the app.
    /// A relaunch has no idea whether anybody was watching an hour ago, and guessing would be the
    /// difference between an escalation that respects the user's presence and one that types into
    /// a session they are looking at.
    private var turnStartedWatched: [SessionID: Bool] = [:]

    /// Guards the one re-entrancy that exists here: persisting a receipt posts `ProjectsDidChange`,
    /// which this class observes. The outer pass already covers every session at the same moment,
    /// so a re-entrant request is dropped rather than queued.
    private var isEvaluating = false

    // MARK: - Initialization

    init(
        projectStore: ProjectStore = .shared,
        scheduledMessages: ScheduledMessageStore = .shared,
        settings: CurfewSettings = .shared,
        now: @escaping Clock = { Date() },
        calendar: Calendar = .current,
        activity: @escaping Activity = { AgentRuntime.shared.activity(sessionID: $0) },
        reportsOwnTurns: @escaping SessionPredicate = {
            AgentRuntime.shared.reportsOwnTurns(sessionID: $0)
        },
        supportsEscape: @escaping @MainActor (AgentKind) -> Bool = {
            $0.supports(.escapeInterruptsTerminalTurn)
        },
        // `ScheduledMessageNotifier`'s rule, asked the same way: somebody is watching when the app
        // has the front *and* this is the session on screen. Core imports AppKit for exactly this
        // one question, as that class already does.
        isWatched: @escaping SessionPredicate = { sessionID in
            NSApp.isActive && AgentRuntime.shared.visibleSessionID == sessionID
        },
        notificationCenter: NotificationCenter = .default,
        workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        eventLog: EventLog = .shared,
        performers: Performers? = nil,
        typesIntoLiveSessions: Bool = true
    ) {
        self.projectStore = projectStore
        self.scheduledMessages = scheduledMessages
        self.settings = settings
        self.now = now
        self.calendar = calendar
        self.activity = activity
        self.reportsOwnTurns = reportsOwnTurns
        self.supportsEscape = supportsEscape
        self.isWatched = isWatched
        self.notificationCenter = notificationCenter
        self.workspaceCenter = workspaceCenter
        self.eventLog = eventLog
        // Built here rather than in a default argument because it needs the centre this instance
        // was handed, and a default argument cannot read another parameter.
        self.performers = performers ?? Performers.live(posting: notificationCenter)
        self.typesIntoLiveSessions = typesIntoLiveSessions
    }

    // MARK: - Public Methods — Lifecycle

    /// Begins watching, and settles what the app missed while it was not running.
    ///
    /// **Refused under a hosted test bundle when this instance is the live one.** The
    /// `LimitRecoveryCoordinator` and `UsageWindowPoker` lock, one degree stricter, because this
    /// is the class that presses Escape: the test bundle is hosted in the app, so a suite that
    /// started the real centre would arm a nightly hold — and, past the grace, a keystroke — on
    /// the copy of Threading the developer is working in. A centre built with injected
    /// dependencies is a fixture and starts normally; that is what `typesIntoLiveSessions`
    /// distinguishes.
    func start() {
        guard !isStarted else { return }
        guard !typesIntoLiveSessions || NSClassFromString("XCTestCase") == nil else { return }
        isStarted = true

        let observations = AppEventObservations(center: notificationCenter)
        // A clock step moves every instant relative to now; a zone change moves what the user's
        // own words meant, and a standing window is written in their words.
        observations.observe(NSNotification.Name.NSSystemClockDidChange) { [weak self] in
            self?.refreshAfterClockChange()
        }
        observations.observe(NSNotification.Name.NSSystemTimeZoneDidChange) { [weak self] in
            self?.refreshAfterClockChange()
        }
        observations.observe(NSApplication.didBecomeActiveNotification) { [weak self] in
            self?.evaluateAll()
        }
        // The provider-neutral edge: a turn started, or one ended. O(1) — only the session that
        // moved is re-evaluated.
        observations.observe(SessionActivityDidChange.self) { [weak self] event in
            self?.activityChanged(event.sessionID)
        }
        observations.observe(CurfewSettingsDidChange.self) { [weak self] _ in
            self?.evaluateAll()
        }
        // A rule written on a session or its checkout changes what resolves for it, and the store
        // is the only place that says so.
        observations.observe(ProjectsDidChange.self) { [weak self] _ in
            self?.evaluateAll()
        }
        self.observations = observations

        let workspaceObservations = AppEventObservations(center: workspaceCenter)
        workspaceObservations.observe(NSWorkspace.didWakeNotification) { [weak self] in
            self?.refreshAfterClockChange()
        }
        self.workspaceObservations = workspaceObservations

        rebuildAndMaterialize()
    }

    /// Settles every session against the clock as it is now.
    ///
    /// **Nothing is typed here.** Every session is dormant at launch, so `activity` answers
    /// `.dormant` and the interrupt step cannot fire; a hold that began while the app was shut
    /// materializes dated its own deadline rather than this launch, and a wrap-up whose window
    /// passed fails saying Threading was not running.
    func rebuildAndMaterialize() {
        guard !isEvaluating else { return }
        isEvaluating = true
        defer { isEvaluating = false }

        let moment = now()
        pendingMoments.removeAll(keepingCapacity: true)
        walkSessions { [weak self] sessionID in
            self?.evaluate(sessionID, at: moment, materializing: true)
        }
        rearmTimer()
    }

    /// Public for deterministic tests and for the system notifications above. Correctness comes
    /// from the stored dates; it does not matter whether the previous timer fired.
    func refreshAfterClockChange() {
        evaluateAll()
    }

    func evaluateAll() {
        guard !isEvaluating else { return }
        isEvaluating = true
        defer { isEvaluating = false }

        let moment = now()
        walkSessions { [weak self] sessionID in
            self?.evaluate(sessionID, at: moment, materializing: false)
        }
        rearmTimer()
    }

    // MARK: - Public Methods — Reading

    /// What this session's curfew has already done, or nil where it has done nothing.
    func state(for sessionID: SessionID) -> SessionCurfewState? {
        projectStore.session(withID: sessionID)?.curfewState
    }

    /// Whether Threading can tell that this session is working — the honest half of the strip's
    /// sentence, and the exact condition under which the escalation has anything to press.
    ///
    /// A runtime that reports no turns, or a CLI that does not read Escape as *stop*, still gets
    /// the hold: the outbox stops draining and scheduled sends stand aside. What it does not get
    /// is a keystroke, and the copy says so rather than implying a fence that is not there.
    func canTellWorking(sessionID: SessionID) -> Bool {
        guard let session = projectStore.session(withID: sessionID) else { return false }
        return session.usesNativeUI
            || (supportsEscape(session.kind) && reportsOwnTurns(sessionID))
    }

    // MARK: - Public Methods — Writing

    /// Records the user's own answer for one conversation, and settles it immediately.
    ///
    /// The store's own outcome is handed back rather than swallowed, because a menu that asked
    /// for this has to say when the answer did not stick: a refused write leaves the row showing
    /// a rule nobody stored, and the surfaces that offer the choice already own that sentence
    /// (`ProjectSidebarViewController.chooseLimitRecovery`). Discardable for the callers that
    /// arm a curfew as part of a larger act and have no row to put a notice on.
    @discardableResult
    func setCurfew(
        _ rule: CurfewRule?,
        forSessionID sessionID: SessionID
    ) -> ProjectMutationResult {
        let outcome = suspendingEvaluation {
            projectStore.setCurfewRule(rule, forSessionID: sessionID)
        }
        eventLog.record(.curfew, "Curfew set", [
            "session": sessionID.uuidString,
            "rule": Self.describe(rule),
            "outcome": String(describing: outcome)
        ])
        guard outcome == .applied else { return outcome }

        evaluateSession(sessionID)
        notificationCenter.post(CurfewDidChange(sessionID: sessionID))
        return outcome
    }

    /// Ends the curfew this session is under, by the only route that ever ends one early.
    ///
    /// Two shapes, because "not tonight" and "never" are different sentences. A curfew the user
    /// set on this conversation is a rule on the record, so lifting it *removes the rule*. A
    /// standing quiet-hours window belongs to every session and cannot be written nil, so the lift
    /// is scoped to the instance: `liftedAt` on the state whose deadline is tonight's window start,
    /// which `CurfewResolution` reads and tomorrow's window — a different start — never sees.
    func lift(sessionID: SessionID) {
        let moment = now()
        guard let session = projectStore.session(withID: sessionID),
              let curfew = resolve(sessionID, at: moment)?.curfew else { return }

        var state = instanceState(session.curfewState, for: curfew)
        state.liftedAt = moment
        state.record(.lifted, at: moment)

        suspendingEvaluation {
            switch curfew.origin {
            case .session:
                projectStore.setCurfewRule(nil, forSessionID: sessionID)
            case .quietHours:
                break
            }
            projectStore.updateCurfewState(state, forSessionID: sessionID)
        }

        removeUndeliveredWindDown(state.windDownMessageID)
        performers.withdrawGaveUpAlert(sessionID)
        eventLog.record(.curfew, "Curfew lifted", [
            "session": sessionID.uuidString,
            "deadline": Self.stamp(curfew.deadline)
        ])

        evaluateSession(sessionID)
        notificationCenter.post(CurfewDidChange(sessionID: sessionID))
    }

    // MARK: - Public Methods — Reports From The Performers

    /// What became of an interrupt this class asked for.
    ///
    /// Journalled and nothing more. **A failure is still a spent attempt**: the budget bounds how
    /// many times Threading may press a key in somebody's session, not how many times it succeeds,
    /// and a refusal that reset the count would be a loop the app kept typing at forever.
    func noteInterruptOutcome(sessionID: SessionID, receipt: InterruptReceipt) {
        eventLog.record(.curfew, "Curfew interrupt reported back", [
            "session": sessionID.uuidString,
            "receipt": Self.describe(receipt)
        ])
    }

    /// The wrap-up reached the session.
    func noteWindDownDelivered(sessionID: SessionID) {
        recordWindDownOutcome(.windDownSent, for: sessionID, detail: nil)
    }

    /// The wrap-up could not be delivered, in the scheduled store's own words.
    func noteWindDownFailed(sessionID: SessionID, reason: String) {
        recordWindDownOutcome(.windDownFailed, for: sessionID, detail: reason)
    }

    // MARK: - Private Methods — Walking

    /// Runs `body` with this class's own store writes unable to call it back.
    ///
    /// `ProjectStore.updateCurfewState` posts `ProjectsDidChange`, which is observed here, so a
    /// public writer that did not suspend would have its own half-finished record re-read
    /// mid-write. The pass that follows sees the finished one.
    private func suspendingEvaluation<Value>(_ body: () -> Value) -> Value {
        let previous = isEvaluating
        isEvaluating = true
        defer { isEvaluating = previous }
        return body()
    }

    private func walkSessions(_ body: (SessionID) -> Void) {
        for project in projectStore.projects {
            for session in project.sessions where !session.isArchived {
                body(session.id)
            }
        }
    }

    private func evaluateSession(_ sessionID: SessionID) {
        guard !isEvaluating else { return }
        isEvaluating = true
        defer { isEvaluating = false }

        evaluate(sessionID, at: now(), materializing: false)
        rearmTimer()
    }

    private func activityChanged(_ sessionID: SessionID) {
        if activity(sessionID).hasTurnInFlight {
            // The edge, not the state: only the *first* report of a turn in flight decides
            // whether it began in front of the user.
            if turnStartedWatched[sessionID] == nil {
                turnStartedWatched[sessionID] = isWatched(sessionID)
            }
        } else {
            turnStartedWatched[sessionID] = nil
        }
        evaluateSession(sessionID)
    }

    // MARK: - Private Methods — Resolution

    private func resolve(_ sessionID: SessionID, at moment: Date) -> CurfewResolution.Answer? {
        guard let session = projectStore.session(withID: sessionID) else { return nil }
        // The pure chain rather than its store-reading convenience, because that one reads
        // `CurfewSettings.shared` and this class was handed a settings store of its own — the
        // whole reason a fixture can arm a standing window without touching the app's.
        return CurfewResolution.resolve(
            session: session.curfewRule,
            project: projectStore.project(forSessionID: sessionID)?.curfewRule,
            preferences: settings.preferences,
            state: session.curfewState,
            now: moment,
            calendar: calendar
        )
    }

    /// The state describing `curfew`, which is the stored one only when it names the same
    /// deadline. A new deadline is a new curfew: the wrap-up is owed again, the hold is announced
    /// again, the budget starts at zero.
    private func instanceState(
        _ stored: SessionCurfewState?,
        for curfew: ResolvedCurfew
    ) -> SessionCurfewState {
        guard var stored, stored.deadline == curfew.deadline else {
            return SessionCurfewState(deadline: curfew.deadline, origin: curfew.origin)
        }
        stored.origin = curfew.origin
        return stored
    }

    // MARK: - Private Methods — One Session, One Moment

    private func evaluate(_ sessionID: SessionID, at moment: Date, materializing: Bool) {
        guard let session = projectStore.session(withID: sessionID) else {
            pendingMoments[sessionID] = nil
            return
        }
        guard let curfew = resolve(sessionID, at: moment)?.curfew else {
            closeStaleInstance(session.curfewState, for: sessionID, at: moment)
            // A lifted standing instance resolves to *nothing* until its own window closes, and
            // then tomorrow's resolves again. Without an alarm for that end, a machine left alone
            // after a lift would pick tomorrow's window up only on some unrelated event.
            if case .quietHours(let endsAt)? = projectStore.session(withID: sessionID)?
                .curfewState?.origin, endsAt > moment {
                pendingMoments[sessionID] = endsAt
            } else {
                pendingMoments[sessionID] = nil
            }
            return
        }
        if session.curfewState?.deadline != curfew.deadline {
            closeStaleInstance(session.curfewState, for: sessionID, at: moment)
        }

        var state = instanceState(projectStore.session(withID: sessionID)?.curfewState, for: curfew)
        var changed = false

        changed = windDown(session, curfew: curfew, state: &state, at: moment) || changed
        changed = hold(curfew: curfew, state: &state, at: moment, materializing: materializing)
            || changed
        changed = escalate(session, curfew: curfew, state: &state, at: moment) || changed

        if changed {
            projectStore.updateCurfewState(state, forSessionID: sessionID)
            notificationCenter.post(CurfewDidChange(sessionID: sessionID))
        }
        pendingMoments[sessionID] = nextMoment(curfew: curfew, state: state, after: moment)
    }

    /// Closes the books on an instance the resolution has moved past.
    ///
    /// Only a standing window ends by itself, so only a standing window earns an `.ended` receipt,
    /// and it is dated the moment it actually ended rather than whenever this ran. Without this
    /// the receipt would have nowhere to live: by the time the window has closed, resolution is
    /// already answering with tomorrow's, and the state describing last night is one write from
    /// being replaced.
    private func closeStaleInstance(
        _ stored: SessionCurfewState?,
        for sessionID: SessionID,
        at moment: Date
    ) {
        guard var stored,
              case .quietHours(let endsAt) = stored.origin,
              moment >= endsAt,
              !stored.has(.ended) else { return }

        stored.record(.ended, at: endsAt)
        projectStore.updateCurfewState(stored, forSessionID: sessionID)
        eventLog.record(.curfew, "Quiet hours ended", [
            "session": sessionID.uuidString,
            "endsAt": Self.stamp(endsAt)
        ])
        notificationCenter.post(CurfewDidChange(sessionID: sessionID))
    }

    // MARK: - Private Methods — The Wrap-Up

    /// Files the wrap-up, skips it, or fails it — once per instance, whichever happens.
    private func windDown(
        _ session: AgentSession,
        curfew: ResolvedCurfew,
        state: inout SessionCurfewState,
        at moment: Date
    ) -> Bool {
        // Switched off in Settings. There is no wrap-up to send, so there is none to fail either
        // — and `windDownDeliverableUntil` collapses onto the deadline when the margin is nil,
        // which without this guard would file a failure receipt for a message nobody asked for.
        guard let windDownAt = curfew.windDownAt else { return false }

        let settled = state.has(.windDownSent)
            || state.has(.windDownSkippedIdle)
            || state.has(.windDownFailed)
        guard !settled else { return false }

        if state.windDownMessageID == nil,
           moment >= windDownAt,
           moment < curfew.windDownDeliverableUntil {
            // An idle session has nothing to wrap up, and typing into it would wake it and spend
            // usage the curfew exists to stop spending.
            guard activity(session.id).hasTurnInFlight else {
                state.record(.windDownSkippedIdle, at: moment)
                eventLog.record(.curfew, "Curfew wrap-up skipped: nothing in flight", [
                    "session": session.id.uuidString
                ])
                return true
            }
            return fileWindDown(session, curfew: curfew, state: &state, at: moment)
        }

        guard moment >= curfew.windDownDeliverableUntil else { return false }

        // Past the window and still owed. Two ways to get here, and they are different news: a
        // record was filed and its session never came free, or nothing was ever filed because
        // Threading was not running at the moment the wrap-up was due.
        if let id = state.windDownMessageID, scheduledMessages[id] != nil {
            let reason = CurfewReceiptWords.windDownFailureReason
            scheduledMessages.fail(id, reason: reason)
            state.record(.windDownFailed, at: moment, detail: reason)
        } else {
            state.record(.windDownFailed, at: moment, detail: CurfewReceiptWords.notRunningFailureReason)
        }
        eventLog.record(.curfew, "Curfew wrap-up missed its window", [
            "session": session.id.uuidString
        ])
        return true
    }

    private func fileWindDown(
        _ session: AgentSession,
        curfew: ResolvedCurfew,
        state: inout SessionCurfewState,
        at moment: Date
    ) -> Bool {
        let message = ScheduledMessage(
            // A hair ahead of now, because the store refuses a moment already past and a record
            // filed for *this* instant is exactly that. The scheduler offers it on its next pass,
            // which is not a delay anybody experiences.
            dueAt: moment.addingTimeInterval(CurfewCenterDefaults.windDownLead),
            calendar: calendar,
            target: .session(session.id),
            text: CurfewReceiptWords.windDownText(
                template: curfew.windDownText,
                deadline: curfew.deadline
            ),
            purpose: .curfewWindDown
        )

        switch scheduledMessages.add(message, now: moment) {
        case .success(let filed):
            state.windDownMessageID = filed.id
            eventLog.record(.curfew, "Curfew wrap-up filed", [
                "session": session.id.uuidString,
                "deadline": Self.stamp(curfew.deadline)
            ])
        case .failure(let refusal):
            let reason = String(describing: refusal)
            state.record(.windDownFailed, at: moment, detail: reason)
            eventLog.record(.curfew, "Curfew wrap-up refused by the store", [
                "session": session.id.uuidString,
                "reason": reason
            ])
        }
        return true
    }

    private func recordWindDownOutcome(
        _ event: CurfewReceipt.Event,
        for sessionID: SessionID,
        detail: String?
    ) {
        guard var state = projectStore.session(withID: sessionID)?.curfewState else { return }
        guard !state.has(event) else { return }

        state.windDownMessageID = nil
        state.record(event, at: now(), detail: detail)
        projectStore.updateCurfewState(state, forSessionID: sessionID)
        eventLog.record(.curfew, "Curfew wrap-up settled", [
            "session": sessionID.uuidString,
            "event": event.rawValue,
            "detail": detail ?? ""
        ])
        notificationCenter.post(CurfewDidChange(sessionID: sessionID))
    }

    private func removeUndeliveredWindDown(_ id: ScheduledMessageID?) {
        guard let id, scheduledMessages[id] != nil else { return }
        scheduledMessages.remove(id)
    }

    // MARK: - Private Methods — The Hold

    private func hold(
        curfew: ResolvedCurfew,
        state: inout SessionCurfewState,
        at moment: Date,
        materializing: Bool
    ) -> Bool {
        guard moment >= curfew.deadline, !state.has(.held) else { return false }
        if let endsAt = curfew.endsAt, moment >= endsAt { return false }

        // Dated the deadline when the app has just found it already past: a hold that began at
        // 04:00 and was noticed at 09:00 is still a hold that began at 04:00, and a receipt saying
        // otherwise would describe the app's uptime rather than the user's curfew.
        state.record(.held, at: materializing ? curfew.deadline : moment)
        eventLog.record(.curfew, "Curfew hold began", [
            "deadline": Self.stamp(curfew.deadline)
        ])
        return true
    }

    // MARK: - Private Methods — The Escalation Ladder
    //
    // Deliberately written in terms of a session and a state rather than in terms of a curfew.
    // The same ladder — a bounded number of interrupts, spaced, skipped for a turn the user
    // started while watching, then an opt-in stop and one actionable alert — is what a custom
    // limit's `enforce` tier would need, and the only thing that would differ is which clock said
    // *stop*. That tier is not built here; what is avoided here is baking this reason into the
    // ladder's own names so that building it later means moving code rather than copying it.

    private func escalate(
        _ session: AgentSession,
        curfew: ResolvedCurfew,
        state: inout SessionCurfewState,
        at moment: Date
    ) -> Bool {
        guard let interruptAt = curfew.interruptAt,
              moment >= interruptAt,
              state.gaveUpAt == nil,
              activity(session.id).hasTurnInFlight else { return false }

        // Also what keeps a second Escape away from an idle prompt, where Claude reads it as
        // "open the rewind chooser".
        if let last = state.lastInterruptAt,
           last.addingTimeInterval(CurfewDefaults.reinterruptSpacing) > moment { return false }

        // The first press after the grace lands whatever the user is doing — the curfew is theirs,
        // and it has just run out. Every later one is only for a turn that *started* while nobody
        // was watching: a turn somebody began in front of the app is theirs.
        let isFirst = state.interruptCount == 0
        guard isFirst || turnStartedWatched[session.id] != true else { return false }

        guard state.interruptCount < CurfewDefaults.maximumInterrupts else {
            return giveUp(session, state: &state, at: moment)
        }
        return interrupt(session, state: &state, at: moment)
    }

    private func interrupt(
        _ session: AgentSession,
        state: inout SessionCurfewState,
        at moment: Date
    ) -> Bool {
        let performed: Bool
        if session.usesNativeUI {
            performers.interruptNative(session.id)
            performed = true
        } else if supportsEscape(session.kind), reportsOwnTurns(session.id) {
            // Gated twice on purpose: the capability says this CLI reads Escape as *stop*, and the
            // turn report says there is a turn rather than a chooser on screen.
            performed = performers.interruptTerminal(session.id)
        } else {
            // Nothing to press. The hold stands, and the strip says Threading cannot tell whether
            // this session is working.
            performed = false
        }
        guard performed else { return false }

        state.interruptCount += 1
        state.record(
            .interrupted,
            at: moment,
            detail: "\(state.interruptCount)/\(CurfewDefaults.maximumInterrupts)"
        )
        eventLog.record(.curfew, "Curfew interrupted a turn", [
            "session": session.id.uuidString,
            "attempt": "\(state.interruptCount)/\(CurfewDefaults.maximumInterrupts)"
        ])
        return true
    }

    private func giveUp(
        _ session: AgentSession,
        state: inout SessionCurfewState,
        at moment: Date
    ) -> Bool {
        state.gaveUpAt = moment
        state.record(.gaveUp, at: moment, detail: "\(state.interruptCount)")

        let stops = settings.preferences.stopsAgentOnGiveUp
        if stops {
            performers.stopAgent(session.id)
            state.record(.stoppedAgent, at: moment)
        }
        performers.postGaveUpAlert(session.id, state.interruptCount, stops)
        eventLog.record(.curfew, "Curfew gave up", [
            "session": session.id.uuidString,
            "interrupts": "\(state.interruptCount)",
            "stoppedAgent": stops ? "yes" : "no"
        ])
        return true
    }

    // MARK: - Private Methods — The Timer

    /// The nearest moment this session has anything left to do.
    private func nextMoment(
        curfew: ResolvedCurfew,
        state: SessionCurfewState,
        after moment: Date
    ) -> Date? {
        var candidates: [Date] = [curfew.deadline]
        let windDownSettled = state.has(.windDownSent)
            || state.has(.windDownSkippedIdle)
            || state.has(.windDownFailed)
        if !windDownSettled, let windDownAt = curfew.windDownAt {
            candidates.append(windDownAt)
            candidates.append(curfew.windDownDeliverableUntil)
        }
        if state.gaveUpAt == nil {
            if let interruptAt = curfew.interruptAt { candidates.append(interruptAt) }
            if let last = state.lastInterruptAt {
                candidates.append(last.addingTimeInterval(CurfewDefaults.reinterruptSpacing))
            }
        }
        if let endsAt = curfew.endsAt { candidates.append(endsAt) }

        return candidates.filter { $0 > moment }.min()
    }

    private func rearmTimer() {
        timer?.invalidate()
        timer = nil
        guard isStarted, let next = pendingMoments.values.min() else { return }

        let interval = max(
            CurfewCenterDefaults.minimumTimerInterval,
            next.timeIntervalSince(now())
        )
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.evaluateAll() }
        }
    }

    // MARK: - Private Methods — Words For The Journal

    private static func stamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func describe(_ rule: CurfewRule?) -> String {
        guard let rule else { return "inherit" }
        switch rule {
        case .exempt: return "exempt"
        case .until(let deadline): return "until \(stamp(deadline))"
        }
    }

    private static func describe(_ receipt: InterruptReceipt) -> String {
        switch receipt {
        case .reported(let stillQueued): return "reported(\(stillQueued.count) still queued)"
        case .acknowledged: return "acknowledged"
        case .failed(let reason): return "failed: \(reason)"
        }
    }
}

// MARK: - Defaults

enum CurfewCenterDefaults {

    /// How far ahead of the moment it is filed a wrap-up is due.
    ///
    /// `ScheduledMessageStore.add` refuses a record whose moment has already passed, and one filed
    /// for *now* is that record by the time the guard reads the clock. A second is short enough
    /// that the scheduler's very next pass takes it and long enough that no rounding puts it in
    /// the past.
    static let windDownLead: TimeInterval = 1

    /// The floor under a re-arm, so a moment that has just passed cannot spin the run loop.
    static let minimumTimerInterval: TimeInterval = 0.05
}

import Foundation

// MARK: - Limit Escape Ranking

/// Which of a session's other logins its conversation could carry on under, ranked.
///
/// The interactive half of `limit-recovery.md`'s `resumeOnBestAccount`: the policy that migrates
/// automatically stays unbuilt, but the *choice* it would have made is exactly what a one-tap
/// offer needs, so the arithmetic is written once, here, and pressed by hand.
///
/// **Pure, and taking values rather than looking anything up** — `preferred(among:)`'s reason in
/// [`accounts.md`](accounts.md): a rule that decides where somebody's conversation goes has to be
/// testable without a home directory to scan or a network to answer. The live inputs are gathered
/// by `LimitEscapeSuggestion.compute`, which is the only part that needs a running app.
enum LimitEscapeRanking {

    // MARK: - Types

    /// One login offered to the ranking, beside whatever reading is known for it.
    ///
    /// The reading is optional because "we have never fetched this account" is a real answer and
    /// a common one, and it is not the same as "this account is spent".
    struct Candidate: Equatable {
        let accountID: AccountID
        let usage: AccountUsage?

        /// The user's own limits on this login, passed in rather than fetched, so the ranking
        /// stays the pure function its tests read it as.
        let limits: [CustomLimit]

        init(accountID: AccountID, usage: AccountUsage?, limits: [CustomLimit] = []) {
            self.accountID = accountID
            self.usage = usage
            self.limits = limits
        }
    }

    /// A login that survived eligibility, with the numbers that placed it.
    struct Ranked: Equatable {
        let accountID: AccountID

        /// The account's **worst** metering window — the one that would stop the work first, and
        /// therefore the one this account is judged on. Named for the journal, so a bug report
        /// weeks later says which window the choice turned on rather than only which login won.
        let decidingWindowName: String

        /// `bound × elapsedFraction − usedFraction` on that window: how far behind its own
        /// linear burn toward **the line that applies** the account is. Positive is room to
        /// spare, negative is burning faster than the clock.
        ///
        /// The bound generalizes the shipped formula rather than replacing it — with no line of
        /// the user's it is 1 and this is `elapsedFraction − usedFraction` exactly. What it buys
        /// is the "yours vs. theirs" answer: a shared login far under the share reserved for its
        /// owner ranks ahead of a free login near its own cap, which is the comparison somebody
        /// choosing a destination is actually making.
        let paceDeficit: Double
    }

    /// A login that was *refused* by one of the user's own limits, and the hold that refused it.
    ///
    /// Separate from simply not appearing, because the receipt has to be able to say **"excluded
    /// by your limit"** rather than "spent". Silent exclusion reads as spent, which slanders an
    /// account with headroom — and worse, points the user at the provider for a line they drew.
    struct Excluded: Equatable {
        let accountID: AccountID
        let hold: CustomLimitHold
    }

    // MARK: - Public Methods

    /// Every login with headroom for this model, furthest behind its burn first.
    ///
    /// **Ranked by pace deficit rather than by how empty the window is**, which is the same rule
    /// `weeklyAheadOfPace` already applies to the usage-window poke and reads the same numbers:
    /// an account at 40% two hours into a five-hour window is under more pressure than one at 55%
    /// four hours in, and moving a refused conversation onto the first would spend a window that
    /// is already running hot.
    ///
    /// Ties keep the order the candidates arrived in, so a discovery order that does not change
    /// cannot make this answer differ between two identical readings.
    static func rank(
        _ candidates: [Candidate],
        metering model: String?,
        at now: Date = Date()
    ) -> [Ranked] {
        candidates
            .enumerated()
            .compactMap { index, candidate -> (offer: Int, ranked: Ranked)? in
                guard let ranked = eligible(candidate, metering: model, at: now) else { return nil }
                return (index, ranked)
            }
            .sorted { left, right in
                guard left.ranked.paceDeficit == right.ranked.paceDeficit else {
                    return left.ranked.paceDeficit > right.ranked.paceDeficit
                }
                return left.offer < right.offer
            }
            .map(\.ranked)
    }

    /// The login a one-tap offer would name, or nil when none of them can be recommended.
    static func best(
        among candidates: [Candidate],
        metering model: String?,
        at now: Date = Date()
    ) -> Ranked? {
        rank(candidates, metering: model, at: now).first
    }

    /// Whether a login already chosen still has room — the guard a tap runs again against a
    /// freshly forced reading, so a cached number cannot move a conversation onto a spent login.
    static func hasHeadroom(
        _ candidate: Candidate,
        metering model: String?,
        at now: Date = Date()
    ) -> Bool {
        eligible(candidate, metering: model, at: now) != nil
    }

    /// The logins this ranking refused because of a rule of the user's, so a strip or a receipt
    /// can name them rather than leaving them looking spent.
    static func exclusions(
        _ candidates: [Candidate],
        at now: Date = Date()
    ) -> [Excluded] {
        candidates.compactMap { candidate in
            let hold = CustomLimitBounds.hold(
                on: candidate.usage,
                in: candidate.limits,
                at: now
            )
            guard hold.isHolding else { return nil }
            return Excluded(accountID: candidate.accountID, hold: hold)
        }
    }

    // MARK: - Private Methods

    /// One login's eligibility, decided on **every** window that meters the session's model —
    /// the account's own windows and the model-scoped ones alike, which is `bindingWindow`'s
    /// list rather than `peakWindow`'s. A weekly window at 20% beside a spent `7d Fable` is a
    /// comfortable account and a useless destination for a session running Fable.
    ///
    /// Three shapes are refused rather than guessed at, because each of them would put somebody's
    /// conversation on a login that cannot run it:
    ///
    /// - **No reading at all.** The account may well be empty; nothing here knows.
    /// - **A window whose `resetsAt` has passed.** Its percentage describes the *previous*
    ///   window ([`accounts.md`](accounts.md)) — the number is very likely to be generous, which
    ///   is exactly why it must not be believed.
    /// - **No window at all**, which is what a provider that reports no limits looks like, and
    ///   is indistinguishable here from a reading that failed to parse.
    private static func eligible(
        _ candidate: Candidate,
        metering model: String?,
        at now: Date
    ) -> Ranked? {
        guard let usage = candidate.usage else { return nil }

        // A fourth refusal, and the only one that is not about what the provider said: an account
        // the user fenced off must never be somewhere a conversation is moved *into*. It is
        // reported through `exclusions` rather than dropped silently, because a login that
        // disappears from an offer reads as spent.
        guard !CustomLimitBounds.hold(
            on: usage,
            in: candidate.limits,
            at: now
        ).isHolding else { return nil }

        let windows = usage.windows(metering: model)
        guard !windows.isEmpty else { return nil }

        var worst: Ranked?
        for window in windows {
            guard !window.isExpired(at: now), let fraction = window.fraction else { return nil }
            let bound = CustomLimitBounds.effectiveBound(
                on: window.id,
                in: candidate.limits,
                window: window,
                at: now
            )
            guard fraction / bound < LimitEscapeDefaults.headroomFraction else { return nil }

            // A window whose length the provider did not state has no pace to be behind, so it
            // contributes nothing rather than a number invented from one side of the subtraction.
            let deficit = bound * (window.elapsedFraction(at: now) ?? (fraction / bound)) - fraction
            if let standing = worst, standing.paceDeficit <= deficit { continue }

            worst = Ranked(
                accountID: candidate.accountID,
                decidingWindowName: window.compactName,
                paceDeficit: deficit
            )
        }
        return worst
    }
}

// MARK: - Limit Escape Suggestion

/// What a standing refusal can be answered with.
///
/// Two genuinely different acts, which is why they are named rather than counted: one moves the
/// conversation to another login and carries on now, the other leaves it exactly where it is and
/// files a message for when the window comes back.
enum LimitEscapeAction: Equatable, Sendable {
    case moveAccount
    case waitForReset
}

/// A standing usage-limit refusal, and what can be done about it: a login to carry on under, a
/// wait for the window to reset, or — where neither is available — the fact by itself.
///
/// **The account half is optional, and that is the record's whole shape.** It began as "one login
/// to escape to", which meant a session with no second login carried no record at all: the strip
/// never appeared, and the only thing left saying the session had stopped was the sidebar's
/// triangle. But waiting for the reset needs no second account, so the refusal — not the escape —
/// is what the record is *about*. Three things follow from putting it this way round:
///
/// - a single-account session gets a strip, carrying the wait offer alone;
/// - the dismissal, the busy flag and the problem sentence keep working for it, because they live
///   on an entry that now always exists;
/// - `LimitEscapeSuggestionStore.update` can **upgrade** a refusal that had no login into one that
///   does, the moment a candidate's reading arrives with headroom.
///
/// A value rather than a live object, for `ScheduledMessageStripView.Row`'s reason — the strip
/// shows what it is handed and reports gestures back, so nothing about a migration in flight is
/// held in a view.
struct LimitEscapeSuggestion: Equatable, Sendable {

    // MARK: - Properties

    let sessionID: SessionID

    /// The login worth moving to, when one has headroom. Nil where none does — every other login
    /// is as spent as this one, or the runtime routes no accounts at all.
    let accountID: AccountID?

    /// The login named the way every other surface names one: after the person, not the alias.
    let accountName: String?

    /// The compact reading, metered by what this session runs — `5h 12% · 7d 40%`. Nil when the
    /// login reports no windows to state, which is a login with nothing to say rather than a
    /// login with nothing left.
    ///
    /// Replaced when a tap force-refreshes the target: the whole point of that read is that the
    /// cached number may be wrong, so the strip must not go on showing the number that was.
    var reading: String?

    /// When the provider said the *refused* account comes back, in the provider's own words.
    /// Never reformatted into the Mac's locale — see `UsageLimitStop`.
    let resetHint: String?

    /// The model the eligibility was decided against, kept so the tap re-checks the same windows.
    let model: String?

    /// The window the choice turned on, for the journal. Nil where no login was chosen.
    let decidingWindowName: String?

    /// Whether there is a login worth moving to.
    var offersAccountEscape: Bool { accountID != nil }

    /// Which answer is being carried out, if either. Both controls dim while one runs — the
    /// second would act on the same refusal — but only the one pressed says it is working.
    ///
    /// Named rather than a Boolean because the two answers do very different things: a strip
    /// that reported "Continuing as Daniel Block…" because somebody pressed *Continue at Reset*
    /// would be claiming a login change nobody asked for, over a conversation that had not moved.
    var busy: LimitEscapeAction?

    /// Whether either answer is in flight.
    var isBusy: Bool { busy != nil }

    /// Why the tap did not go through, when it did not. The strip degrades to this rather than
    /// silently naming a different login: another account is a *new* suggestion the user can tap,
    /// not something to escalate to on their behalf.
    var problem: String?

    /// Whether the user has waved this refusal's offer away. Not persisted: a refusal is a fact
    /// about a live process, and so is having decided to ignore it.
    var isDismissed = false

    // MARK: - Initialization

    init(
        sessionID: SessionID,
        accountID: AccountID? = nil,
        accountName: String? = nil,
        reading: String? = nil,
        resetHint: String?,
        model: String?,
        decidingWindowName: String? = nil
    ) {
        self.sessionID = sessionID
        self.accountID = accountID
        self.accountName = accountName
        self.reading = reading
        self.resetHint = resetHint
        self.model = model
        self.decidingWindowName = decidingWindowName
    }
}

// MARK: - Building One From The Live App

extension LimitEscapeSuggestion {

    /// Asks the ranking about a refused session's own destinations.
    ///
    /// The candidates are `SessionMigration.destinations(for:)` — the enabled logins of the same
    /// runtime, minus the one that just refused. That list is already capability-gated, which is
    /// why nothing here names a provider: a runtime that routes no accounts offers none, and the
    /// account half is simply absent.
    ///
    /// **No eligible login is not "no record".** It used to be, and that is what left a
    /// single-account session with nothing on screen but the sidebar's triangle. The refusal is
    /// the fact; the login is one of the two answers to it. Only a session that has gone missing
    /// answers nil here.
    @MainActor
    static func compute(for sessionID: SessionID, stop: UsageLimitStop) -> LimitEscapeSuggestion? {
        guard let session = ProjectStore.shared.session(withID: sessionID) else { return nil }

        let model = effectiveModel(for: session)
        let refusalAlone = LimitEscapeSuggestion(
            sessionID: sessionID,
            resetHint: stop.resetHint,
            model: model
        )

        let destinations = SessionMigration.destinations(for: session)
        guard !destinations.isEmpty else { return refusalAlone }

        let candidates = destinations.map {
            LimitEscapeRanking.Candidate(
                accountID: $0.id,
                usage: AccountUsageService.shared.usage(for: $0),
                limits: CustomLimitSettings.shared.rules(for: $0.id)
            )
        }

        guard let best = LimitEscapeRanking.best(among: candidates, metering: model),
              let account = destinations.first(where: { $0.id == best.accountID })
        else { return refusalAlone }

        return LimitEscapeSuggestion(
            sessionID: sessionID,
            accountID: account.id,
            accountName: AccountName.display(for: account),
            reading: AccountUsageService.shared.usage(for: account)?
                .compactSummary(metering: model),
            resetHint: stop.resetHint,
            model: model,
            decidingWindowName: best.decidingWindowName
        )
    }

    /// Starts a paced refresh for every login the offer could name.
    ///
    /// Called at detection rather than when the strip is drawn: a refusal is read seconds after
    /// it happened and looked at minutes later, so this is the one moment where a fetch has time
    /// to land before it is needed. Every pacing rule in `AccountUsageService` still applies —
    /// the per-account floor and the endpoint's own `notBefore` — so a refusal cannot become a
    /// way to hammer the usage endpoints.
    @MainActor
    static func warmCandidateReadings(for sessionID: SessionID) {
        guard let session = ProjectStore.shared.session(withID: sessionID) else { return }
        for account in SessionMigration.destinations(for: session) {
            AccountUsageService.shared.refresh(account)
        }
    }

    /// What the next turn would run on: the session's own choice, else what its account is
    /// configured for — the same "effective model" the toolbar pill gauges, since the windows
    /// that stop a session are the windows metering what it runs.
    @MainActor
    static func effectiveModel(for session: AgentSession) -> String? {
        guard let account = AgentAccountDiscovery.account(
            for: session.kind,
            handle: session.accountHandle
        ) else { return session.model }

        return session.model ?? AgentModels.defaultModel(for: session.kind, account: account)
    }
}

// MARK: - Change Announcement

/// A session's escape offer appeared, changed or went away.
struct LimitEscapeSuggestionDidChange: AppEvent {
    static let name = Notification.Name("ThreadingLimitEscapeSuggestionDidChange")
    let sessionID: SessionID
}

/// The user pressed the offer.
///
/// Announced rather than called for `ScheduledMessageDidBecomeDue`'s reason: migrating a
/// conversation and reopening it is `SessionCoordinator`'s work, and a strip inside a session's
/// own pane knows nothing about sidebars, panes or launching.
struct LimitEscapeRequested: AppEvent {
    static let name = Notification.Name("ThreadingLimitEscapeRequested")
    let sessionID: SessionID
}

/// The user pressed the other offer: stay put and continue when the window resets.
///
/// A second event rather than a flag on the first, because they end in different places — the
/// migration is `SessionCoordinator`'s, while answering the CLI's chooser and filing the
/// continuation is `LimitRecoveryCoordinator`'s, the same routine the automatic policy runs.
struct LimitWaitForResetRequested: AppEvent {
    static let name = Notification.Name("ThreadingLimitWaitForResetRequested")
    let sessionID: SessionID
}

// MARK: - Limit Escape Suggestion Store

/// Which sessions are currently offering an escape, and what each offer says.
///
/// **In memory only.** A refusal is a fact about a live process — the transcript says so while it
/// stands, and `LimitRecoveryCoordinator` reads it again on the next launch — so persisting the
/// offer would mean restoring an answer to a question nobody has re-asked. The dismissal rides
/// along for the same reason: waving away today's refusal must not silence tomorrow's.
///
/// One direction, like the strip that draws from it: this is the truth, views read it, and a
/// gesture is reported back as an intention rather than applied in place.
@MainActor
final class LimitEscapeSuggestionStore {

    // MARK: - Properties

    static let shared = LimitEscapeSuggestionStore()

    private var entries: [SessionID: LimitEscapeSuggestion] = [:]

    /// The refusal currently standing over each session.
    ///
    /// Kept so a candidate's reading arriving *after* the refusal can re-rank the offer against
    /// the same stop — `warmCandidateReadings` asks at detection and the answers land seconds
    /// later, by which time the offer has already been drawn from whatever was cached.
    private var standingRefusals: [SessionID: UsageLimitStop] = [:]

    private let center: NotificationCenter
    private let observations: AppEventObservations

    // MARK: - Initialization

    /// Not private: a test builds its own rather than reaching for the singleton, which is what
    /// lets the dismissal and clearing rules be asserted without a coordinator, a timer or a
    /// live agent.
    init(center: NotificationCenter = .default) {
        self.center = center
        observations = AppEventObservations(center: center)

        // A session whose agent exited has nothing to migrate *into* — the offer named a login
        // for a conversation that is no longer running, and the row already says dormant.
        observations.observe(TerminalSessionDidEnd.self) { [weak self] event in
            self?.refusalCleared(for: event.sessionID)
        }

        // A candidate login answered. The offer is only worth as much as the numbers on it, and
        // the dismissal survives, because this is still the same refusal.
        observations.observe(AccountUsageDidChange.self) { [weak self] _ in
            self?.rerankStandingRefusals()
        }
    }

    // MARK: - Public Methods — A Standing Refusal

    /// A session's provider refused it over a spent limit, and nothing is recovering it.
    ///
    /// The one entry point both surfaces use: `LimitRecoveryCoordinator` reads a terminal
    /// session's refusal out of its transcript, a rendered conversation is told by its own
    /// stream, and from here on the two are the same fact. Calling it again is a **new**
    /// refusal, which is what makes a previous dismissal stop applying.
    func refusalStands(_ stop: UsageLimitStop, for sessionID: SessionID) {
        standingRefusals[sessionID] = stop

        // Asked here rather than where the offer is drawn: a refusal is read seconds after it
        // happens and looked at minutes later, which is the only moment a fetch has time to land
        // before it is needed. Every pacing rule in `AccountUsageService` still applies, so a
        // refusal cannot become a way to hammer the usage endpoints.
        LimitEscapeSuggestion.warmCandidateReadings(for: sessionID)

        guard let suggestion = LimitEscapeSuggestion.compute(for: sessionID, stop: stop) else {
            // Only a session that is no longer there. A refusal with no login to escape to still
            // gets a record, because waiting for the reset needs no second account.
            clear(sessionID)
            EventLog.shared.record(.limitRecovery, "Refusal read for a session that is gone", [
                "session": sessionID.uuidString
            ])
            return
        }

        record(suggestion)
        EventLog.shared.record(
            .limitRecovery,
            suggestion.offersAccountEscape ? "Escape suggested" : "Refusal stands, no login with headroom",
            [
                "session": sessionID.uuidString,
                "account": suggestion.accountID?.description ?? "",
                "window": suggestion.decidingWindowName ?? "",
                "reading": suggestion.reading ?? "",
                "model": suggestion.model ?? ""
            ]
        )
    }

    /// The refusal is over: the conversation spoke again, or the session stopped being one.
    func refusalCleared(for sessionID: SessionID) {
        standingRefusals.removeValue(forKey: sessionID)
        clear(sessionID)
    }

    /// Whether a refusal is standing over this session — the flag the surfaces read back rather
    /// than each keeping their own copy of it.
    func hasStandingRefusal(for sessionID: SessionID) -> Bool {
        standingRefusals[sessionID] != nil
    }

    // MARK: - Public Methods

    /// The record for a session, dismissed or not.
    func suggestion(for sessionID: SessionID) -> LimitEscapeSuggestion? {
        entries[sessionID]
    }

    /// What a surface should draw, which is nothing once the user has waved it away.
    func offer(for sessionID: SessionID) -> LimitEscapeSuggestion? {
        guard let suggestion = entries[sessionID], !suggestion.isDismissed else { return nil }
        return suggestion
    }

    /// Files the offer for a **new** refusal, which is also what makes a previous dismissal
    /// stop applying: the user waved away one refusal, not the state of being refused.
    func record(_ suggestion: LimitEscapeSuggestion) {
        var fresh = suggestion
        fresh.isDismissed = false
        entries[suggestion.sessionID] = fresh
        announce(suggestion.sessionID)
    }

    /// Re-files the offer for the refusal already standing — a candidate's reading arrived, and
    /// the numbers on the button moved. Keeps the dismissal, because this is the same refusal.
    ///
    /// Does nothing where no offer stands: a reading arriving for a session that was never
    /// refused is not news.
    func update(_ suggestion: LimitEscapeSuggestion) {
        guard let standing = entries[suggestion.sessionID] else { return }

        var fresh = suggestion
        fresh.isDismissed = standing.isDismissed
        guard fresh != standing else { return }
        entries[suggestion.sessionID] = fresh
        announce(suggestion.sessionID)
    }

    /// Waves this refusal's offer away until a new one is computed.
    func dismiss(_ sessionID: SessionID) {
        guard var suggestion = entries[sessionID], !suggestion.isDismissed else { return }
        suggestion.isDismissed = true
        entries[sessionID] = suggestion
        EventLog.shared.record(.limitRecovery, "Escape suggestion dismissed", [
            "session": sessionID.uuidString,
            "account": suggestion.accountID?.description ?? ""
        ])
        announce(sessionID)
    }

    /// The refusal is over — the conversation spoke again, the session went dormant, or the
    /// escape landed.
    func clear(_ sessionID: SessionID) {
        guard entries.removeValue(forKey: sessionID) != nil else { return }
        announce(sessionID)
    }

    /// Marks the tap as in flight, so the button states that it is working rather than sitting
    /// pressable while a migration runs.
    func setBusy(_ action: LimitEscapeAction?, for sessionID: SessionID) {
        guard var suggestion = entries[sessionID], suggestion.busy != action else { return }
        suggestion.busy = action
        if action != nil { suggestion.problem = nil }
        entries[sessionID] = suggestion
        announce(sessionID)
    }

    /// States why the tap did not go through, on the strip that offered it. Never followed by a
    /// different login chosen on the user's behalf — see `LimitEscapeSuggestion.problem`.
    ///
    /// A `reading` given here replaces the one on the record, because the reason a tap is
    /// refused is nearly always that the forced read disagreed with the cached one, and a
    /// button still quoting the cached figure would be arguing with the sentence beside it.
    func note(problem: String, reading: String? = nil, for sessionID: SessionID) {
        guard var suggestion = entries[sessionID] else { return }
        suggestion.busy = nil
        suggestion.problem = problem
        if let reading { suggestion.reading = reading }
        entries[sessionID] = suggestion
        announce(sessionID)
    }

    // MARK: - Private Methods

    /// Re-ranks every standing refusal against readings that have since arrived.
    ///
    /// Bounded by the number of *refused* sessions rather than by the number of accounts: usage
    /// readings move several times a minute in a busy app, and this runs a pure comparison over
    /// a set that is almost always empty and never larger than the live sessions.
    ///
    /// A recomputation that finds nothing to offer leaves the standing offer alone rather than
    /// withdrawing it: the refusal has not gone anywhere, and a strip that vanished because one
    /// account's reading failed would be reporting the wrong thing.
    private func rerankStandingRefusals() {
        for (sessionID, stop) in standingRefusals {
            guard entries[sessionID] != nil,
                  let suggestion = LimitEscapeSuggestion.compute(for: sessionID, stop: stop)
            else { continue }
            update(suggestion)
        }
    }

    private func announce(_ sessionID: SessionID) {
        center.post(LimitEscapeSuggestionDidChange(sessionID: sessionID))
    }
}

// MARK: - Limit Escape Defaults

enum LimitEscapeDefaults {

    /// How full a window may be before its login stops being somewhere to escape *to*.
    ///
    /// The pill's own warning threshold rather than a second number beside it: an account
    /// Threading already tints as under pressure is not a place to move a conversation that has
    /// just run out, and two thresholds a few points apart would eventually disagree about the
    /// same login on the same screen.
    static let headroomFraction = UsageDefaults.warningFraction

    /// How long the continuation waits behind a migration before it is due.
    ///
    /// A migration stops the agent and starts it again under the other login, and the CLI has to
    /// come up and replay the transcript before there is a prompt to type into. The delivery
    /// rules in [`scheduled-messages.md`](scheduled-messages.md) are what actually keep this
    /// safe — a send arriving mid-turn parks `.waiting` and is retried on the activity edge —
    /// so this only spares the store an attempt that was never going to land.
    ///
    /// It is also why the record is not created "now": `ScheduledMessageStore.add` refuses a
    /// moment that has already passed, which is the right rule for everything else it holds.
    static let continuationDelay: TimeInterval = 8
}

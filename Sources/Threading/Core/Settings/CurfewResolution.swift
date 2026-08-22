import Foundation

// MARK: - Scope

/// Which record answered for a session's curfew.
///
/// Named rather than inferred from "is the session's field nil", because the menu's checkmark
/// and the row's mark both need to tell *chose it* from *followed somebody who chose it* — the
/// distinction `LimitRecoveryScope` and `ThemeScope` draw, for the same surfaces.
enum CurfewScope: Equatable, Sendable {
    case session
    case project
    case app
}

// MARK: - Resolved Curfew

/// One deadline and everything that follows from it.
///
/// The three moments are computed rather than stored so that changing a margin in Settings moves
/// them for every armed session at once, with nothing to migrate: a stored `windDownAt` would
/// have to be rewritten across every record the next time somebody dragged the popup, and the
/// ones that were dormant at the time would keep the old ladder.
struct ResolvedCurfew: Equatable, Sendable {

    // MARK: - Properties

    /// The moment Threading stops spending this session on its own.
    let deadline: Date

    let origin: CurfewOrigin

    /// How long before the deadline the wrap-up goes out; `nil` sends none.
    let windDownMargin: TimeInterval?

    /// How long after the deadline a turn still in flight is left alone; `nil` never interrupts.
    let grace: TimeInterval?

    let windDownText: String

    // MARK: - The Three Moments

    /// When the agent is asked to wrap up. Absent when the user turned the wrap-up off.
    var windDownAt: Date? {
        windDownMargin.map { deadline.addingTimeInterval(-$0) }
    }

    /// When a turn still in flight is interrupted. Absent when the user chose never to
    /// interrupt — the hold still applies, so the session stops being spent either way.
    var interruptAt: Date? {
        grace.map { deadline.addingTimeInterval($0) }
    }

    /// How long the wrap-up stays deliverable **past** the deadline.
    ///
    /// The wrap-up is exempt from the hold it belongs to, because an interrupted agent still
    /// needs one turn to commit and write the handoff note — and on a terminal session that turn
    /// only becomes typeable once the interrupt has produced the activity edge, which is after
    /// the deadline by construction. The grace is when the interrupt lands; one more wind-down
    /// margin past it is the window in which the wrap-up can still do its job. Past that it
    /// fails with the curfew's own sentence rather than arriving in the morning.
    var windDownDeliverableUntil: Date {
        deadline.addingTimeInterval((grace ?? 0) + (windDownMargin ?? 0))
    }

    /// When this curfew ends by itself. Only a quiet-hours instance has one: a curfew the user
    /// set on a session is lifted explicitly or not at all.
    var endsAt: Date? {
        guard case .quietHours(let endsAt) = origin else { return nil }
        return endsAt
    }
}

// MARK: - Curfew Resolution

/// Which curfew governs one conversation, and who said so.
///
/// Three scopes, narrowest first: the chat, its checkout, the standing quiet hours in Settings.
/// Absent means **inherit, not none** — the rule every scoped setting here follows
/// (`LimitRecoveryResolution`, `ThemeResolution`, `SoundResolution`) — so switching quiet hours
/// on still reaches every chat that never answered for itself.
///
/// The chain is pure, and kept apart from the store on purpose: this is the rule that decides
/// when the app stops spending somebody's session and, past the grace, types into it. It should
/// be assertable with no home directory, no database and no live agent.
enum CurfewResolution {

    /// A resolved curfew and the scope that supplied it. `nil` is a real answer: *this session
    /// has no curfew*, which is what an exemption produces.
    struct Answer: Equatable, Sendable {
        let scope: CurfewScope
        let curfew: ResolvedCurfew?
    }

    // MARK: - The Chain

    /// Resolves narrowest-first. The app scope always answers, so this cannot fail.
    ///
    /// `state` enters for exactly one reason: a quiet-hours instance the user **lifted** must
    /// stay lifted until its window closes, and a window is not a record anybody can write nil
    /// into. Lifting it any other way — writing `.exempt` on the session — would exempt it from
    /// every night that follows, which is not what "not tonight" means.
    static func resolve(
        session: CurfewRule?,
        project: CurfewRule?,
        preferences: CurfewPreferences,
        state: SessionCurfewState?,
        now: Date,
        calendar: Calendar = .current
    ) -> Answer {
        switch session {
        case .exempt:
            return Answer(scope: .session, curfew: nil)
        case .until(let deadline):
            return Answer(
                scope: .session,
                curfew: curfew(deadline: deadline, origin: .session, preferences: preferences)
            )
        case nil:
            break
        }

        // A checkout may exempt its chats and may not set a deadline for them: `.until` is a
        // wall-clock moment, and one written on a project would keep ending chats created weeks
        // later at a time nobody chose. `ProjectStore.setCurfewRule(_:forProjectID:)` refuses
        // it; a record carrying one anyway — a hand-edited file, a newer build — falls through
        // to the standing window rather than being honoured.
        if case .exempt = project {
            return Answer(scope: .project, curfew: nil)
        }

        return quietHours(preferences: preferences, state: state, now: now, calendar: calendar)
    }

    /// What a record *would* follow if it said nothing — the answer a menu names beside its
    /// Inherit row, and the value a writer compares against before storing anything.
    ///
    /// Expressed as resolution with that one level removed rather than as a second rule, so the
    /// label and the writer cannot drift apart; `LimitRecoveryResolution.inherited(beyond:…)` is
    /// the same construction for the same reason.
    static func inherited(
        beyond scope: CurfewScope,
        project: CurfewRule?,
        preferences: CurfewPreferences,
        now: Date,
        calendar: Calendar = .current
    ) -> ResolvedCurfew? {
        switch scope {
        case .session:
            return resolve(
                session: nil,
                project: project,
                preferences: preferences,
                state: nil,
                now: now,
                calendar: calendar
            ).curfew
        case .project, .app:
            return resolve(
                session: nil,
                project: nil,
                preferences: preferences,
                state: nil,
                now: now,
                calendar: calendar
            ).curfew
        }
    }

    // MARK: - Private Methods

    /// The standing window's answer: the one `now` is inside, else the one it will be inside
    /// next.
    ///
    /// Both are curfews rather than only the first, because every surface that reads this is
    /// answering "when does this session end" ahead of time — the composer chip, the row mark,
    /// the engine arming its timer. A window that has not opened yet is still the deadline this
    /// session is running towards.
    private static func quietHours(
        preferences: CurfewPreferences,
        state: SessionCurfewState?,
        now: Date,
        calendar: Calendar
    ) -> Answer {
        let hours = preferences.quietHours
        if let window = hours.window(containing: now, calendar: calendar) {
            // Lifted *this* instance, identified by its start. The next night's window has a
            // different start, so tomorrow resolves again with nothing carried over — which is
            // the whole difference between "not tonight" and "never".
            if let state, state.deadline == window.start, state.liftedAt != nil {
                return Answer(scope: .app, curfew: nil)
            }
            return Answer(
                scope: .app,
                curfew: curfew(
                    deadline: window.start,
                    origin: .quietHours(endsAt: window.end),
                    preferences: preferences
                )
            )
        }
        guard let next = hours.nextWindow(after: now, calendar: calendar) else {
            return Answer(scope: .app, curfew: nil)
        }
        return Answer(
            scope: .app,
            curfew: curfew(
                deadline: next.start,
                origin: .quietHours(endsAt: next.end),
                preferences: preferences
            )
        )
    }

    /// The margins and the wrap-up come from Settings in every case. Per-session wrap-up text is
    /// deliberately out of scope for this slice: one message, edited in one place.
    private static func curfew(
        deadline: Date,
        origin: CurfewOrigin,
        preferences: CurfewPreferences
    ) -> ResolvedCurfew {
        ResolvedCurfew(
            deadline: deadline,
            origin: origin,
            windDownMargin: preferences.windDownMargin,
            grace: preferences.grace,
            windDownText: preferences.windDownText
        )
    }

    // MARK: - Reading The Records
    //
    // The only part of this file that knows where the records live. Each takes the store as a
    // parameter rather than reaching for `ProjectStore.shared`: a sidebar is built against
    // whichever store it was handed, and merely *touching* the singleton in a test loads the
    // real database — the mistake `LimitRecoveryResolution` documents, which broke
    // `SidebarTreeBuilderTests` wholesale.
    //
    // `now` is a parameter for the same kind of reason. Every answer here depends on the clock
    // — a standing window is "the one containing this moment" — so a caller that has a moment
    // in mind, and every test, says which one rather than racing the one this call happens to
    // read.

    /// The curfew governing one conversation, and the scope that supplied it.
    @MainActor
    static func answer(
        forSessionID sessionID: SessionID,
        in store: ProjectStore = .shared,
        now: Date = Date()
    ) -> Answer {
        let session = store.session(withID: sessionID)
        return resolve(
            session: session?.curfewRule,
            project: store.project(forSessionID: sessionID)?.curfewRule,
            preferences: CurfewSettings.shared.preferences,
            state: session?.curfewState,
            now: now
        )
    }

    /// What this conversation would follow if it had no answer of its own — what the menu names
    /// beside its Inherit row, and what a writer compares against before storing anything.
    @MainActor
    static func inherited(
        beyondSessionID sessionID: SessionID,
        in store: ProjectStore = .shared,
        now: Date = Date()
    ) -> ResolvedCurfew? {
        inherited(
            beyond: .session,
            project: store.project(forSessionID: sessionID)?.curfewRule,
            preferences: CurfewSettings.shared.preferences,
            now: now
        )
    }

    /// The curfew governing a checkout's chats that never answered for themselves.
    @MainActor
    static func answer(
        forProjectID projectID: ProjectID,
        in store: ProjectStore = .shared,
        now: Date = Date()
    ) -> Answer {
        resolve(
            session: nil,
            project: store.project(withID: projectID)?.curfewRule,
            preferences: CurfewSettings.shared.preferences,
            // A checkout has no instance of its own to have lifted: a lift belongs to the one
            // session whose state records it.
            state: nil,
            now: now
        )
    }

    /// What this checkout would follow if it had no answer of its own — the standing window,
    /// since there is no scope between a checkout and Settings. It takes the identifier anyway
    /// so the call site reads like the session one and keeps saying what it is asking about.
    @MainActor
    static func inherited(
        beyondProjectID projectID: ProjectID,
        now: Date = Date()
    ) -> ResolvedCurfew? {
        inherited(
            beyond: .project,
            project: nil,
            preferences: CurfewSettings.shared.preferences,
            now: now
        )
    }
}

import Foundation

// MARK: - Scheduled Curfew Plan Resolution

/// What a frozen `ScheduledCurfewPlan` means at the moment its session finally starts.
///
/// A plan is a decision — *this* moment, or whenever quiet hours next begin — and the decision is
/// what survives the wait. Turning it back into a deadline is therefore something that happens at
/// fire time, against the clock and the settings in force then, and it can legitimately answer
/// *nothing to arm*: a start that fired late has a wall-clock end that is already behind it, and a
/// standing window the user switched off in the meantime names no moment at all.
///
/// Pure, and kept out of the coordinator, for `CurfewResolution`'s reason: this decides when the
/// app will stop spending somebody's session and, past the grace, type into it. It should be
/// assertable with no window, no database and no live agent — which is also why the skipped cases
/// are named rather than folded into a bare `nil`, since what the journal records the next morning
/// is *which* of them happened.
enum ScheduledCurfewPlanResolution {

    // MARK: - Outcome

    /// What the caller should do with the plan it is holding.
    enum Outcome: Equatable, Sendable {

        /// The plan carried no curfew. The session runs until somebody stops it.
        case noCurfew

        /// Arm this session's curfew at this moment.
        case arm(Date)

        /// The plan named an end that cannot be armed, and why.
        case skipped(Reason)
    }

    /// Why a plan that asked for an end got none. Raw values are what the journal prints.
    enum Reason: String, Equatable, Sendable {

        /// A wall-clock end that had already passed when the start finally fired — the missed
        /// overnight case. Arming it would hold the session from its first breath, which is not
        /// what "end it at four" asked for.
        case deadlineAlreadyPassed

        /// The plan followed the standing quiet hours, and by the time it fired there were none:
        /// switched off, or configured into a window that names no moment.
        case quietHoursNotConfigured
    }

    // MARK: - Public Methods

    /// The moment this plan ends its session, or the reason it ends nothing.
    ///
    /// `atQuietHours` resolves to the **next** window's start rather than to the one `now` may
    /// already be standing inside, so the deadline is always ahead of the session that is about to
    /// begin — and it is the same moment `CurfewMenu` named when the plan was chosen, which is the
    /// half of this that the user actually read.
    static func deadline(
        for plan: ScheduledCurfewPlan?,
        preferences: CurfewPreferences,
        now: Date,
        calendar: Calendar = .current
    ) -> Outcome {
        switch plan {
        case nil:
            return .noCurfew

        case .at(let deadline):
            guard deadline > now else { return .skipped(.deadlineAlreadyPassed) }
            return .arm(deadline)

        case .atQuietHours:
            let quietHours = preferences.quietHours
            guard quietHours.isEnabled,
                  let next = quietHours.nextWindow(after: now, calendar: calendar) else {
                return .skipped(.quietHoursNotConfigured)
            }
            return .arm(next.start)
        }
    }
}

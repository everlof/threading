import Foundation

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
    /// One provider process starts per interval, after the selected conversation's head start.
    static let staggerInterval: TimeInterval = 1.0

    /// The launch set, and the reason for every session that is not in it.
    struct Plan: Equatable, Sendable {
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

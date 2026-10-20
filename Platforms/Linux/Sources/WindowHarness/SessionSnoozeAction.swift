#if os(Linux)
import Foundation
import Glibc
@testable import CoreSlice

/// Durable snooze writes and deadline reconciliation for the Linux host. The UI owns one
/// deadline map and timer; this worker never reads or writes the store on the drawing path.
enum SessionSnoozeAction {
    enum Change: Sendable {
        case snooze(until: Date, at: Date, hadTurnInFlight: Bool)
        case unsnooze
        case wake(SessionWakeReason, at: Date)
        case acknowledge
    }

    struct Result: Sendable {
        let changed: Bool
        let deadline: Date?
        let hasWake: Bool
    }

    struct Deadlines: Sendable {
        let active: [SessionID: Date]
        let expired: [SessionID]
    }

    static func run(store: String, sessionID: SessionID, projectID: ProjectID,
                    change: Change) throws -> Result {
        try withLockedDatabase(store: store) { database in
            guard let record = try database.sessionRecord(id: sessionID),
                  record.project.id == projectID else {
                throw WindowFailure("session is no longer in this project")
            }
            var session = record.session
            let changed: Bool
            switch change {
            case .snooze(let deadline, let date, let hadTurnInFlight):
                guard !session.isArchived, deadline > date else {
                    throw WindowFailure("session cannot be snoozed")
                }
                changed = session.snoozedAt != date || session.snoozedUntil != deadline
                    || session.hadTurnInFlightWhenSnoozed != hadTurnInFlight
                    || session.wake != nil
                session.snoozedAt = date
                session.snoozedUntil = deadline
                session.hadTurnInFlightWhenSnoozed = hadTurnInFlight
                session.wake = nil
            case .unsnooze:
                changed = session.snoozedAt != nil || session.snoozedUntil != nil
                session.snoozedAt = nil
                session.snoozedUntil = nil
                session.hadTurnInFlightWhenSnoozed = false
            case .wake(let reason, let date):
                guard session.snoozedAt != nil else {
                    return Result(changed: false, deadline: nil, hasWake: session.wake != nil)
                }
                if reason == .turnCompleted && !session.hadTurnInFlightWhenSnoozed {
                    return Result(changed: false, deadline: session.snoozedUntil,
                                  hasWake: session.wake != nil)
                }
                if reason == .timeReached {
                    guard let deadline = session.snoozedUntil, deadline <= date else {
                        return Result(changed: false, deadline: session.snoozedUntil,
                                      hasWake: session.wake != nil)
                    }
                } else {
                    guard let snoozedAt = session.snoozedAt,
                          session.isSnoozed(at: date), date >= snoozedAt else {
                        return Result(changed: false, deadline: session.snoozedUntil,
                                      hasWake: session.wake != nil)
                    }
                }
                changed = true
                session.snoozedAt = nil
                session.snoozedUntil = nil
                session.hadTurnInFlightWhenSnoozed = false
                session.wake = SessionWake(reason: reason, wokeAt: date)
            case .acknowledge:
                changed = session.wake != nil
                session.wake = nil
            }
            if changed {
                try database.saveSession(session, in: projectID, position: record.position)
            }
            return Result(changed: changed, deadline: session.snoozedUntil,
                          hasWake: session.wake != nil)
        }
    }

    /// One startup pass through the already stored graph, matching macOS's materialization of
    /// deadlines missed while the app was closed. Later expiry uses exact indexed row writes.
    static func reconcileAtStartup(store: String, now: Date) throws -> Deadlines {
        try withLockedDatabase(store: store) { database in
            let state = try database.load().state
            var active: [SessionID: Date] = [:]
            var expired: [SessionID] = []
            var writes: [ProjectDatabase.SessionWrite] = []
            for project in state.projects {
                for (position, stored) in project.sessions.enumerated() where !stored.isArchived {
                    guard stored.snoozedAt != nil, let deadline = stored.snoozedUntil else {
                        continue
                    }
                    if stored.isSnoozed(at: now) {
                        active[stored.id] = deadline
                    } else {
                        var session = stored
                        session.snoozedAt = nil
                        session.snoozedUntil = nil
                        session.hadTurnInFlightWhenSnoozed = false
                        session.wake = SessionWake(reason: .timeReached, wokeAt: deadline)
                        writes.append(.init(session: session, projectID: project.id,
                                            position: position))
                        expired.append(stored.id)
                    }
                }
            }
            if !writes.isEmpty { try database.saveSessions(writes) }
            return Deadlines(active: active, expired: expired)
        }
    }

    /// The host sends only deadlines due on its one timer. One transaction handles a group
    /// expiring together, rather than decoding all historical sessions on every wake.
    static func expire(store: String, due: [SessionID], now: Date) throws -> [SessionID: Result] {
        try withLockedDatabase(store: store) { database in
            var writes: [ProjectDatabase.SessionWrite] = []
            var results: [SessionID: Result] = [:]
            for id in due {
                guard let record = try database.sessionRecord(id: id) else { continue }
                var session = record.session
                guard !session.isArchived, session.snoozedAt != nil,
                      let deadline = session.snoozedUntil else {
                    results[id] = Result(changed: false, deadline: nil,
                                         hasWake: session.wake != nil)
                    continue
                }
                guard deadline <= now else {
                    results[id] = Result(changed: false, deadline: deadline,
                                         hasWake: session.wake != nil)
                    continue
                }
                session.snoozedAt = nil
                session.snoozedUntil = nil
                session.hadTurnInFlightWhenSnoozed = false
                session.wake = SessionWake(reason: .timeReached, wokeAt: deadline)
                writes.append(.init(session: session, projectID: record.project.id,
                                    position: record.position))
                results[id] = Result(changed: true, deadline: nil, hasWake: true)
            }
            if !writes.isEmpty { try database.saveSessions(writes) }
            return results
        }
    }

    private static func withLockedDatabase<T>(store: String,
        _ body: (ProjectDatabase) throws -> T) throws -> T {
        let root = URL(fileURLWithPath: store, isDirectory: true)
        let databaseURL = root.appendingPathComponent("threading.db")
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw WindowFailure("session store does not exist")
        }
        let lock = Glibc.open(root.appendingPathComponent("host.lock").path,
                              O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw WindowFailure("cannot open session store lock") }
        defer { Glibc.close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            throw WindowFailure("session store is already owned")
        }
        let database = try ProjectDatabase(url: databaseURL)
        defer { database.close() }
        return try body(database)
    }
}
#endif

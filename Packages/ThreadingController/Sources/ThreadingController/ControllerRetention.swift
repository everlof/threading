import Foundation

/// Owner retention. Removes journal history older than a cutoff while keeping every record
/// that resolves state:
///
/// - `event` journal rows are deleted (sequences are AUTOINCREMENT, so a consumer's cursor
///   stays valid and simply skips the pruned range);
/// - task `activity` is deleted only for completed or cancelled work;
/// - a trigger source event keeps its row, its (id, revision) dedupe key and its admission
///   receipts, but its event fields and evidence are dropped, so a redelivery still admits
///   nothing twice.
///
/// Work, questions, deliveries, launches, usage receipts, automation runs, mail and memory are
/// never pruned here. Each batch commits on its own and one call examines a bounded number of
/// rows; a call that stops early returns `more` and a cursor to continue from.
public struct ControllerPruneResult: Codable, Equatable, Sendable {
    public let before: String
    public let events: Int
    public let activities: Int
    public let sourceEvents: Int
    /// Pass back as `after` while `more` is true.
    public let next: Int64
    public let more: Bool
}

public enum RetentionLimits {
    /// Rows examined (and at most changed) per write transaction; also SQLite's page bound.
    public static let rowsPerCommit = 100
    /// Rows examined per call across all kinds.
    public static let rowsPerCall = 10_000
    /// Prune never reaches into the most recent day of history.
    public static let minimumAge: TimeInterval = 86_400
}

extension ControllerStore {
    public func prune(before: Date, after: Int64 = 0, now: Date = Date()) throws -> ControllerPruneResult {
        guard after >= 0 else { throw ControllerError.invalidInput("cursor") }
        guard before <= now.addingTimeInterval(-RetentionLimits.minimumAge) else { throw ControllerError.invalidInput("prune_too_recent") }
        let cutoff = ISO8601DateFormatter().string(from: before)
        var budget = RetentionLimits.rowsPerCall
        var events = 0
        // The journal is append-only, so its oldest rows are always at the head: delete from
        // there until a row at or after the cutoff.
        journal: while budget > 0 {
            let removed: Int? = try db.transaction {
                let rows = try db.rows("SELECT sequence,at FROM event ORDER BY sequence LIMIT ?",
                                       [.integer(Int64(min(budget, RetentionLimits.rowsPerCommit)))])
                var removed = 0
                for row in rows {
                    guard try row.text(1) < cutoff else { return removed == 0 ? nil : removed }
                    try db.run("DELETE FROM event WHERE sequence=?", [.integer(row.integers[0])])
                    removed += 1
                }
                return rows.isEmpty ? nil : removed
            }
            guard let removed else { break journal }
            events += removed
            budget -= removed
        }
        var activities = 0
        var sourceEvents = 0
        var cursors: [Int64] = []
        for kind in ["activity", "sourceEvent"] {
            var cursor = after
            var finished = false
            while budget > 0, !finished {
                try db.transaction {
                    let rows = try db.rows("""
                        SELECT sequence,parent,payload FROM record INDEXED BY record_page
                        WHERE kind=? AND sequence>? ORDER BY sequence LIMIT ?
                        """, [.text(kind), .integer(cursor), .integer(Int64(min(budget, RetentionLimits.rowsPerCommit)))],
                        pageByteLimit: 1_048_576)
                    if rows.isEmpty { finished = true }
                    var terminal: [String: Bool] = [:]
                    for row in rows {
                        if kind == "activity" {
                            let activity: WorkActivity = try decode(row.text(2))
                            guard activity.at < cutoff else { finished = true; break }
                            let parent = try row.text(1)
                            let done = try terminal[parent] ?? {
                                let state = try work(WorkID(parent)).state
                                return state == .completed || state == .cancelled
                            }()
                            terminal[parent] = done
                            if done {
                                try db.run("DELETE FROM record WHERE sequence=?", [.integer(row.integers[0])])
                                activities += 1
                            }
                        } else {
                            var stored: SourceEvent = try decode(row.text(2))
                            guard stored.receivedAt < cutoff else { finished = true; break }
                            if !stored.event.fields.isEmpty || stored.event.evidence != nil {
                                stored = SourceEvent(sourceID: stored.sourceID, event: stored.event.withoutContent,
                                                     receivedAt: stored.receivedAt, receipts: stored.receipts)
                                try db.run("UPDATE record SET payload=? WHERE sequence=?",
                                           [.text(try encode(stored)), .integer(row.integers[0])])
                                sourceEvents += 1
                            }
                        }
                        cursor = row.integers[0]
                        budget -= 1
                    }
                }
            }
            if !finished { cursors.append(cursor) }
        }
        if events + activities + sourceEvents > 0 { try db.transaction { try event("controller.pruned", cutoff) } }
        let more = budget <= 0
        return ControllerPruneResult(before: cutoff, events: events, activities: activities, sourceEvents: sourceEvents,
                                     next: more ? (cursors.min() ?? after) : 0, more: more)
    }
}

extension ProbeEvent {
    /// The identity a dedupe key needs, without the fields and evidence it carried.
    var withoutContent: ProbeEvent { ProbeEvent(compacting: self) }
    private init(compacting event: ProbeEvent) {
        id = event.id; revision = event.revision; occurredAt = event.occurredAt; fields = [:]; evidence = nil
    }
}

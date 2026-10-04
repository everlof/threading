import Foundation

/// Ordering between work items: `after` names work that must complete before an item is claimed.
/// Dependencies must already exist, so the graph is acyclic by construction. A cancelled
/// dependency can never complete, so its queued dependents are cancelled with a reason in the
/// same transaction instead of waiting forever.
///
/// Scaling: each item names at most `maximumPerItem` dependencies and each item may be named by
/// at most `maximumDependents`, so one reverse lookup is a single indexed page. A cascade visits
/// only queued dependents — work that is still active — so its cost is bounded by the active
/// queue, never by completed history.
public enum WorkDependencies {
    public static let maximumPerItem = 16
    public static let maximumDependents = 64
    static let kind = "workDependency"
    static let cancelledReasonPrefix = "dependency_cancelled: "

    /// Appended to the claim query: every named dependency's work record is `completed`.
    static let satisfiedClause = """
        NOT EXISTS (SELECT 1 FROM json_each(work.payload,'$.dependsOn') AS dependency
            JOIN record AS needed ON needed.kind='work' AND needed.id=dependency.value
            WHERE needed.state IS NOT 'completed')
        """
}

extension ControllerStore {
    /// Validates and indexes `work.dependsOn` (dependency → dependent) inside the enqueue.
    func recordDependencies(of work: WorkItem) throws {
        for dependency in work.dependsOn ?? [] {
            let needed: WorkItem = try required("work", dependency.description)
            guard needed.state != .cancelled else { throw ControllerError.invalidInput("dependency_cancelled") }
            let dependents = try db.rows("SELECT id FROM record WHERE kind=? AND parent=? LIMIT ?",
                                         [.text(WorkDependencies.kind), .text(dependency.description),
                                          .integer(Int64(WorkDependencies.maximumDependents))])
            guard dependents.count < WorkDependencies.maximumDependents else { throw ControllerError.invalidInput("dependents") }
            try insert(WorkDependencies.kind, "\(dependency)/\(work.id)", parent: dependency.description,
                       scope: work.id.description, value: work.id)
        }
    }

    /// Cancels every queued item that (transitively) depends on `workID`, recording which
    /// dependency was cancelled. Runs inside the cancelling transaction.
    func cancelDependents(of workID: WorkID) throws {
        var pending = [workID]
        while let cancelled = pending.popLast() {
            let rows = try db.rows("SELECT scope FROM record WHERE kind=? AND parent=? ORDER BY sequence LIMIT ?",
                                   [.text(WorkDependencies.kind), .text(cancelled.description),
                                    .integer(Int64(WorkDependencies.maximumDependents))])
            for row in rows {
                let dependent = try WorkID(row.text(0))
                var work = try self.work(dependent)
                // Only a queued item can be waiting on a dependency; anything else already ended.
                guard work.state == .queued else { continue }
                work.state = .cancelled
                work.cancelReason = WorkDependencies.cancelledReasonPrefix + cancelled.description
                try saveWork(work)
                try event("work.cancelled", dependent.description, text: work.cancelReason)
                pending.append(dependent)
            }
        }
    }
}

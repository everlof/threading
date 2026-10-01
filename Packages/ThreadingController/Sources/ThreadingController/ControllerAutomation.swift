import Foundation
import ThreadingDomain

public enum AutomationTag: Sendable {}
public typealias AutomationID = ControllerID<AutomationTag>
public enum AutomationMissedPolicy: String, Codable, Sendable { case skip, latest }

/// The execution recipe stays with the worker. Changing a schedule never widens its permissions.
public struct ControllerAutomationSpec: Codable, Equatable, Sendable {
    public var name: String
    public var workerID: WorkerID
    public var instruction: String
    public var schedule: AutomationSchedule?
    public var missedPolicy: AutomationMissedPolicy
    public var archiveOnSuccess: Bool
    public init(name: String, workerID: WorkerID, instruction: String, schedule: AutomationSchedule?,
                missedPolicy: AutomationMissedPolicy = .skip, archiveOnSuccess: Bool = true) {
        self.name = name; self.workerID = workerID; self.instruction = instruction
        self.schedule = schedule; self.missedPolicy = missedPolicy; self.archiveOnSuccess = archiveOnSuccess
    }
    func validate() throws {
        try Limits.text(name, field: "automation_name", maximum: 160)
        try Limits.text(instruction, field: "instruction")
        do { try schedule?.validate() } catch { throw ControllerError.invalidInput("schedule") }
    }
}
public struct ControllerAutomation: Codable, Equatable, Sendable {
    public let id: AutomationID
    public internal(set) var revision: Int
    public internal(set) var enabled: Bool
    public internal(set) var deleted: Bool
    public internal(set) var spec: ControllerAutomationSpec
    public internal(set) var nextRunAt: Date?
    public internal(set) var lastWorkID: WorkID?
}
public struct ControllerAutomationRun: Codable, Equatable, Sendable {
    public let id: UUID
    public let automationID: AutomationID
    public let revision: Int
    public let key: String
    public let scheduledAt: Date
    public let recordedAt: Date
    public let workID: WorkID?
    /// enqueued, missed, or overlap. Execution state is read from the durable work receipt.
    public let admission: String
    public let archiveOnSuccess: Bool
}
public struct ControllerAutomationRunStatus: Codable, Sendable {
    public let run: ControllerAutomationRun
    public let workState: WorkState?
    public let archived: Bool
    public let result: String?
}

extension ControllerStore {
    public func automations(after: Int64 = 0, limit: Int = 50) throws -> ControllerPage<ControllerAutomation> {
        try page("automation", after: after, limit: limit)
    }
    public func automation(_ id: AutomationID) throws -> ControllerAutomation { try required("automation", id.description) }

    public func configureAutomation(_ id: AutomationID, expectedRevision: Int,
                                    spec: ControllerAutomationSpec, now: Date = Date()) throws -> ControllerAutomation {
        try spec.validate()
        guard expectedRevision >= 0, expectedRevision < Int.max else { throw ControllerError.invalidInput("revision") }
        return try db.transaction {
            let _: ControllerWorker = try required("worker", spec.workerID.description)
            try requireActiveWorker(spec.workerID)
            let old: ControllerAutomation? = try optional("automation", id.description)
            guard (old?.revision ?? 0) == expectedRevision, old?.deleted != true else { throw ControllerError.conflict }
            let value = ControllerAutomation(id: id, revision: expectedRevision + 1, enabled: false,
                deleted: false, spec: spec, nextRunAt: nil, lastWorkID: old?.lastWorkID)
            if old == nil { try insert("automation", id.description, value: value) }
            else { try update("automation", id.description, value: value) }
            try db.run("DELETE FROM automation_due WHERE id=?", [.text(id.description)])
            try event("automation.configured", id.description)
            return value
        }
    }
    public func setAutomationEnabled(_ id: AutomationID, expectedRevision: Int, enabled: Bool,
                                     now: Date = Date()) throws -> ControllerAutomation {
        try db.transaction {
            var value = try automation(id)
            guard value.revision == expectedRevision, !value.deleted, expectedRevision < Int.max else { throw ControllerError.conflict }
            if enabled { try requireActiveWorker(value.spec.workerID) }
            value.revision += 1; value.enabled = enabled
            value.nextRunAt = enabled ? try value.spec.schedule?.next(after: now) : nil
            try saveAutomation(value)
            try event(enabled ? "automation.enabled" : "automation.paused", id.description)
            return value
        }
    }
    public func deleteAutomation(_ id: AutomationID, expectedRevision: Int) throws -> ControllerAutomation {
        try db.transaction {
            var value = try automation(id)
            guard value.revision == expectedRevision, !value.deleted, expectedRevision < Int.max else { throw ControllerError.conflict }
            value.revision += 1; value.enabled = false; value.deleted = true; value.nextRunAt = nil
            try saveAutomation(value)
            try event("automation.deleted", id.description)
            return value
        }
    }
    /// Explicit run-now/event requests carry a caller-generated key so lost SSH responses are
    /// retryable. A revision conflict is never silently interpreted against new instructions.
    public func runAutomation(_ id: AutomationID, expectedRevision: Int, key: String,
                              now: Date = Date()) throws -> ControllerAutomationRun {
        try Limits.text(key, field: "run_key", maximum: 160)
        return try db.transaction {
            var value = try automation(id)
            if let prior = try automationRun(id, key: "manual:" + key) {
                guard prior.revision == expectedRevision else { throw ControllerError.conflict }
                return prior
            }
            guard value.revision == expectedRevision, !value.deleted else { throw ControllerError.conflict }
            let run = try admitAutomation(&value, key: "manual:" + key, due: now, now: now, missed: false)
            try saveAutomation(value)
            return run
        }
    }
    /// Indexed due queue; at most 32 rules and one occurrence per rule in a sweep. Occurrence,
    /// work and next deadline commit together. Missed intervals never expand into a backlog.
    /// Each rule is admitted in its own savepoint: one that cannot be admitted rolls back alone,
    /// is retried later and leaves a durable event, rather than failing the sweep that also
    /// carries every other rule and the supervisor's launch pass.
    public func tickAutomations(now: Date = Date(), limit: Int = 32) throws -> [ControllerAutomationRun] {
        try Limits.page(0, limit)
        return try db.transaction {
            let rows = try db.rows("SELECT id FROM automation_due WHERE due<=? ORDER BY due,id LIMIT ?",
                [.integer(Self.milliseconds(now)), .integer(Int64(limit))])
            var result: [ControllerAutomationRun] = []
            for row in rows {
                let raw = try row.text(0)
                do {
                    if let run = try db.transaction({ try admitDue(raw, now: now) }) { result.append(run) }
                } catch {
                    try db.run("UPDATE automation_due SET due=? WHERE id=?",
                        [.integer(Self.milliseconds(now.addingTimeInterval(Self.failedAdmissionRetry))), .text(raw)])
                    try event("automation.admission_failed", raw)
                }
            }
            return result
        }
    }
    /// A run page is bounded by its encoded size as well as its count: each status carries the
    /// latest delivered result, and a page of long reports must still fit the owner transport.
    public func automationRuns(_ id: AutomationID, after: Int64 = 0, limit: Int = 50) throws -> ControllerPage<ControllerAutomationRunStatus> {
        try Limits.page(after, limit)
        let rows = try db.rows("SELECT sequence,payload FROM record WHERE kind='automationRun' AND parent=? AND sequence>? ORDER BY sequence LIMIT ?",
            [.text(id.description), .integer(after), .integer(Int64(limit))], pageByteLimit: 1_048_576)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var items: [ControllerAutomationRunStatus] = []
        var bytes = 0
        var next = after
        for row in rows {
            let status = try runStatus(try decode(row.text(1)))
            let size = try encoder.encode(status).count
            // The first item always fits: a run record and one bounded result stay far below this.
            guard items.isEmpty || bytes + size <= Self.runPageBytes else { break }
            bytes += size
            items.append(status)
            next = row.integers[0]
        }
        return ControllerPage(items: items, next: next)
    }
    private func runStatus(_ run: ControllerAutomationRun) throws -> ControllerAutomationRunStatus {
        let work = try run.workID.map { try self.work($0) }
        // Completion alone is insufficient: delivery must be confirmed and processes stopped.
        var archived = false
        if run.archiveOnSuccess, let work, work.state == .completed {
            let unresolvedDelivery = try db.rows("SELECT id FROM record WHERE kind='delivery' AND parent=? AND state!='delivered' LIMIT 1", [.text(work.id.description)])
            let unresolvedLaunch = try db.rows("SELECT id FROM record WHERE kind='launch' AND parent=? AND state IN ('prepared','dispatching','running') LIMIT 1", [.text(work.id.description)])
            archived = unresolvedDelivery.isEmpty && unresolvedLaunch.isEmpty
        }
        let delivery: WorkDelivery? = try run.workID.flatMap { id in
            guard let row = try db.rows("SELECT payload FROM record WHERE kind='delivery' AND parent=? ORDER BY sequence DESC LIMIT 1", [.text(id.description)]).first else { return nil }
            return try decode(row.text(0))
        }
        return ControllerAutomationRunStatus(run: run, workState: work?.state, archived: archived, result: delivery?.payload)
    }
    /// Retrying automation-owned work re-enters that automation's single slot. It is refused
    /// while a newer occurrence is still active, and afterwards a later occurrence sees the
    /// retried work as busy — so a retry can never run beside another occurrence.
    func claimAutomationSlot(for work: WorkItem) throws {
        guard work.key.hasPrefix(Self.workKeyPrefix) else { return }
        let rest = work.key.dropFirst(Self.workKeyPrefix.count)
        guard let colon = rest.firstIndex(of: ":"), let id = try? AutomationID(String(rest[..<colon])),
              var value: ControllerAutomation = try optional("automation", id.description) else { return }
        if let last = value.lastWorkID, last != work.id, try automationWorkIsActive(last) {
            throw ControllerError.conflict
        }
        value.lastWorkID = work.id
        try update("automation", id.description, value: value)
    }
    private func admitDue(_ raw: String, now: Date) throws -> ControllerAutomationRun? {
        var value = try automation(AutomationID(raw))
        guard value.enabled, !value.deleted, let due = value.nextRunAt, let schedule = value.spec.schedule else {
            // Pausing, deleting and unscheduling all clear the row; one left behind is inert.
            try db.run("DELETE FROM automation_due WHERE id=?", [.text(raw)])
            return nil
        }
        let late = now.timeIntervalSince(due) > 90
        let missed = late && value.spec.missedPolicy == .skip
        let key = "scheduled:\(value.revision):\(Self.milliseconds(due))"
        // A catch-up stands for the most recent occurrence it replaces, not the oldest it missed.
        let occurrence = late && !missed ? (try schedule.latest(onOrBefore: now) ?? due) : due
        let run = try admitAutomation(&value, key: key, due: occurrence, now: now, missed: missed)
        value.nextRunAt = try schedule.next(after: now)
        try saveAutomation(value)
        return run
    }
    private func automationRun(_ id: AutomationID, key: String) throws -> ControllerAutomationRun? {
        guard let row = try db.rows("SELECT payload FROM record WHERE kind='automationRun' AND parent=? AND key=? LIMIT 1",
            [.text(id.description), .text(key)]).first else { return nil }
        return try decode(row.text(0))
    }
    private func admitAutomation(_ value: inout ControllerAutomation, key: String, due: Date,
                                 now: Date, missed: Bool) throws -> ControllerAutomationRun {
        if let prior = try automationRun(value.id, key: key) { return prior }
        let busy = try value.lastWorkID.map(automationWorkIsActive) ?? false
        let work: WorkItem? = missed || busy ? nil : try enqueue(workerID: value.spec.workerID,
            key: Self.workKeyPrefix + "\(value.id):\(key)", instruction: value.spec.instruction, source: key.hasPrefix("manual:") ? .request : .schedule)
        if let work { value.lastWorkID = work.id }
        let run = ControllerAutomationRun(id: UUID(), automationID: value.id, revision: value.revision,
            key: key, scheduledAt: due, recordedAt: now, workID: work?.id,
            admission: missed ? "missed" : (busy ? "overlap" : "enqueued"), archiveOnSuccess: value.spec.archiveOnSuccess)
        try insert("automationRun", run.id.uuidString.lowercased(), parent: value.id.description, key: key, value: run)
        try event("automation.\(run.admission)", run.id.uuidString.lowercased())
        return run
    }
    private func automationWorkIsActive(_ id: WorkID) throws -> Bool {
        let work = try self.work(id)
        if work.state == .queued || work.state == .running || work.state == .waiting { return true }
        return try !db.rows("SELECT id FROM record WHERE kind='launch' AND parent=? AND state IN ('prepared','dispatching','running') LIMIT 1", [.text(id.description)]).isEmpty
    }
    private func saveAutomation(_ value: ControllerAutomation) throws {
        try update("automation", value.id.description, value: value)
        try db.run("DELETE FROM automation_due WHERE id=?", [.text(value.id.description)])
        if let due = value.nextRunAt {
            try db.run("INSERT INTO automation_due(id,due) VALUES(?,?)", [.text(value.id.description), .integer(Self.milliseconds(due))])
        }
    }
    private static func milliseconds(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1_000) }
    private static let workKeyPrefix = "automation:"
    /// A rule that could not be admitted is retried after this, not on every supervisor pass.
    static let failedAdmissionRetry: TimeInterval = 300
    /// Encoded bytes per run page, leaving room under the Mac's 2 MiB owner-transport capture.
    static let runPageBytes = 1_048_576
}

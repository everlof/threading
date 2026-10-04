import Foundation
import ThreadingDomain

// Trigger sources on a controller host: source → match → admit → run, with tokens spent only in
// the last step. A source is an owner-approved probe executable (TriggerProbe); a trigger is a
// typed AND rule over a source's events that admits `event` work for one worker. Event content is
// evidence carried in the work's request envelope, never configuration.

public enum SourceTag: Sendable {}
public enum TriggerRuleTag: Sendable {}
public typealias SourceID = ControllerID<SourceTag>
public typealias TriggerRuleID = ControllerID<TriggerRuleTag>

/// Owner-authored. Either an interval or a calendar schedule says when it polls.
public struct ControllerSourceSpec: Codable, Equatable, Sendable {
    public let name: String
    public let executable: String
    /// A script the executable interprets (`python3 probe.py`): hashed with the executable.
    public let script: String?
    public let arguments: [String]
    public let environment: [String: String]
    /// Environment name → secret name, resolved by the host at poll time. Never stored here.
    public let secrets: [String: String]
    public let intervalSeconds: Int?
    public let schedule: AutomationSchedule?
    public let timeoutSeconds: Int
    public let limit: Int

    public init(name: String, executable: String, script: String? = nil, arguments: [String] = [],
                environment: [String: String] = [:], secrets: [String: String] = [:], intervalSeconds: Int? = 600,
                schedule: AutomationSchedule? = nil, timeoutSeconds: Int = 30, limit: Int = 50) {
        self.name = name; self.executable = executable; self.script = script; self.arguments = arguments
        self.environment = environment; self.secrets = secrets; self.intervalSeconds = intervalSeconds
        self.schedule = schedule; self.timeoutSeconds = timeoutSeconds; self.limit = limit
    }
    public init(from decoder: any Decoder) throws {
        enum Keys: String, CodingKey { case name, executable, script, arguments, environment, secrets, intervalSeconds, schedule, timeoutSeconds, limit }
        let c = try decoder.container(keyedBy: Keys.self)
        name = try c.decode(String.self, forKey: .name)
        executable = try c.decode(String.self, forKey: .executable)
        script = try c.decodeIfPresent(String.self, forKey: .script)
        arguments = try c.decodeIfPresent([String].self, forKey: .arguments) ?? []
        environment = try c.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        secrets = try c.decodeIfPresent([String: String].self, forKey: .secrets) ?? [:]
        intervalSeconds = try c.decodeIfPresent(Int.self, forKey: .intervalSeconds)
        schedule = try c.decodeIfPresent(AutomationSchedule.self, forKey: .schedule)
        timeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? 30
        limit = try c.decodeIfPresent(Int.self, forKey: .limit) ?? 50
    }

    public func validate() throws {
        try Limits.text(name, field: "source_name", maximum: 128)
        for path in [executable] + (script.map { [$0] } ?? []) {
            try Limits.text(path, field: "source_path", maximum: 4096)
            guard path.hasPrefix("/") else { throw ControllerError.invalidInput("absolute_source_path") }
        }
        guard arguments.count <= 32, environment.count <= 64, secrets.count <= 16 else { throw ControllerError.invalidInput("source_size") }
        for value in arguments + Array(environment.values) { guard !value.contains("\0"), value.utf8.count <= 4096 else { throw ControllerError.invalidInput("source_value") } }
        for key in Array(environment.keys) + Array(secrets.keys) {
            guard !key.isEmpty, !key.contains("="), !key.contains("\0"), !key.hasPrefix("THREADING_") else { throw ControllerError.invalidInput("environment_key") }
        }
        for name in secrets.values { guard SecretName.isValid(name) else { throw ControllerError.invalidInput("secret_name") } }
        guard (intervalSeconds == nil) != (schedule == nil) else { throw ControllerError.invalidInput("source_timing") }
        if let intervalSeconds { guard (60...86_400).contains(intervalSeconds) else { throw ControllerError.invalidInput("interval") } }
        if let schedule { do { try schedule.validate() } catch { throw ControllerError.invalidInput("schedule") } }
        guard (1...Int(ProbeLimits.maximumTimeout)).contains(timeoutSeconds), (1...ProbeLimits.maximumEvents).contains(limit) else {
            throw ControllerError.invalidInput("source_bounds")
        }
    }
    /// The files whose content the approval names: the executable and the script it interprets.
    public var hashedPaths: [String] { [executable] + (script.map { [$0] } ?? []) }
}

public enum SecretName {
    public static func isValid(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 64 && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_-".contains($0)) }
    }
}

public enum SourceState: String, Codable, Sendable { case idle, healthy, backoff, authenticationNeeded, failed, changed }
public struct SourceHealth: Codable, Equatable, Sendable {
    public var state: SourceState
    public var failures: Int
    public var lastPollAt: String?
    public var detail: String?
    public var nextPollAt: String?
}

public struct ControllerSource: Codable, Equatable, Sendable {
    public let id: SourceID
    public let revision: Int
    public let spec: ControllerSourceSpec
    /// SHA-256 of the executable and script when this revision was configured.
    public let hash: String
    public let approvedHash: String?
    public let enabled: Bool
    public let deleted: Bool
    public internal(set) var cursor: String?
    public internal(set) var health: SourceHealth
}

public enum TriggerOperator: String, Codable, Sendable { case equals, notEquals, prefix, notPrefix, contains, exists, absent }
public struct TriggerClause: Codable, Equatable, Sendable {
    public let field: String
    public let op: TriggerOperator
    public let value: String?
    public init(field: String, op: TriggerOperator, value: String? = nil) { self.field = field; self.op = op; self.value = value }
    /// A missing field matches only `absent`; it never satisfies a negative test by accident.
    func matches(_ fields: [String: ProbeValue]) -> Bool {
        guard let actual = fields[field]?.text else { return op == .absent }
        let expected = value ?? ""
        switch op {
        case .equals: return actual == expected
        case .notEquals: return actual != expected
        case .prefix: return actual.hasPrefix(expected)
        case .notPrefix: return !actual.hasPrefix(expected)
        case .contains: return actual.contains(expected)
        case .exists: return true
        case .absent: return false
        }
    }
}
public struct ControllerTriggerSpec: Codable, Equatable, Sendable {
    public let name: String
    public let sourceID: SourceID
    public let workerID: WorkerID
    public let match: [TriggerClause]
    /// Host-authored instruction the admitted work starts from; the event travels as evidence.
    public let instruction: String
    public init(name: String, sourceID: SourceID, workerID: WorkerID, match: [TriggerClause], instruction: String) {
        self.name = name; self.sourceID = sourceID; self.workerID = workerID; self.match = match; self.instruction = instruction
    }
    func validate() throws {
        try Limits.text(name, field: "trigger_name", maximum: 128)
        try Limits.text(instruction, field: "instruction")
        guard match.count <= 16 else { throw ControllerError.invalidInput("match") }
        for clause in match {
            guard ProbeLimits.isFieldName(clause.field) else { throw ControllerError.invalidInput("match_field") }
            if [.exists, .absent].contains(clause.op) { guard clause.value == nil else { throw ControllerError.invalidInput("match_value") } }
            else { guard let value = clause.value, value.utf8.count <= ProbeLimits.fieldBytes else { throw ControllerError.invalidInput("match_value") } }
        }
    }
}
public struct ControllerTrigger: Codable, Equatable, Sendable {
    public let id: TriggerRuleID
    public let revision: Int
    public let spec: ControllerTriggerSpec
    public let enabled: Bool
    public let deleted: Bool
}

public enum TriggerAdmission: String, Codable, Sendable { case queued, notMatched, refused }
public struct TriggerReceipt: Codable, Equatable, Sendable {
    public let triggerID: TriggerRuleID
    public let admission: TriggerAdmission
    public let workID: WorkID?
    public let reason: String?
}
public struct SourceEvent: Codable, Equatable, Sendable {
    public let sourceID: SourceID
    public let event: ProbeEvent
    public let receivedAt: String
    public let receipts: [TriggerReceipt]
}

/// The immutable request a matched event's work carries: which source, and its evidence.
public struct TriggerWorkRequest: Codable, Sendable {
    public let kind: String
    public let source: String
    public let trigger: String
    public let event: ProbeEvent
}

/// Bounds on what one poll may admit. See `recordPoll`.
public enum TriggerAdmissionLimits {
    /// Events stored (with their admissions) per write transaction.
    public static let eventsPerCommit = 25
    /// Tasks admitted per write transaction before it commits (an event's own matches are
    /// never split, so a commit admits fewer than this plus one event's triggers).
    public static let admissionsPerCommit = 20
    /// Tasks one poll may admit across all of a source's triggers.
    public static let admissionsPerPoll = 100
    /// Queued, unclaimed tasks one trigger may hold; a match beyond it is refused.
    public static let backlogPerTrigger = 50
    /// How soon a poll that left events for later runs again (the shortest polling interval).
    public static let deferredPollDelay: TimeInterval = 60
    public static let backlogReason = "backlog"
    static func scope(_ trigger: TriggerRuleID) -> String { "trigger:\(trigger)" }
}
struct TriggerPollAdmission {
    var admitted = 0
    var deferred = false
    var backlog: [TriggerRuleID: Int] = [:]
}

/// What one poll needs: exactly the approved revision's spec, with the hash to verify first.
public struct SourcePollIntent: Codable, Sendable {
    public let source: ControllerSource
    public let directory: String
}

extension ControllerStore {
    // MARK: - Sources

    /// Configuring always pauses and clears approval: a person approves what will run.
    public func configureSource(_ id: SourceID, expectedRevision: Int, spec: ControllerSourceSpec) throws -> ControllerSource {
        try spec.validate()
        let hash: String
        do { hash = try TriggerProbe.contentHash(of: spec.hashedPaths) } catch { throw ControllerError.invalidInput("source_unreadable") }
        return try db.transaction {
            let prior: ControllerSource? = try optional("source", id.description)
            guard (prior?.revision ?? 0) == expectedRevision, prior?.deleted != true else { throw ControllerError.conflict }
            let value = ControllerSource(id: id, revision: expectedRevision + 1, spec: spec, hash: hash, approvedHash: nil,
                                         enabled: false, deleted: false, cursor: prior?.cursor,
                                         health: SourceHealth(state: .idle, failures: 0))
            try saveSource(value, new: prior == nil)
            try db.run("DELETE FROM source_due WHERE id=?", [.text(id.description)])
            try event("source.configured", id.description)
            return value
        }
    }
    /// The approver names the hash they reviewed; it must be the configured one and still match
    /// the files on disk now.
    public func approveSource(_ id: SourceID, expectedRevision: Int, hash: String) throws -> ControllerSource {
        let source = try requireSource(id)
        let current: String
        do { current = try TriggerProbe.contentHash(of: source.spec.hashedPaths) } catch { throw ControllerError.invalidInput("source_unreadable") }
        return try db.transaction {
            let prior = try requireSource(id)
            guard prior.revision == expectedRevision, !prior.deleted, prior.hash == hash, current == hash else { throw ControllerError.conflict }
            var health = prior.health
            if health.state == .changed { health.state = .idle }
            let value = ControllerSource(id: id, revision: prior.revision + 1, spec: prior.spec, hash: prior.hash, approvedHash: hash,
                                         enabled: prior.enabled, deleted: false, cursor: prior.cursor, health: health)
            try saveSource(value, new: false)
            try event("source.approved", id.description)
            return value
        }
    }
    public func setSourceEnabled(_ id: SourceID, expectedRevision: Int, enabled: Bool) throws -> ControllerSource {
        try db.transaction {
            let prior = try requireSource(id)
            guard prior.revision == expectedRevision, !prior.deleted else { throw ControllerError.conflict }
            if enabled { guard prior.approvedHash == prior.hash else { throw ControllerError.forbidden } }
            let value = ControllerSource(id: id, revision: prior.revision + 1, spec: prior.spec, hash: prior.hash, approvedHash: prior.approvedHash,
                                         enabled: enabled, deleted: false, cursor: prior.cursor, health: prior.health)
            try saveSource(value, new: false)
            if enabled { try schedulePoll(id, at: Date()) } else { try db.run("DELETE FROM source_due WHERE id=?", [.text(id.description)]) }
            try event(enabled ? "source.enabled" : "source.paused", id.description)
            return value
        }
    }
    public func deleteSource(_ id: SourceID, expectedRevision: Int) throws -> ControllerSource {
        try db.transaction {
            let prior = try requireSource(id)
            guard prior.revision == expectedRevision else { throw ControllerError.conflict }
            let value = ControllerSource(id: id, revision: prior.revision + 1, spec: prior.spec, hash: prior.hash, approvedHash: nil,
                                         enabled: false, deleted: true, cursor: prior.cursor, health: prior.health)
            try saveSource(value, new: false)
            try db.run("DELETE FROM source_due WHERE id=?", [.text(id.description)])
            try event("source.deleted", id.description)
            return value
        }
    }
    public func source(_ id: SourceID) throws -> ControllerSource { try requireSource(id) }
    public func sources(after: Int64 = 0, limit: Int = 50) throws -> ControllerPage<ControllerSource> {
        try page("source", after: after, limit: limit)
    }
    public func sourceEvents(_ id: SourceID, after: Int64 = 0, limit: Int = 50) throws -> ControllerPage<SourceEvent> {
        try page("sourceEvent", parent: id.description, after: after, limit: limit)
    }

    /// Enabled, approved sources whose poll is due, oldest deadline first.
    public func dueSources(now: Date = Date(), limit: Int = 8) throws -> [ControllerSource] {
        let rows = try db.rows("SELECT id FROM source_due WHERE due<=? ORDER BY due,id LIMIT ?",
                               [.integer(Int64(now.timeIntervalSince1970)), .integer(Int64(min(limit, 100)))])
        return try rows.map { try requireSource(SourceID($0.text(0))) }
    }
    /// Claims the next deadline before the poll runs, so a crash mid-poll waits one interval
    /// rather than polling in a tight loop.
    public func beginPoll(_ id: SourceID, manual: Bool = false) throws -> ControllerSource {
        try db.transaction {
            let source = try requireSource(id)
            guard !source.deleted, source.approvedHash == source.hash, manual || source.enabled else { throw ControllerError.conflict }
            if source.enabled { try schedulePoll(id, at: try nextPoll(source, after: Date(), failures: 0)) }
            return source
        }
    }

    /// Records one poll: verifies the files still match the approval, stores new events once,
    /// admits work for every enabled trigger they match, then moves the cursor.
    ///
    /// Admission is bounded three ways (`TriggerAdmissionLimits`): events commit in short chunks
    /// so the write lock is held briefly; a trigger whose queued backlog is at its ceiling
    /// records `refused: backlog` instead of queueing; and once a poll has admitted its cap,
    /// the remaining events are not recorded and the cursor stays where it was, so the probe
    /// redelivers them to a prompt follow-up poll. A crash between chunks leaves the cursor
    /// unmoved; redelivered events already stored are skipped by their (id, revision) key.
    public func recordPoll(_ id: SourceID, revision: Int, observedHash: String?, run: ProbeRun) throws -> [SourceEvent] {
        let initial = try requireSource(id)
        guard initial.revision == revision, !initial.deleted, initial.approvedHash == initial.hash else { throw ControllerError.conflict }
        var recorded: [SourceEvent] = []
        var admission = TriggerPollAdmission()
        if run.outcome == .healthy, observedHash == initial.approvedHash {
            let events = Array(run.events.prefix(initial.spec.limit))
            var index = 0
            while index < events.count, !admission.deferred {
                try db.transaction {
                    let source = try requireSource(id)
                    guard source.revision == revision, !source.deleted, source.approvedHash == source.hash else { throw ControllerError.conflict }
                    let triggers = try activeTriggers(source.id)
                    let end = min(index + TriggerAdmissionLimits.eventsPerCommit, events.count)
                    let admittedBefore = admission.admitted
                    while index < end, admission.admitted - admittedBefore < TriggerAdmissionLimits.admissionsPerCommit {
                        guard let outcome = try recordEvent(events[index], source: source, triggers: triggers, admission: &admission) else { break }
                        if let stored = outcome { recorded.append(stored) }
                        index += 1
                    }
                }
            }
        }
        return try db.transaction {
            var source = try requireSource(id)
            guard source.revision == revision, !source.deleted, source.approvedHash == source.hash else { throw ControllerError.conflict }
            let now = Date()
            source.health.lastPollAt = Self.now()
            if observedHash != source.approvedHash {
                // Edited since approval: stop until a person approves the new content.
                source.health.state = .changed
                source.health.detail = "The probe changed since it was approved."
                source.health.nextPollAt = nil
                try update("source", id.description, state: "changed", value: source)
                try db.run("DELETE FROM source_due WHERE id=?", [.text(id.description)])
                try event("source.changed", id.description)
                return []
            }
            switch run.outcome {
            case .healthy:
                // Deferred events are redelivered from the unmoved cursor.
                if !admission.deferred { source.cursor = run.cursor }
                source.health.state = .healthy
                source.health.failures = 0
                source.health.detail = admission.deferred
                    ? "Admitted \(admission.admitted) tasks, the most one poll may; later events wait for the next poll."
                    : (run.diagnostics.isEmpty ? nil : String(run.diagnostics.prefix(1_024)))
            case .backoff, .authenticationNeeded, .failed:
                source.health.state = run.outcome == .backoff ? .backoff : run.outcome == .authenticationNeeded ? .authenticationNeeded : .failed
                source.health.failures += 1
                source.health.detail = String(run.diagnostics.prefix(1_024))
            }
            if source.enabled {
                var next = try nextPoll(source, after: now, failures: source.health.failures)
                if admission.deferred { next = min(next, now.addingTimeInterval(TriggerAdmissionLimits.deferredPollDelay)) }
                source.health.nextPollAt = ISO8601DateFormatter().string(from: next)
                try schedulePoll(id, at: next)
            }
            try update("source", id.description, state: source.health.state.rawValue, value: source)
            try event("source.polled", id.description)
            return recorded
        }
    }

    private func activeTriggers(_ source: SourceID) throws -> [ControllerTrigger] {
        let rows = try db.rows("SELECT payload FROM record WHERE kind='trigger' AND parent=? AND json_extract(payload,'$.enabled')=1 AND json_extract(payload,'$.deleted')=0 ORDER BY sequence LIMIT 101",
                               [.text(source.description)])
        guard rows.count <= 100 else { throw ControllerError.invalidInput("active_trigger_limit") }
        return try rows.map { row -> ControllerTrigger in try decode(row.text(0)) }.filter { $0.enabled && !$0.deleted }
    }

    /// Nil: the poll's admission cap is reached and this event is left for the next poll.
    /// `.some(nil)`: already stored. `.some(event)`: stored now, with one receipt per trigger.
    private func recordEvent(_ probeEvent: ProbeEvent, source: ControllerSource, triggers: [ControllerTrigger],
                             admission: inout TriggerPollAdmission) throws -> SourceEvent?? {
        let key = "\(probeEvent.id)\u{1f}\(probeEvent.revision)"
        if try !db.rows("SELECT id FROM record WHERE kind='sourceEvent' AND parent=? AND key=? LIMIT 1",
                        [.text(source.id.description), .text(key)]).isEmpty { return .some(nil) }
        let matched = Set(triggers.filter { trigger in trigger.spec.match.allSatisfy { $0.matches(probeEvent.fields) } }.map(\.id))
        // Checked per event, so a poll admits at most max(cap, active triggers) tasks and
        // always makes progress.
        if admission.admitted > 0, admission.admitted + matched.count > TriggerAdmissionLimits.admissionsPerPoll {
            admission.deferred = true
            return nil
        }
        let recordID = UUID().uuidString.lowercased()
        var receipts: [TriggerReceipt] = []
        for trigger in triggers {
            guard matched.contains(trigger.id) else {
                receipts.append(TriggerReceipt(triggerID: trigger.id, admission: .notMatched, workID: nil, reason: nil)); continue
            }
            let scope = TriggerAdmissionLimits.scope(trigger.id)
            let backlog = try admission.backlog[trigger.id] ?? queuedBacklog(scope)
            admission.backlog[trigger.id] = backlog
            guard backlog < TriggerAdmissionLimits.backlogPerTrigger else {
                receipts.append(TriggerReceipt(triggerID: trigger.id, admission: .refused, workID: nil,
                                               reason: TriggerAdmissionLimits.backlogReason)); continue
            }
            let request = TriggerWorkRequest(kind: "threading.trigger-event", source: source.spec.name, trigger: trigger.spec.name, event: probeEvent)
            do {
                let work = try db.transaction {
                    try enqueue(workerID: trigger.spec.workerID, key: "trigger:\(trigger.id):\(recordID)",
                                instruction: trigger.spec.instruction, request: try encode(request), source: .event,
                                after: [], scope: scope)
                }
                admission.admitted += 1
                admission.backlog[trigger.id] = backlog + 1
                receipts.append(TriggerReceipt(triggerID: trigger.id, admission: .queued, workID: work.id, reason: nil))
            } catch let error as ControllerError {
                if case .storage = error { throw error }
                receipts.append(TriggerReceipt(triggerID: trigger.id, admission: .refused, workID: nil, reason: error.description))
            }
        }
        let value = SourceEvent(sourceID: source.id, event: probeEvent, receivedAt: Self.now(), receipts: receipts)
        try insert("sourceEvent", recordID, parent: source.id.description, key: key, value: value)
        try event("source.event", source.id.description)
        return .some(value)
    }
    /// Queued (unclaimed) work one trigger admitted, read from the scope/state index and
    /// stopped at the ceiling: O(ceiling), independent of completed history.
    private func queuedBacklog(_ scope: String) throws -> Int {
        let rows = try db.rows("""
            SELECT COUNT(*) FROM (SELECT 1 FROM record INDEXED BY record_scope_state
            WHERE kind='work' AND scope=? AND state='queued' LIMIT ?)
            """, [.text(scope), .integer(Int64(TriggerAdmissionLimits.backlogPerTrigger))])
        return Int(rows.first?.integers[0] ?? 0)
    }

    private func nextPoll(_ source: ControllerSource, after date: Date, failures: Int) throws -> Date {
        if let schedule = source.spec.schedule {
            guard failures > 0 else {
                do { return try schedule.next(after: date) } catch { throw ControllerError.invalidInput("schedule") }
            }
        }
        let base = TimeInterval(source.spec.intervalSeconds ?? 600)
        guard failures > 0 else { return date.addingTimeInterval(base) }
        // Exponential backoff to an hour, so a failing source cannot hammer its endpoint.
        return date.addingTimeInterval(min(base * pow(2, Double(min(failures, 10))), 3_600))
    }
    private func schedulePoll(_ id: SourceID, at date: Date) throws {
        try db.run("INSERT INTO source_due(id,due) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET due=excluded.due",
                   [.text(id.description), .integer(Int64(date.timeIntervalSince1970))])
    }
    private func requireSource(_ id: SourceID) throws -> ControllerSource { try required("source", id.description) }
    private func saveSource(_ value: ControllerSource, new: Bool) throws {
        if new { try insert("source", value.id.description, state: value.health.state.rawValue, value: value) }
        else { try update("source", value.id.description, state: value.health.state.rawValue, value: value) }
    }

    // MARK: - Triggers

    /// Always paused on configure. Enabling needs the worker to accept `event` work.
    public func configureTrigger(_ id: TriggerRuleID, expectedRevision: Int, spec: ControllerTriggerSpec) throws -> ControllerTrigger {
        try spec.validate()
        return try db.transaction {
            _ = try requireSource(spec.sourceID)
            let _: ControllerWorker = try required("worker", spec.workerID.description)
            let prior: ControllerTrigger? = try optional("trigger", id.description)
            guard (prior?.revision ?? 0) == expectedRevision, prior?.deleted != true else { throw ControllerError.conflict }
            if let prior, prior.spec.sourceID != spec.sourceID { throw ControllerError.invalidInput("trigger_source") }
            let value = ControllerTrigger(id: id, revision: expectedRevision + 1, spec: spec, enabled: false, deleted: false)
            if prior == nil { try insert("trigger", id.description, parent: spec.sourceID.description, value: value) }
            else { try update("trigger", id.description, value: value) }
            try event("trigger.configured", id.description)
            return value
        }
    }
    public func setTriggerEnabled(_ id: TriggerRuleID, expectedRevision: Int, enabled: Bool) throws -> ControllerTrigger {
        try db.transaction {
            let prior: ControllerTrigger = try required("trigger", id.description)
            guard prior.revision == expectedRevision, !prior.deleted else { throw ControllerError.conflict }
            if enabled { try requireWorkSource(prior.spec.workerID, source: .event) }
            if enabled && !prior.enabled {
                let active = try db.rows("SELECT id FROM record WHERE kind='trigger' AND parent=? AND json_extract(payload,'$.enabled')=1 AND json_extract(payload,'$.deleted')=0 LIMIT 100",
                                         [.text(prior.spec.sourceID.description)])
                guard active.count < 100 else { throw ControllerError.invalidInput("active_trigger_limit") }
            }
            let value = ControllerTrigger(id: id, revision: prior.revision + 1, spec: prior.spec, enabled: enabled, deleted: false)
            try update("trigger", id.description, value: value)
            try event(enabled ? "trigger.enabled" : "trigger.paused", id.description)
            return value
        }
    }
    public func deleteTrigger(_ id: TriggerRuleID, expectedRevision: Int) throws -> ControllerTrigger {
        try db.transaction {
            let prior: ControllerTrigger = try required("trigger", id.description)
            guard prior.revision == expectedRevision else { throw ControllerError.conflict }
            let value = ControllerTrigger(id: id, revision: prior.revision + 1, spec: prior.spec, enabled: false, deleted: true)
            try update("trigger", id.description, value: value)
            try event("trigger.deleted", id.description)
            return value
        }
    }
    public func trigger(_ id: TriggerRuleID) throws -> ControllerTrigger { try required("trigger", id.description) }
    public func triggers(source: SourceID, after: Int64 = 0, limit: Int = 50) throws -> ControllerPage<ControllerTrigger> {
        try page("trigger", parent: source.description, after: after, limit: limit)
    }
}

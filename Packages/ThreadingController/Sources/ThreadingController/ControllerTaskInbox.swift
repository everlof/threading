import Foundation

public struct WorkMessage: Codable, Equatable, Sendable {
    public let id: UUID
    public let workID: WorkID
    public let author: String
    public let text: String
    public let at: String
    public internal(set) var consumedBy: ExecutionID?
}
public struct WorkActivity: Codable, Equatable, Sendable {
    public let workID: WorkID
    public let workerID: WorkerID
    public let executionID: ExecutionID?
    public let kind: String
    public let source: String
    public let text: String?
    public let at: String
}

extension ControllerStore {
    /// Owner-authenticated append; a message cannot grant tools or start a completed task.
    public func message(workID: WorkID, id: UUID, author: String, text: String) throws -> WorkMessage {
        try Limits.recipient(author, prefix: "person:")
        try Limits.text(text, field: "message")
        return try db.transaction {
            if let previous: WorkMessage = try optional("message", id.uuidString) {
                guard previous.workID == workID, previous.author == author, previous.text == text else { throw ControllerError.conflict }
                return previous
            }
            let work = try work(workID)
            guard work.state != .completed, work.state != .cancelled else { throw ControllerError.conflict }
            let value = WorkMessage(id: id, workID: workID, author: author, text: text,
                at: ISO8601DateFormatter().string(from: Date()), consumedBy: nil)
            try insert("message", id.uuidString, parent: workID.description, state: "pending", value: value)
            try event("work.message_received", workID.description)
            return value
        }
    }
    public func messages(workID: WorkID, after: Int64 = 0, limit: Int = 20) throws -> ControllerPage<WorkMessage> {
        try page("message", parent: workID.description, after: after, limit: limit)
    }
    /// Explicit receipt, separate from reading. Old executions cannot consume newer messages.
    public func consumeMessage(executionID: ExecutionID, id: UUID) throws -> WorkMessage {
        try db.transaction {
            let (work, _) = try running(executionID)
            var value: WorkMessage = try required("message", id.uuidString)
            guard value.workID == work.id else { throw ControllerError.forbidden }
            if value.consumedBy != nil { return value }
            value.consumedBy = executionID
            try update("message", id.uuidString, state: "consumed", value: value)
            try event("work.message_consumed", work.id.description)
            return value
        }
    }
    public func activities(workID: WorkID, after: Int64 = 0, limit: Int = 20) throws -> ControllerPage<WorkActivity> {
        try page("activity", parent: workID.description, after: after, limit: limit)
    }
    func recordActivity(kind: String, subject: String, text: String?, source: String) throws {
        let family = String(kind.prefix(while: { $0 != "." }))
        let work: WorkItem?
        var executionID: ExecutionID?
        switch family {
        case "work": work = try optional("work", subject)
        case "execution":
            let value: ControllerExecution? = try optional("execution", subject)
            work = try value.map { try self.work($0.workID) }; executionID = value?.id
        case "launch":
            let value: ControllerLaunch? = try optional("launch", subject)
            work = try value.map { try self.work($0.workID) }; executionID = value?.executionID
        case "question":
            let value: WorkQuestion? = try optional("question", subject)
            work = try value.map { try self.work($0.workID) }; executionID = value?.executionID
        case "delivery":
            let value: WorkDelivery? = try optional("delivery", subject)
            work = try value.map { try self.work($0.workID) }
        default: return
        }
        guard let work else { return }
        let value = WorkActivity(workID: work.id, workerID: work.workerID,
            executionID: executionID ?? work.executionID, kind: kind, source: source, text: text,
            at: ISO8601DateFormatter().string(from: Date()))
        try insert("activity", UUID().uuidString, parent: work.id.description, scope: work.workerID.description, value: value)
    }
    /// Cancellation requires positive process reconciliation first. It never invents an exit.
    public func cancel(workID: WorkID) throws -> WorkItem {
        try db.transaction {
            var work = try work(workID)
            if work.state == .cancelled { return work }
            guard work.state != .completed, work.state != .running,
                  try db.rows("SELECT id FROM record WHERE kind='launch' AND parent=? AND state IN ('prepared','dispatching','running') LIMIT 1", [.text(workID.description)]).isEmpty else {
                throw ControllerError.conflict
            }
            work.state = .cancelled
            try saveWork(work)
            try db.run("UPDATE record SET state='cancelled' WHERE kind='question' AND parent=? AND state='open'", [.text(workID.description)])
            try event("work.cancelled", workID.description)
            return work
        }
    }
    public func archiveWorker(_ id: WorkerID) throws -> ControllerWorker {
        try db.transaction {
            let worker: ControllerWorker = try required("worker", id.description)
            let prior: Bool? = try optional("workerArchived", id.description)
            if prior == true { return worker }
            guard try db.rows("SELECT id FROM record WHERE kind='work' AND parent=? AND state IN ('queued','running','waiting','interrupted') LIMIT 1", [.text(id.description)]).isEmpty,
                  try db.rows("SELECT id FROM record WHERE kind='launch' AND scope=? AND state IN ('prepared','dispatching','running') LIMIT 1", [.text(id.description)]).isEmpty else { throw ControllerError.conflict }
            guard try db.rows("SELECT id FROM record WHERE kind='automation' AND json_extract(payload,'$.enabled')=1 AND json_extract(payload,'$.spec.workerID')=? LIMIT 1", [.text(id.description)]).isEmpty else { throw ControllerError.conflict }
            if let policy = try workerPolicy(id) { _ = try setWorkerEnabled(id, expectedRevision: policy.revision, enabled: false) }
            try insert("workerArchived", id.description, value: true)
            try event("worker.archived", id.description)
            return worker
        }
    }
    func requireActiveWorker(_ id: WorkerID) throws {
        let archived: Bool? = try optional("workerArchived", id.description)
        guard archived != true else { throw ControllerError.conflict }
    }
}

public struct WorkerSources: Codable, Equatable, Sendable {
    public let workerID: WorkerID
    public let revision: Int
    public let sources: [WorkSource]
}
extension ControllerStore {
    public func workerSources(_ id: WorkerID) throws -> WorkerSources? { try optional("workerSources", id.description) }
    public func setWorkerSources(_ id: WorkerID, expectedRevision: Int, sources: [WorkSource]) throws -> WorkerSources {
        guard !sources.isEmpty, sources.count <= WorkSource.allCases.count,
              Set(sources).count == sources.count, expectedRevision >= 0, expectedRevision < Int.max else { throw ControllerError.invalidInput("work_sources") }
        return try db.transaction {
            let _: ControllerWorker = try required("worker", id.description)
            try requireActiveWorker(id)
            let previous = try workerSources(id)
            guard (previous?.revision ?? 0) == expectedRevision else { throw ControllerError.conflict }
            let value = WorkerSources(workerID: id, revision: expectedRevision + 1, sources: sources)
            if previous == nil { try insert("workerSources", id.description, value: value) }
            else { try update("workerSources", id.description, value: value) }
            try event("worker.sources_changed", id.description)
            return value
        }
    }
    func requireWorkSource(_ id: WorkerID, source: WorkSource) throws {
        // Existing owner-configured workers retain their established sources across migration.
        if let policy = try workerSources(id), !policy.sources.contains(source) { throw ControllerError.forbidden }
    }
}

import Foundation

/// Persistent work, independent of agent processes. There is deliberately no provider, SSH,
/// application database, email address, or deployment policy here.
public actor ControllerStore {
    let db: ControllerDatabase
    public init(path: String) throws { db = try ControllerDatabase(path: path) }

    public func addWorker(id: WorkerID, name: String) throws -> ControllerWorker {
        try Limits.text(name, field: "name", maximum: 256)
        return try db.transaction {
            let worker = ControllerWorker(id: id, name: name)
            if let prior: ControllerWorker = try optional("worker", id.description) {
                guard prior == worker else { throw ControllerError.conflict }
                return prior
            }
            try insert("worker", id.description, value: worker)
            try event("worker.created", id.description)
            return worker
        }
    }

    /// The source supplies a stable key. Reusing it with different content is a conflict.
    public func enqueue(workerID: WorkerID, key: String, instruction: String, request: String? = nil, source: WorkSource = .request) throws -> WorkItem {
        try Limits.text(key, field: "key", maximum: 256)
        try Limits.text(instruction, field: "instruction")
        if let request { try Limits.text(request, field: "request") }
        return try db.transaction {
            let _: ControllerWorker = try required("worker", workerID.description)
            try requireActiveWorker(workerID)
            try requireWorkSource(workerID, source: source)
            if let row = try db.rows("SELECT payload FROM record WHERE kind='work' AND parent=? AND key=? LIMIT 1",
                                     [.text(workerID.description), .text(key)]).first {
                let existing: WorkItem = try decode(row.text(0))
                guard existing.instruction == instruction, existing.request == request, (existing.source ?? .request) == source else { throw ControllerError.conflict }
                return existing
            }
            let work = WorkItem(id: WorkID(), workerID: workerID, key: key, instruction: instruction,
                                request: request, source: source, state: .queued, checkpoint: "", executionID: nil)
            try insert("work", work.id.description, parent: workerID.description, key: key,
                       state: work.state.rawValue, value: work)
            try event("work.queued", work.id.description)
            return work
        }
    }

    /// Claim is atomic across processes. A running item is never claimed a second time.
    public func claim(workerID: WorkerID) throws -> WorkClaim? {
        try db.transaction {
            let _: ControllerWorker = try required("worker", workerID.description)
            try requireActiveWorker(workerID)
            guard let row = try db.rows("""
                SELECT payload FROM record AS work WHERE kind='work' AND parent=? AND state='queued'
                AND NOT EXISTS (SELECT 1 FROM record AS launch WHERE launch.kind='launch'
                    AND launch.parent=work.id AND launch.state IN ('prepared','dispatching','running'))
                ORDER BY sequence LIMIT 1
                """,
                                       [.text(workerID.description)]).first else { return nil }
            var work: WorkItem = try decode(row.text(0))
            let execution = ControllerExecution(id: ExecutionID(), workID: work.id, state: .running)
            work.state = .running
            work.executionID = execution.id
            try insert("execution", execution.id.description, parent: work.id.description,
                       state: execution.state.rawValue, value: execution)
            try saveWork(work)
            try event("execution.claimed", execution.id.description)
            return WorkClaim(work: work, execution: execution)
        }
    }

    public func checkpoint(executionID: ExecutionID, text: String) throws -> WorkItem {
        try Limits.text(text, field: "checkpoint")
        return try db.transaction {
            var (work, _) = try running(executionID)
            work.checkpoint = text
            try saveWork(work)
            try event("work.checkpointed", work.id.description, text: text, source: "agent")
            return work
        }
    }

    /// Commits the question and checkpoint and yields this execution in ONE transaction.
    /// No synchronous wait and no process required to keep the question alive.
    public func ask(executionID: ExecutionID, id: QuestionID, recipients: [String],
                    text: String, checkpoint: String) throws -> WorkQuestion {
        try Limits.text(text, field: "question")
        try Limits.text(checkpoint, field: "checkpoint")
        guard (1...32).contains(recipients.count), Set(recipients).count == recipients.count else {
            throw ControllerError.invalidInput("recipients")
        }
        for recipient in recipients { try Limits.recipient(recipient) }
        return try db.transaction {
            // A retry after losing the response returns the original committed question.
            if let prior: WorkQuestion = try optional("question", id.description) {
                guard prior.executionID == executionID, prior.text == text,
                      prior.recipients == recipients, prior.checkpoint == checkpoint else { throw ControllerError.conflict }
                return prior
            }
            var (work, execution) = try running(executionID)
            let question = WorkQuestion(id: id, workID: work.id, executionID: executionID,
                                        recipients: recipients, text: text, checkpoint: checkpoint, answer: nil, answeredBy: nil)
            work.checkpoint = checkpoint
            work.state = .waiting
            work.executionID = nil
            execution.state = .yielded
            try insert("question", id.description, parent: work.id.description, state: "open", scope: work.workerID.description, value: question)
            try saveWork(work)
            try saveExecution(execution)
            try event("question.opened", id.description)
            return question
        }
    }

    /// First authorized answer wins. An answer supplies information, never a permission grant.
    public func answer(questionID: QuestionID, principal: AnswerPrincipal, text: String) throws -> WorkQuestion {
        try Limits.text(text, field: "answer")
        return try db.transaction {
            var question: WorkQuestion = try required("question", questionID.description)
            guard question.recipients.contains(principal.person) ||
                    !principal.groups.isDisjoint(with: question.recipients) else { throw ControllerError.forbidden }
            if question.answer != nil {
                guard question.answer == text, question.answeredBy == principal.person else { throw ControllerError.conflict }
                return question
            }
            var work: WorkItem = try required("work", question.workID.description)
            guard work.state == .waiting else { throw ControllerError.conflict }
            question.answer = text
            question.answeredBy = principal.person
            work.state = .queued
            try update("question", questionID.description, state: "answered", value: question)
            try saveWork(work)
            try event("question.answered", questionID.description)
            try event("work.queued", work.id.description)
            return question
        }
    }

    /// Completion produces a durable outbox entry. It does not claim external delivery.
    public func finish(executionID: ExecutionID, destination: String, payload: String) throws -> WorkDelivery {
        try Limits.text(destination, field: "destination", maximum: 256)
        try Limits.text(payload, field: "payload")
        return try db.transaction {
            let prior: ControllerExecution = try required("execution", executionID.description)
            if prior.state == .completed {
                guard let row = try db.rows("SELECT payload FROM record WHERE kind='delivery' AND parent=? AND key=? LIMIT 1",
                                            [.text(prior.workID.description), .text(executionID.description)]).first else {
                    throw ControllerError.conflict
                }
                let delivery: WorkDelivery = try decode(row.text(0))
                guard delivery.destination == destination, delivery.payload == payload else { throw ControllerError.conflict }
                return delivery
            }
            var (work, execution) = try running(executionID)
            guard try db.rows("SELECT id FROM record WHERE kind='message' AND parent=? AND state='pending' LIMIT 1", [.text(work.id.description)]).isEmpty else {
                throw ControllerError.conflict // Consume messages received before completion, or ask a question.
            }
            let delivery = WorkDelivery(id: DeliveryID(), workID: work.id, destination: destination,
                                        payload: payload, state: .pending, attemptID: nil, receipt: nil)
            work.state = .completed
            work.executionID = nil
            execution.state = .completed
            try insert("delivery", delivery.id.description, parent: work.id.description, key: executionID.description,
                       state: delivery.state.rawValue, value: delivery)
            try saveWork(work)
            try saveExecution(execution)
            try event("delivery.pending", delivery.id.description)
            try event("work.completed", work.id.description)
            return delivery
        }
    }

    /// An operator/runtime must first establish that this execution has stopped. No timed-out
    /// lease automatically starts a second process that could repeat an external effect.
    public func interrupt(executionID: ExecutionID) throws -> WorkItem {
        try db.transaction {
            var (work, execution) = try running(executionID)
            work.state = .interrupted
            work.executionID = nil
            execution.state = .interrupted
            try saveWork(work)
            try saveExecution(execution)
            try event("execution.interrupted", executionID.description)
            return work
        }
    }
    public func retry(workID: WorkID) throws -> WorkItem {
        try db.transaction {
            var work: WorkItem = try required("work", workID.description)
            guard work.state == .interrupted else { throw ControllerError.conflict }
            try claimAutomationSlot(for: work)
            work.state = .queued
            try saveWork(work)
            try event("work.queued", workID.description)
            return work
        }
    }

    public func workers(after: Int64 = 0, limit: Int = 50) throws -> ControllerPage<ControllerWorker> {
        try page("worker", after: after, limit: limit)
    }

    public func work(_ id: WorkID) throws -> WorkItem { try required("work", id.description) }
    public func questions(workID: WorkID, after: Int64 = 0, limit: Int = 50) throws -> ControllerPage<WorkQuestion> {
        try page("question", parent: workID.description, after: after, limit: limit)
    }
    public func works(workerID: WorkerID, after: Int64 = 0, limit: Int = 50) throws -> ControllerPage<WorkItem> {
        try page("work", parent: workerID.description, after: after, limit: limit)
    }
    public func deliveries(after: Int64 = 0, limit: Int = 50) throws -> ControllerPage<WorkDelivery> {
        try page("delivery", after: after, limit: limit)
    }
    public func events(after: Int64 = 0, limit: Int = 50) throws -> ControllerPage<ControllerEvent> {
        try Limits.page(after, limit)
        let rows = try db.rows("SELECT sequence,kind,subject,at FROM event WHERE sequence>? ORDER BY sequence LIMIT ?",
                              [.integer(after), .integer(Int64(limit))])
        let events = try rows.map { row in
            ControllerEvent(sequence: row.integers[0], kind: try row.text(1), subject: try row.text(2), at: try row.text(3))
        }
        return ControllerPage(items: events, next: rows.last?.integers[0] ?? after)
    }

    func running(_ id: ExecutionID) throws -> (WorkItem, ControllerExecution) {
        let execution: ControllerExecution = try required("execution", id.description)
        let work: WorkItem = try required("work", execution.workID.description)
        guard execution.state == .running, work.state == .running, work.executionID == id else {
            throw ControllerError.conflict
        }
        return (work, execution)
    }
    func saveWork(_ work: WorkItem) throws {
        try update("work", work.id.description, state: work.state.rawValue, value: work)
    }
    func saveExecution(_ execution: ControllerExecution) throws {
        try update("execution", execution.id.description, state: execution.state.rawValue, value: execution)
    }
    func encode<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }
    func decode<T: Decodable>(_ text: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(text.utf8))
    }
    func optional<T: Decodable>(_ kind: String, _ id: String) throws -> T? {
        guard let row = try db.rows("SELECT payload FROM record WHERE kind=? AND id=? LIMIT 1", [.text(kind), .text(id)]).first else { return nil }
        return try decode(row.text(0))
    }
    func required<T: Decodable>(_ kind: String, _ id: String) throws -> T {
        guard let value: T = try optional(kind, id) else { throw ControllerError.notFound }
        return value
    }
    func insert<T: Encodable>(_ kind: String, _ id: String, parent: String? = nil,
                              key: String? = nil, state: String? = nil, scope: String? = nil, value: T) throws {
        try db.run("INSERT INTO record(kind,id,parent,key,state,scope,payload) VALUES(?,?,?,?,?,?,?)",
                   [.text(kind), .text(id), parent.map(ControllerDatabase.Value.text) ?? .null,
                    key.map(ControllerDatabase.Value.text) ?? .null, state.map(ControllerDatabase.Value.text) ?? .null,
                    scope.map(ControllerDatabase.Value.text) ?? .null, .text(try encode(value))])
    }
    func update<T: Encodable>(_ kind: String, _ id: String, state: String? = nil, value: T) throws {
        try db.run("UPDATE record SET state=?,payload=? WHERE kind=? AND id=?",
                   [state.map(ControllerDatabase.Value.text) ?? .null, .text(try encode(value)), .text(kind), .text(id)])
    }
    func event(_ kind: String, _ subject: String, text: String? = nil, source: String = "controller") throws {
        try db.run("INSERT INTO event(kind,subject,at) VALUES(?,?,?)",
                   [.text(kind), .text(subject), .text(ISO8601DateFormatter().string(from: Date()))])
        try recordActivity(kind: kind, subject: subject, text: text, source: source)
    }
    func page<T: Codable & Sendable>(_ kind: String, parent: String? = nil, after: Int64, limit: Int) throws -> ControllerPage<T> {
        try Limits.page(after, limit)
        var values: [ControllerDatabase.Value] = [.text(kind)]
        let parentClause: String
        if let parent { parentClause = " AND parent=?"; values.append(.text(parent)) }
        else { parentClause = "" }
        values += [.integer(after), .integer(Int64(limit))]
        let rows = try db.rows("SELECT sequence,payload FROM record WHERE kind=?\(parentClause) AND sequence>? ORDER BY sequence LIMIT ?",
                              values, pageByteLimit: 1_048_576)
        return ControllerPage(items: try rows.map { try decode($0.text(1)) }, next: rows.last?.integers[0] ?? after)
    }
}

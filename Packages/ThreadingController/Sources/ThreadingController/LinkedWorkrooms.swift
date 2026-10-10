import Foundation

public enum WorkroomTag: Sendable {}
public enum WorkroomLinkTag: Sendable {}
public typealias WorkroomID = ControllerID<WorkroomTag>
public typealias WorkroomLinkID = ControllerID<WorkroomLinkTag>

/// A room owns its collaboration identity. External links may be attached later.
public struct LinkedWorkroom: Codable, Equatable, Sendable {
    public let id: WorkroomID
    public let scope: String
    public let title: String
    public let purpose: String
    public let createdAt: String
}

public enum WorkroomLinkKind: String, Codable, Sendable {
    case issue, pullRequest, supportCase, document, repository, url, other
}

public enum WorkroomLinkRelationship: String, Codable, Sendable {
    case context, source, output, affected
}

/// The target is an opaque provider ID, never a grant to read or mutate that provider.
public struct WorkroomLink: Codable, Equatable, Sendable {
    public let id: WorkroomLinkID
    public let roomID: WorkroomID
    public let kind: WorkroomLinkKind
    public let provider: String
    public let target: String
    public let label: String
    public let relationship: WorkroomLinkRelationship
    public let url: String?
    public let createdAt: String
}

extension ControllerStore {
    /// Owner operation. The host adapter must authorize the scope before calling it.
    public func createWorkroom(id: WorkroomID, scope: String, title: String, purpose: String) throws -> LinkedWorkroom {
        try Limits.text(scope, field: "scope", maximum: 256)
        try Limits.text(title, field: "title", maximum: 256)
        try Limits.text(purpose, field: "purpose", maximum: 4_096, empty: true)
        return try db.transaction {
            if let prior: LinkedWorkroom = try optional("workroom", id.description) {
                guard prior.scope == scope, prior.title == title, prior.purpose == purpose else {
                    throw ControllerError.conflict
                }
                return prior
            }
            let room = LinkedWorkroom(id: id, scope: scope, title: title, purpose: purpose,
                                      createdAt: Self.now())
            try insert("workroom", id.description, scope: scope, value: room)
            try event("workroom.created", id.description)
            return room
        }
    }

    public func workroom(_ id: WorkroomID) throws -> LinkedWorkroom {
        try required("workroom", id.description)
    }

    /// Owner projection. A future human adapter must filter by authenticated scope.
    public func workrooms(scope: String, after: Int64 = 0, limit: Int = 50) throws -> ControllerPage<LinkedWorkroom> {
        try Limits.text(scope, field: "scope", maximum: 256)
        try Limits.page(after, limit)
        let rows = try db.rows("""
            SELECT sequence,payload FROM record INDEXED BY record_scope_state
            WHERE kind='workroom' AND scope=? AND state IS NULL AND sequence>?
            ORDER BY sequence LIMIT ?
            """, [.text(scope), .integer(after), .integer(Int64(limit))], pageByteLimit: 1_048_576)
        return ControllerPage(items: try rows.map { try decode($0.text(1)) },
                              next: rows.last?.integers[0] ?? after)
    }

    /// Owner operation. A link's display URL is never used as an authenticated provider route.
    public func addWorkroomLink(id: WorkroomLinkID, roomID: WorkroomID, kind: WorkroomLinkKind,
                                provider: String, target: String, label: String,
                                relationship: WorkroomLinkRelationship, url: String? = nil) throws -> WorkroomLink {
        try Limits.text(provider, field: "provider", maximum: 128)
        try Limits.text(target, field: "target", maximum: 2_048)
        try Limits.text(label, field: "label", maximum: 256)
        if let url {
            try Limits.text(url, field: "url", maximum: 2_048)
            guard let parsed = URL(string: url), parsed.scheme == "https", parsed.host != nil,
                  parsed.user == nil, parsed.password == nil else { throw ControllerError.invalidInput("url") }
        }
        return try db.transaction {
            let _: LinkedWorkroom = try required("workroom", roomID.description)
            if let prior: WorkroomLink = try optional("workroomLink", id.description) {
                guard prior.roomID == roomID, prior.kind == kind, prior.provider == provider,
                      prior.target == target, prior.label == label, prior.relationship == relationship,
                      prior.url == url else { throw ControllerError.conflict }
                return prior
            }
            let link = WorkroomLink(id: id, roomID: roomID, kind: kind, provider: provider,
                                    target: target, label: label, relationship: relationship,
                                    url: url, createdAt: Self.now())
            try insert("workroomLink", id.description, parent: roomID.description, value: link)
            try event("workroom.linked", roomID.description)
            return link
        }
    }

    public func workroomLinks(roomID: WorkroomID, after: Int64 = 0, limit: Int = 50) throws -> ControllerPage<WorkroomLink> {
        let _: LinkedWorkroom = try required("workroom", roomID.description)
        return try page("workroomLink", parent: roomID.description, after: after, limit: limit)
    }

    public func workroomWorks(roomID: WorkroomID, after: Int64 = 0, limit: Int = 50) throws -> ControllerPage<WorkItem> {
        try Limits.page(after, limit)
        let _: LinkedWorkroom = try required("workroom", roomID.description)
        let rows = try db.rows("""
            SELECT rw.sequence,w.payload FROM workroom_work AS rw
            JOIN record AS w ON w.kind='work' AND w.id=rw.work
            WHERE rw.room=? AND rw.sequence>? ORDER BY rw.sequence LIMIT ?
            """, [.text(roomID.description), .integer(after), .integer(Int64(limit))], pageByteLimit: 1_048_576)
        return ControllerPage(items: try rows.map { try decode($0.text(1)) },
                              next: rows.last?.integers[0] ?? after)
    }

    public func workroomQuestions(roomID: WorkroomID, after: Int64 = 0, limit: Int = 50,
                                  openOnly: Bool = false) throws -> ControllerPage<WorkQuestion> {
        try Limits.page(after, limit)
        let _: LinkedWorkroom = try required("workroom", roomID.description)
        let stateClause = openOnly ? " AND rq.state='open'" : ""
        let index = openOnly ? "workroom_question_open" : "workroom_question_page"
        let rows = try db.rows("""
            SELECT rq.sequence,q.payload FROM workroom_question AS rq INDEXED BY \(index)
            JOIN record AS q ON q.kind='question' AND q.id=rq.question
            WHERE rq.room=?\(stateClause) AND rq.sequence>?
            ORDER BY rq.sequence LIMIT ?
            """, [.text(roomID.description), .integer(after), .integer(Int64(limit))],
                   pageByteLimit: 1_048_576)
        return ControllerPage(items: try rows.map { try decode($0.text(1)) },
                              next: rows.last?.integers[0] ?? after)
    }

    /// Exact room membership is checked before a human adapter reads or answers one question.
    public func workroomQuestion(roomID: WorkroomID, questionID: QuestionID) throws -> WorkQuestion {
        let rows = try db.rows("""
            SELECT q.payload FROM workroom_question AS rq
            JOIN record AS q ON q.kind='question' AND q.id=rq.question
            WHERE rq.room=? AND rq.question=? LIMIT 1
            """, [.text(roomID.description), .text(questionID.description)])
        guard let row = rows.first else { throw ControllerError.notFound }
        return try decode(row.text(0))
    }

    /// A person's inbox page never scans questions addressed to somebody else.
    public func workroomQuestionsFor(roomID: WorkroomID, recipient: String,
                                     after: Int64 = 0, limit: Int = 50) throws -> ControllerPage<WorkQuestion> {
        try Limits.recipient(recipient)
        try Limits.page(after, limit)
        let _: LinkedWorkroom = try required("workroom", roomID.description)
        let rows = try db.rows("""
            SELECT qr.sequence,q.payload FROM workroom_question_recipient AS qr
            INDEXED BY workroom_question_recipient_page
            JOIN record AS q ON q.kind='question' AND q.id=qr.question
            WHERE qr.room=? AND qr.recipient=? AND qr.sequence>?
            ORDER BY qr.sequence LIMIT ?
            """, [.text(roomID.description), .text(recipient), .integer(after), .integer(Int64(limit))],
                   pageByteLimit: 1_048_576)
        return ControllerPage(items: try rows.map { try decode($0.text(1)) },
                              next: rows.last?.integers[0] ?? after)
    }

    /// Enqueue and bind in one transaction. A retry cannot silently adopt pre-existing work.
    public func enqueueInWorkroom(roomID: WorkroomID, workerID: WorkerID, key: String,
                                  instruction: String, request: String? = nil,
                                  source: WorkSource = .request, after: [WorkID] = []) throws -> WorkItem {
        try db.transaction {
            let _: LinkedWorkroom = try required("workroom", roomID.description)
            let existing = try db.rows("SELECT id FROM record WHERE kind='work' AND parent=? AND key=? LIMIT 1",
                                       [.text(workerID.description), .text(key)]).first != nil
            var work = try enqueue(workerID: workerID, key: key, instruction: instruction,
                                   request: request, source: source, after: after)
            if existing {
                guard work.workroomID == roomID else { throw ControllerError.conflict }
                return work
            }
            work.workroomID = roomID
            try saveWork(work)
            guard let row = try db.rows("SELECT sequence FROM record WHERE kind='work' AND id=? LIMIT 1",
                                        [.text(work.id.description)]).first else { throw ControllerError.notFound }
            try db.run("INSERT INTO workroom_work(room,work,sequence) VALUES(?,?,?)",
                       [.text(roomID.description), .text(work.id.description), .integer(row.integers[0])])
            try event("workroom.work_linked", roomID.description)
            return work
        }
    }

    func recordWorkroomQuestion(_ question: WorkQuestion, roomID: WorkroomID) throws {
        guard let row = try db.rows("SELECT sequence FROM record WHERE kind='question' AND id=? LIMIT 1",
                                    [.text(question.id.description)]).first else { throw ControllerError.notFound }
        try db.run("INSERT INTO workroom_question(room,question,sequence,state) VALUES(?,?,?,'open')",
                   [.text(roomID.description), .text(question.id.description), .integer(row.integers[0])])
        for recipient in question.recipients {
            try db.run("INSERT INTO workroom_question_recipient(room,question,recipient,sequence) VALUES(?,?,?,?)",
                       [.text(roomID.description), .text(question.id.description), .text(recipient), .integer(row.integers[0])])
        }
    }
}

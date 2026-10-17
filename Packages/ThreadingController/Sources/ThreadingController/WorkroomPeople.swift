import Foundation

// The people a Linked Workroom may address, and which rooms each may see. People are owner
// records: an agent names one by handle and can only ask someone the owner added. A room starts
// private; the owner opens it to named people, and only then does the portal show it to them.

public enum WorkroomPersonTag: Sendable {}
public typealias WorkroomPersonID = ControllerID<WorkroomPersonTag>

/// Who last chose a person's language. The person's own choice sticks: an agent may follow the
/// language a person writes in, but never overrides what the person picked in the portal.
public enum WorkroomLanguageSource: String, Codable, Sendable { case owner, agent, person }

public enum WorkroomPersonState: String, Codable, Sendable { case active, removed }

public struct WorkroomPerson: Codable, Equatable, Sendable {
    public let id: WorkroomPersonID
    /// What agents and the owner type: lowercase letters, digits, `.`, `-`, `_`.
    public let handle: String
    public internal(set) var name: String
    public internal(set) var language: String
    public internal(set) var languageSource: WorkroomLanguageSource
    public internal(set) var email: String?
    public internal(set) var state: WorkroomPersonState
    public internal(set) var revision: Int
    public let createdAt: String

    /// This person's local-only mailbox: questions are mail to it, answers mail from it.
    public func mailAddress(host: HostID) -> MailAddress { MailAddress(host: host, kind: .person, id: id.rawValue) }
}

public enum WorkroomPublicationState: String, Codable, Sendable { case `private`, open, closed }

/// Whether a room is visible outside this Mac. Absent means private. Only the owner writes it.
public struct WorkroomPublication: Codable, Equatable, Sendable {
    public let roomID: WorkroomID
    public internal(set) var state: WorkroomPublicationState
    public internal(set) var revision: Int
    public internal(set) var openedAt: String?
    public internal(set) var expiresAt: String?
    public internal(set) var closedAt: String?

    /// Open and not past its expiry.
    public func isOpen(at now: Date = Date()) -> Bool {
        guard state == .open else { return false }
        guard let expiresAt, let expiry = ControllerStore.date(expiresAt) else { return true }
        return now < expiry
    }
}

public enum WorkroomAccessState: String, Codable, Sendable { case granted, revoked }

/// One person's standing in one room.
public struct WorkroomAccess: Codable, Equatable, Sendable {
    public let roomID: WorkroomID
    public let person: WorkroomPersonID
    public let state: WorkroomAccessState
    public let revision: Int
}

/// What the owner sees for one room: the room, its publication and who may see it.
public struct WorkroomSummary: Codable, Equatable, Sendable {
    public let room: LinkedWorkroom
    public let publication: WorkroomPublication
    public let people: [WorkroomPerson]
    public let openQuestions: Int
}

extension ControllerStore {
    // MARK: - People

    public func addWorkroomPerson(id: WorkroomPersonID, handle: String, name: String, language: String,
                                  email: String? = nil) throws -> WorkroomPerson {
        try Self.validatePerson(handle: handle, name: name, language: language, email: email)
        return try db.transaction {
            if let prior: WorkroomPerson = try optional("workroomPerson", id.description) {
                guard prior.handle == handle, prior.name == name, prior.email == email, prior.state == .active else {
                    throw ControllerError.conflict
                }
                return prior
            }
            guard try workroomPerson(handle: handle) == nil else { throw ControllerError.conflict }
            let person = WorkroomPerson(id: id, handle: handle, name: name, language: language, languageSource: .owner,
                                        email: email, state: .active, revision: 1, createdAt: Self.now())
            try insert("workroomPerson", id.description, key: handle, state: person.state.rawValue, value: person)
            try event("workroom.person_added", id.description)
            return person
        }
    }

    /// Owner edit. The handle is the person's identity for agents and never changes.
    public func updateWorkroomPerson(id: WorkroomPersonID, expectedRevision: Int, name: String, language: String,
                                     email: String?) throws -> WorkroomPerson {
        return try db.transaction {
            var person: WorkroomPerson = try required("workroomPerson", id.description)
            try Self.validatePerson(handle: person.handle, name: name, language: language, email: email)
            guard person.revision == expectedRevision, person.state == .active else { throw ControllerError.conflict }
            if person.language != language { person.languageSource = .owner }
            person.name = name
            person.language = language
            person.email = email
            person.revision += 1
            try savePerson(person)
            try event("workroom.person_changed", id.description)
            return person
        }
    }

    /// Removing a person ends every device session and pending invitation in the same
    /// transaction; their questions and answers stay as history.
    public func removeWorkroomPerson(id: WorkroomPersonID) throws -> WorkroomPerson {
        try db.transaction {
            var person: WorkroomPerson = try required("workroomPerson", id.description)
            guard person.state == .active else { return person }
            person.state = .removed
            person.revision += 1
            try savePerson(person)
            try revokeWorkroomCredentials(person: id)
            try event("workroom.person_removed", id.description)
            return person
        }
    }

    public func workroomPerson(_ id: WorkroomPersonID) throws -> WorkroomPerson {
        try required("workroomPerson", id.description)
    }

    /// Active people only: a removed handle cannot be addressed.
    public func workroomPerson(handle: String) throws -> WorkroomPerson? {
        // A removed person keeps their handle as history, so the active one is chosen by state.
        guard let row = try db.rows("""
            SELECT payload FROM record WHERE kind='workroomPerson' AND parent IS NULL AND key=? AND state='active' LIMIT 1
            """, [.text(handle)]).first else { return nil }
        return try decode(row.text(0))
    }

    public func workroomPeople(after: Int64 = 0, limit: Int = 50) throws -> ControllerPage<WorkroomPerson> {
        try Limits.page(after, limit)
        let rows = try db.rows("""
            SELECT sequence,payload FROM record INDEXED BY record_ready
            WHERE kind='workroomPerson' AND parent IS NULL AND state='active' AND sequence>? ORDER BY sequence LIMIT ?
            """, [.integer(after), .integer(Int64(limit))], pageByteLimit: 1_048_576)
        return ControllerPage(items: try rows.map { try decode($0.text(1)) }, next: rows.last?.integers[0] ?? after)
    }

    /// An agent following the language a person writes in. Refused once the person chose
    /// their own language in the portal.
    public func setWorkroomPersonLanguage(_ id: WorkroomPersonID, language: String,
                                          source: WorkroomLanguageSource) throws -> WorkroomPerson {
        try WorkroomLimits.language(language)
        return try db.transaction {
            var person: WorkroomPerson = try required("workroomPerson", id.description)
            guard person.state == .active else { throw ControllerError.notFound }
            if source == .agent, person.languageSource == .person, person.language != language {
                throw ControllerError.conflict
            }
            guard person.language != language || person.languageSource != source else { return person }
            person.language = language
            person.languageSource = source
            person.revision += 1
            try savePerson(person)
            try event("workroom.person_language", id.description)
            return person
        }
    }

    // MARK: - Rooms

    /// A room an agent opened for its session, in that session's project scope. Private until
    /// the owner opens it.
    public func createWorkroom(id: WorkroomID, scope: String, title: String, purpose: String,
                               createdBy: MailAddress?) throws -> LinkedWorkroom {
        try Limits.text(scope, field: "scope", maximum: 256)
        try Limits.text(title, field: "title", maximum: 256)
        try Limits.text(purpose, field: "purpose", maximum: 4_096, empty: true)
        return try db.transaction {
            if let prior: LinkedWorkroom = try optional("workroom", id.description) {
                guard prior.scope == scope, prior.title == title, prior.purpose == purpose,
                      prior.createdBy == createdBy?.description else { throw ControllerError.conflict }
                return prior
            }
            var room = LinkedWorkroom(id: id, scope: scope, title: title, purpose: purpose, createdAt: Self.now())
            room.createdBy = createdBy?.description
            try insert("workroom", id.description, scope: scope, value: room)
            if let createdBy { try tie(createdBy, to: id) }
            try event("workroom.created", id.description)
            return room
        }
    }

    /// Every room on this host, oldest first: the owner's view, across projects.
    public func allWorkrooms(after: Int64 = 0, limit: Int = 50) throws -> ControllerPage<LinkedWorkroom> {
        try page("workroom", after: after, limit: limit)
    }

    public func workroomPublication(_ roomID: WorkroomID) throws -> WorkroomPublication {
        try optional("workroomPublication", roomID.description)
            ?? WorkroomPublication(roomID: roomID, state: .private, revision: 0, openedAt: nil, expiresAt: nil, closedAt: nil)
    }

    /// Owner approval: grants `people` this room and opens it until `expiresAt`. Granting is
    /// additive; a person already granted stays granted.
    public func openWorkroom(_ roomID: WorkroomID, people: [WorkroomPersonID], expiresAt: Date?) throws -> WorkroomPublication {
        guard (1...32).contains(people.count), Set(people).count == people.count else { throw ControllerError.invalidInput("people") }
        if let expiresAt { guard expiresAt > Date() else { throw ControllerError.invalidInput("expires_at") } }
        return try db.transaction {
            let _: LinkedWorkroom = try required("workroom", roomID.description)
            for person in people {
                let value: WorkroomPerson = try required("workroomPerson", person.description)
                guard value.state == .active else { throw ControllerError.notFound }
                try setAccess(roomID, person: person, state: .granted)
            }
            var publication = try workroomPublication(roomID)
            let fresh = publication.revision == 0
            publication.state = .open
            publication.revision += 1
            publication.openedAt = Self.now()
            publication.expiresAt = expiresAt.map { ISO8601DateFormatter().string(from: $0) }
            publication.closedAt = nil
            if fresh {
                try insert("workroomPublication", roomID.description, state: publication.state.rawValue, value: publication)
            } else {
                try update("workroomPublication", roomID.description, state: publication.state.rawValue, value: publication)
            }
            try event("workroom.opened", roomID.description)
            return publication
        }
    }

    public func closeWorkroom(_ roomID: WorkroomID) throws -> WorkroomPublication {
        try db.transaction {
            var publication = try workroomPublication(roomID)
            guard publication.state == .open else { return publication }
            publication.state = .closed
            publication.revision += 1
            publication.closedAt = Self.now()
            try update("workroomPublication", roomID.description, state: publication.state.rawValue, value: publication)
            try event("workroom.closed", roomID.description)
            return publication
        }
    }

    /// Closes every open room, a page at a time. Returns how many it closed.
    public func closeAllWorkrooms() throws -> Int {
        var closed = 0
        while true {
            let rows = try db.rows("""
                SELECT id FROM record INDEXED BY record_ready
                WHERE kind='workroomPublication' AND parent IS NULL AND state='open' ORDER BY sequence LIMIT 100
                """)
            for row in rows {
                _ = try closeWorkroom(try WorkroomID(row.text(0)))
                closed += 1
            }
            guard rows.count == 100 else { return closed }
        }
    }

    /// Rooms that are open now; the portal listens only while this is non-empty.
    public func openWorkroomCount() throws -> Int {
        var count = 0
        for row in try db.rows("""
            SELECT payload FROM record INDEXED BY record_ready
            WHERE kind='workroomPublication' AND parent IS NULL AND state='open' ORDER BY sequence LIMIT 100
            """) {
            let publication: WorkroomPublication = try decode(row.text(0))
            if publication.isOpen() { count += 1 }
        }
        return count
    }

    public func revokeWorkroomAccess(_ roomID: WorkroomID, person: WorkroomPersonID) throws {
        try db.transaction {
            guard try access(roomID, person: person)?.state == .granted else { return }
            try setAccess(roomID, person: person, state: .revoked)
            try event("workroom.access_revoked", roomID.description)
        }
    }

    public func workroomAccess(_ roomID: WorkroomID) throws -> [WorkroomAccess] {
        try db.rows("""
            SELECT room,person,state,revision FROM workroom_access WHERE room=? ORDER BY person LIMIT 100
            """, [.text(roomID.description)]).map { row in
            WorkroomAccess(roomID: try WorkroomID(row.text(0)), person: try WorkroomPersonID(row.text(1)),
                           state: try Self.accessState(row.text(2)), revision: Int(row.integers[3]))
        }
    }

    public func workroomSummary(_ roomID: WorkroomID) throws -> WorkroomSummary {
        let room: LinkedWorkroom = try required("workroom", roomID.description)
        let people = try workroomAccess(roomID).filter { $0.state == .granted }.map { try workroomPerson($0.person) }
        let open = try db.rows("""
            SELECT COUNT(*) FROM (SELECT 1 FROM workroom_ask WHERE room=? AND state='open' LIMIT ?)
            """, [.text(roomID.description), .integer(Int64(WorkroomLimits.openQuestionsPerRoom))]).first?.integers[0] ?? 0
        return WorkroomSummary(room: room, publication: try workroomPublication(roomID), people: people, openQuestions: Int(open))
    }

    // MARK: - Ties

    /// The rooms a mailbox works in — it created them or asked in them — that are not closed.
    /// A session tied to a room routes its questions through it instead of waiting in its
    /// terminal; closing the room unties it. Bounded: a mailbox's first 100 ties.
    public func workroomTies(_ mailbox: MailAddress) throws -> [LinkedWorkroom] {
        var rooms: [LinkedWorkroom] = []
        for row in try db.rows("""
            SELECT payload FROM record INDEXED BY record_ready
            WHERE kind='workroomTie' AND parent=? AND state='tied' ORDER BY sequence LIMIT 100
            """, [.text(mailbox.description)]) {
            let roomID: WorkroomID = try decode(row.text(0))
            guard try workroomPublication(roomID).state != .closed,
                  let room: LinkedWorkroom = try optional("workroom", roomID.description) else { continue }
            rooms.append(room)
        }
        return rooms
    }

    /// Ties a mailbox to a room it works in. Idempotent.
    func tie(_ mailbox: MailAddress, to roomID: WorkroomID) throws {
        let id = "\(mailbox)|\(roomID)"
        guard (try optional("workroomTie", id) as WorkroomID?) == nil else { return }
        try insert("workroomTie", id, parent: mailbox.description, state: "tied", value: roomID)
    }

    // MARK: - Helpers

    func access(_ roomID: WorkroomID, person: WorkroomPersonID) throws -> WorkroomAccess? {
        guard let row = try db.rows("SELECT state,revision FROM workroom_access WHERE room=? AND person=? LIMIT 1",
                                    [.text(roomID.description), .text(person.description)]).first else { return nil }
        return WorkroomAccess(roomID: roomID, person: person,
                              state: try Self.accessState(row.text(0)), revision: Int(row.integers[1]))
    }

    /// A state this build does not know is unreadable data, never a grant or a revocation.
    private static func accessState(_ text: String) throws -> WorkroomAccessState {
        guard let state = WorkroomAccessState(rawValue: text) else { throw ControllerError.unsupportedSchema }
        return state
    }

    /// The room is open and the person granted: what every participant read and write checks.
    func participantMayUse(_ roomID: WorkroomID, person: WorkroomPersonID, now: Date = Date()) throws -> Bool {
        guard try access(roomID, person: person)?.state == .granted else { return false }
        return try workroomPublication(roomID).isOpen(at: now)
    }

    private func setAccess(_ roomID: WorkroomID, person: WorkroomPersonID, state: WorkroomAccessState) throws {
        let prior = try access(roomID, person: person)
        guard prior?.state != state else { return }
        try db.run("""
            INSERT INTO workroom_access(room,person,state,revision) VALUES(?,?,?,1)
            ON CONFLICT(room,person) DO UPDATE SET state=excluded.state, revision=workroom_access.revision+1
            """, [.text(roomID.description), .text(person.description), .text(state.rawValue)])
    }

    private func savePerson(_ person: WorkroomPerson) throws {
        try update("workroomPerson", person.id.description, state: person.state.rawValue, value: person)
    }

    /// The checks `addWorkroomPerson` applies, for an adapter that validates a proposal first.
    public static func validatePerson(handle: String, name: String, language: String, email: String?) throws {
        guard (1...64).contains(handle.utf8.count),
              handle.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || ".-_".contains($0)) }) else {
            throw ControllerError.invalidInput("handle")
        }
        try Limits.text(name, field: "name", maximum: 128)
        guard !name.contains(where: \.isNewline) else { throw ControllerError.invalidInput("name") }
        try WorkroomLimits.language(language)
        if let email {
            try Limits.text(email, field: "email", maximum: 254)
            guard email.contains("@"), !email.contains(where: { $0.isWhitespace }) else { throw ControllerError.invalidInput("email") }
        }
    }

    static func date(_ text: String) -> Date? { ISO8601DateFormatter().date(from: text) }
}

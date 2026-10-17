import Foundation

// Structured questions in a Linked Workroom, asked by an agent's mailbox of one person. A
// question is mail to the person's local-only mailbox; every answer, clarification request or
// decline is a reply from it, committed in the same transaction as the record. So the asking
// session hears about it through ordinary mail delivery (notices, stop hooks, wakes), while the
// typed answer lives here, where the form that validated it does.

public enum WorkroomQuestionState: String, Codable, Sendable { case open, answered, withdrawn, declined }

/// What the agent supplies. The asker, room scope, person and git context are the host's.
public struct WorkroomQuestionDraft: Codable, Equatable, Sendable {
    public let title: String
    public let prompt: String
    public let background: String
    public let language: String
    public let form: WorkroomForm
    public let evidence: [WorkroomEvidence]

    public init(title: String, prompt: String, background: String = "", language: String,
                form: WorkroomForm = WorkroomForm(), evidence: [WorkroomEvidence] = []) {
        self.title = title
        self.prompt = prompt
        self.background = background
        self.language = language
        self.form = form
        self.evidence = evidence
    }

    func validate() throws {
        try Limits.text(title, field: "title", maximum: WorkroomLimits.titleBytes)
        guard !title.contains(where: \.isNewline) else { throw ControllerError.invalidInput("title") }
        try Limits.text(prompt, field: "prompt", maximum: WorkroomLimits.promptBytes)
        try Limits.text(background, field: "background", maximum: WorkroomLimits.backgroundBytes, empty: true)
        try WorkroomLimits.language(language)
        try form.validate()
        guard evidence.count <= WorkroomLimits.evidence else { throw ControllerError.invalidInput("evidence") }
        for item in evidence { try item.validate() }
    }
}

public struct WorkroomQuestion: Codable, Equatable, Sendable {
    public let id: QuestionID
    public let roomID: WorkroomID
    public let asker: MailAddress
    public let askerName: String
    public let person: WorkroomPersonID
    public let draft: WorkroomQuestionDraft
    public let gitContext: WorkroomGitContext?
    public let askedAt: String
    public internal(set) var state: WorkroomQuestionState
    public internal(set) var answerRevision: Int
    public internal(set) var noteCount: Int
    public internal(set) var updatedAt: String

    /// The question's own mail to the person; every reply from the person answers this one.
    public var mailID: UUID { id.rawValue }
}

public struct WorkroomAnswer: Codable, Equatable, Sendable {
    public let questionID: QuestionID
    public let revision: Int
    public let person: WorkroomPersonID
    public let answers: [WorkroomFieldAnswer]
    public let comment: String
    public let at: String
}

public enum WorkroomNoteAuthor: String, Codable, Sendable { case person, agent }
public enum WorkroomNoteKind: String, Codable, Sendable { case clarification, response, decline, withdrawal }

public struct WorkroomNote: Codable, Equatable, Sendable {
    public let id: UUID
    public let questionID: QuestionID
    public let author: WorkroomNoteAuthor
    public let kind: WorkroomNoteKind
    public let text: String
    public let at: String
}

public struct WorkroomQuestionDetail: Codable, Equatable, Sendable {
    public let question: WorkroomQuestion
    public let room: LinkedWorkroom
    public let personName: String
    public let answers: [WorkroomAnswer]
    public let notes: [WorkroomNote]
}

/// The result of a person's write: what changed, and the session mailbox that now has mail,
/// so the host can deliver it (`MacMailDelivery.arrived`).
public struct WorkroomParticipantReceipt: Codable, Equatable, Sendable {
    public let question: WorkroomQuestion
    public let notified: MailAddress
}

/// One page of a person's questions. `next` resumes the scan and `more` says it stopped at its
/// examination bound rather than at the end.
public struct WorkroomInboxPage: Codable, Equatable, Sendable {
    public let items: [WorkroomInboxItem]
    public let next: Int64
    public let more: Bool
}

public struct WorkroomInboxItem: Codable, Equatable, Sendable {
    public let question: WorkroomQuestion
    public let roomTitle: String
}

public enum WorkroomInboxFilter: Sendable { case open, recent }

struct WorkroomAskRate: Codable { var windowStart: Double; var count: Int }

extension ControllerStore {
    // MARK: - Asking (on behalf of an agent's mailbox)

    /// `scope` is the asking session's project: a room in another project is not found. The
    /// person must be an active person the owner added; the room need not be open yet, and the
    /// question waits, invisible, until it is. A retry with the same id returns the original.
    public func askWorkroom(id: QuestionID, roomID: WorkroomID, scope: String, asker: MailAddress,
                            personHandle: String, draft: WorkroomQuestionDraft,
                            gitContext: WorkroomGitContext?) throws -> WorkroomQuestion {
        try draft.validate()
        try gitContext?.validate()
        return try db.transaction {
            let room: LinkedWorkroom = try required("workroom", roomID.description)
            guard room.scope == scope else { throw ControllerError.notFound }
            guard let person = try workroomPerson(handle: personHandle) else { throw ControllerError.invalidInput("person") }
            if let prior: WorkroomQuestion = try optional("workroomAsk", id.description) {
                guard prior.roomID == roomID, prior.asker == asker, prior.person == person.id,
                      prior.draft == draft else { throw ControllerError.conflict }
                return prior
            }
            let open = try db.rows("""
                SELECT COUNT(*) FROM (SELECT 1 FROM workroom_ask WHERE room=? AND state='open' LIMIT ?)
                """, [.text(roomID.description), .integer(Int64(WorkroomLimits.openQuestionsPerRoom))]).first?.integers[0] ?? 0
            guard open < Int64(WorkroomLimits.openQuestionsPerRoom) else { throw ControllerError.invalidInput("room_full") }
            try spendAskRate(asker)
            let askerName = try localMailboxName(asker)
            let now = Self.now()
            let question = WorkroomQuestion(id: id, roomID: roomID, asker: asker, askerName: askerName, person: person.id,
                                            draft: draft, gitContext: gitContext, askedAt: now, state: .open,
                                            answerRevision: 0, noteCount: 0, updatedAt: now)
            let summary = "Workroom question “\(Self.fenced(draft.title))” to \(Self.fenced(person.name)) in “\(Self.fenced(room.title))”:\n\(draft.prompt)"
            _ = try workroomMail(from: asker, senderName: askerName, to: person.mailAddress(host: try host().id),
                                 id: question.mailID, text: Self.clipped(summary), replyTo: nil)
            try insert("workroomAsk", id.description, parent: roomID.description, state: question.state.rawValue,
                       scope: asker.description, value: question)
            guard let sequence = try db.rows("SELECT sequence FROM record WHERE kind='workroomAsk' AND id=? LIMIT 1",
                                             [.text(id.description)]).first?.integers[0] else { throw ControllerError.notFound }
            try db.run("INSERT INTO workroom_ask(question,room,asker,person,state,sequence) VALUES(?,?,?,?,?,?)",
                       [.text(id.description), .text(roomID.description), .text(asker.description),
                        .text(person.id.description), .text(question.state.rawValue), .integer(sequence)])
            try tie(asker, to: roomID)
            try event("workroom.asked", id.description)
            return question
        }
    }

    /// The agent answers a clarification request. Recorded for the person; no mail goes to them.
    public func respondToWorkroomQuestion(_ id: QuestionID, asker: MailAddress, text: String) throws -> WorkroomNote {
        try Limits.text(text, field: "note", maximum: WorkroomLimits.noteBytes)
        return try db.transaction {
            var question = try askedBy(id, asker: asker)
            guard question.state == .open || question.state == .answered else { throw ControllerError.conflict }
            let note = try addNote(&question, author: .agent, kind: .response, text: text)
            try saveQuestion(question)
            try event("workroom.responded", id.description)
            return note
        }
    }

    public func withdrawWorkroomQuestion(_ id: QuestionID, asker: MailAddress, reason: String) throws -> WorkroomQuestion {
        try Limits.text(reason, field: "note", maximum: WorkroomLimits.noteBytes, empty: true)
        return try db.transaction {
            var question = try askedBy(id, asker: asker)
            guard question.state != .withdrawn else { return question }
            guard question.state != .declined else { throw ControllerError.conflict }
            if !reason.isEmpty { _ = try addNote(&question, author: .agent, kind: .withdrawal, text: reason) }
            question.state = .withdrawn
            try saveQuestion(question)
            try settleQuestionMail(question)
            try event("workroom.withdrawn", id.description)
            return question
        }
    }

    // MARK: - Reading (owner and agents)

    /// Questions in one room, oldest first. The caller has already checked the room's scope.
    public func workroomAsks(roomID: WorkroomID, after: Int64 = 0, limit: Int = 50) throws -> ControllerPage<WorkroomQuestion> {
        try Limits.page(after, limit)
        let rows = try db.rows("""
            SELECT a.sequence,q.payload FROM workroom_ask AS a INDEXED BY workroom_ask_room
            JOIN record AS q ON q.kind='workroomAsk' AND q.id=a.question
            WHERE a.room=? AND a.sequence>? ORDER BY a.sequence LIMIT ?
            """, [.text(roomID.description), .integer(after), .integer(Int64(limit))], pageByteLimit: 1_048_576)
        return ControllerPage(items: try rows.map { try decode($0.text(1)) }, next: rows.last?.integers[0] ?? after)
    }

    /// Questions one mailbox asked, across rooms, oldest first.
    public func workroomAsks(asker: MailAddress, after: Int64 = 0, limit: Int = 50) throws -> ControllerPage<WorkroomQuestion> {
        try Limits.page(after, limit)
        let rows = try db.rows("""
            SELECT a.sequence,q.payload FROM workroom_ask AS a INDEXED BY workroom_ask_asker
            JOIN record AS q ON q.kind='workroomAsk' AND q.id=a.question
            WHERE a.asker=? AND a.sequence>? ORDER BY a.sequence LIMIT ?
            """, [.text(asker.description), .integer(after), .integer(Int64(limit))], pageByteLimit: 1_048_576)
        return ControllerPage(items: try rows.map { try decode($0.text(1)) }, next: rows.last?.integers[0] ?? after)
    }

    public func workroomQuestionDetail(_ id: QuestionID) throws -> WorkroomQuestionDetail {
        let question: WorkroomQuestion = try required("workroomAsk", id.description)
        return try detail(question)
    }

    // MARK: - Participant (an authenticated person in the portal)

    /// A person's questions in rooms that are open to them. Examines at most
    /// `WorkroomLimits.inboxScan` index rows per call, whatever it returns.
    public func participantInbox(person: WorkroomPersonID, filter: WorkroomInboxFilter,
                                 cursor: Int64 = 0, limit: Int = 20) throws -> WorkroomInboxPage {
        try Limits.page(max(cursor, 0), limit)
        var items: [WorkroomInboxItem] = []
        var rooms: [WorkroomID: LinkedWorkroom?] = [:]
        var position = cursor
        var examined = 0
        let pageSize = 100
        while examined < WorkroomLimits.inboxScan, items.count < limit {
            // The scan reads index columns only; a payload is decoded for a row that is shown.
            let rows: [ControllerDatabase.Row]
            switch filter {
            case .open:
                rows = try db.rows("""
                    SELECT sequence,room,question,state FROM workroom_ask INDEXED BY workroom_ask_person
                    WHERE person=? AND state='open' AND sequence>? ORDER BY sequence LIMIT ?
                    """, [.text(person.description), .integer(position), .integer(Int64(pageSize))])
            case .recent:
                // Newest first; a zero cursor means "from the newest".
                rows = try db.rows("""
                    SELECT sequence,room,question,state FROM workroom_ask INDEXED BY workroom_ask_person_all
                    WHERE person=? AND (?=0 OR sequence<?) ORDER BY sequence DESC LIMIT ?
                    """, [.text(person.description), .integer(position), .integer(position), .integer(Int64(pageSize))])
            }
            for row in rows {
                examined += 1
                position = row.integers[0]
                if filter == .recent, try row.text(3) == WorkroomQuestionState.open.rawValue { continue }
                let roomID = try WorkroomID(row.text(1))
                if rooms[roomID] == nil {
                    rooms[roomID] = try participantMayUse(roomID, person: person)
                        ? (try required("workroom", roomID.description) as LinkedWorkroom) : nil
                }
                guard let room = rooms[roomID] ?? nil else { continue }
                let question: WorkroomQuestion = try required("workroomAsk", try row.text(2))
                items.append(WorkroomInboxItem(question: question, roomTitle: room.title))
                if items.count == limit { break }
            }
            if rows.count < pageSize, items.count < limit { return WorkroomInboxPage(items: items, next: position, more: false) }
        }
        return WorkroomInboxPage(items: items, next: position, more: true)
    }

    /// One question, if it is addressed to this person in a room open to them. Anything else is
    /// the same not-found, so a person cannot probe for questions that are not theirs.
    public func participantQuestion(person: WorkroomPersonID, id: QuestionID) throws -> WorkroomQuestionDetail {
        try detail(try participantOwned(id, person: person))
    }

    /// An answer revision. Re-submitting what the latest revision already says returns it, so a
    /// double-posted form does not add a revision.
    public func participantAnswer(person: WorkroomPersonID, id: QuestionID, answers: [WorkroomFieldAnswer],
                                  comment: String) throws -> WorkroomParticipantReceipt {
        try Limits.text(comment, field: "comment", maximum: WorkroomLimits.commentBytes, empty: true)
        return try db.transaction {
            var question = try participantOwned(id, person: person)
            guard question.state == .open || question.state == .answered else { throw ControllerError.conflict }
            try question.draft.form.validate(answers: answers)
            if question.draft.form.fields.isEmpty, comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ControllerError.invalidInput("answer_required")
            }
            if question.answerRevision > 0,
               let latest: WorkroomAnswer = try optional("workroomAnswer", "\(id)/\(question.answerRevision)"),
               latest.answers == answers, latest.comment == comment {
                return WorkroomParticipantReceipt(question: question, notified: question.asker)
            }
            guard question.answerRevision < WorkroomLimits.answerRevisions else { throw ControllerError.invalidInput("answer_revisions") }
            let answer = WorkroomAnswer(questionID: id, revision: question.answerRevision + 1, person: person,
                                        answers: answers, comment: comment, at: Self.now())
            try insert("workroomAnswer", "\(id)/\(answer.revision)", parent: id.description, value: answer)
            question.answerRevision = answer.revision
            question.state = .answered
            try saveQuestion(question)
            try settleQuestionMail(question)
            let personRecord = try workroomPerson(person)
            try replyAsPerson(personRecord, question: question, text: answerSummary(question, answer: answer, name: personRecord.name))
            try event("workroom.answered", id.description)
            return WorkroomParticipantReceipt(question: question, notified: question.asker)
        }
    }

    /// The person asks the agent to clarify; the question stays open.
    public func participantClarify(person: WorkroomPersonID, id: QuestionID, text: String) throws -> WorkroomParticipantReceipt {
        try Limits.text(text, field: "note", maximum: WorkroomLimits.noteBytes)
        return try db.transaction {
            var question = try participantOwned(id, person: person)
            guard question.state == .open || question.state == .answered else { throw ControllerError.conflict }
            _ = try addNote(&question, author: .person, kind: .clarification, text: text)
            try saveQuestion(question)
            let personRecord = try workroomPerson(person)
            try replyAsPerson(personRecord, question: question, text: Self.clipped("""
                “\(Self.fenced(personRecord.name))” asks for clarification on “\(Self.fenced(question.draft.title))” \
                (question \(id)):
                \(text)
                Answer with workroom_respond.
                """))
            try event("workroom.clarification", id.description)
            return WorkroomParticipantReceipt(question: question, notified: question.asker)
        }
    }

    /// "I am not the right person" or "I cannot answer this". Closes the question.
    public func participantDecline(person: WorkroomPersonID, id: QuestionID, reason: String) throws -> WorkroomParticipantReceipt {
        try Limits.text(reason, field: "note", maximum: WorkroomLimits.noteBytes)
        return try db.transaction {
            var question = try participantOwned(id, person: person)
            guard question.state == .open else { throw ControllerError.conflict }
            _ = try addNote(&question, author: .person, kind: .decline, text: reason)
            question.state = .declined
            try saveQuestion(question)
            try settleQuestionMail(question)
            let personRecord = try workroomPerson(person)
            try replyAsPerson(personRecord, question: question, text: Self.clipped("""
                “\(Self.fenced(personRecord.name))” declined “\(Self.fenced(question.draft.title))” (question \(id)):
                \(reason)
                """))
            try event("workroom.declined", id.description)
            return WorkroomParticipantReceipt(question: question, notified: question.asker)
        }
    }

    // MARK: - Helpers

    private func askedBy(_ id: QuestionID, asker: MailAddress) throws -> WorkroomQuestion {
        let question: WorkroomQuestion = try required("workroomAsk", id.description)
        guard question.asker == asker else { throw ControllerError.notFound }
        return question
    }

    private func participantOwned(_ id: QuestionID, person: WorkroomPersonID) throws -> WorkroomQuestion {
        guard let question: WorkroomQuestion = try optional("workroomAsk", id.description), question.person == person,
              try participantMayUse(question.roomID, person: person),
              try workroomPerson(person).state == .active else { throw ControllerError.notFound }
        return question
    }

    private func detail(_ question: WorkroomQuestion) throws -> WorkroomQuestionDetail {
        let answers: [WorkroomAnswer] = try db.rows("""
            SELECT payload FROM record WHERE kind='workroomAnswer' AND parent=? ORDER BY sequence LIMIT ?
            """, [.text(question.id.description), .integer(Int64(WorkroomLimits.answerRevisions))]).map { try decode($0.text(0)) }
        let notes: [WorkroomNote] = try db.rows("""
            SELECT payload FROM record WHERE kind='workroomNote' AND parent=? ORDER BY sequence LIMIT ?
            """, [.text(question.id.description), .integer(Int64(WorkroomLimits.notes + 2))]).map { try decode($0.text(0)) }
        return WorkroomQuestionDetail(question: question, room: try required("workroom", question.roomID.description),
                                      personName: try workroomPerson(question.person).name, answers: answers, notes: notes)
    }

    private func addNote(_ question: inout WorkroomQuestion, author: WorkroomNoteAuthor, kind: WorkroomNoteKind,
                         text: String) throws -> WorkroomNote {
        // A closing note (decline, withdrawal) is always allowed, so a full thread can still end.
        let closing = kind == .decline || kind == .withdrawal
        guard closing || question.noteCount < WorkroomLimits.notes else { throw ControllerError.invalidInput("notes") }
        let note = WorkroomNote(id: UUID(), questionID: question.id, author: author, kind: kind, text: text, at: Self.now())
        try insert("workroomNote", note.id.uuidString.lowercased(), parent: question.id.description, value: note)
        question.noteCount += 1
        return note
    }

    private func saveQuestion(_ question: WorkroomQuestion) throws {
        var question = question
        question.updatedAt = Self.now()
        try update("workroomAsk", question.id.description, state: question.state.rawValue, value: question)
        try db.run("UPDATE workroom_ask SET state=? WHERE question=?", [.text(question.state.rawValue), .text(question.id.description)])
    }

    /// The question's mail no longer counts as open in the person's mailbox once it is
    /// answered or closed; nothing reads that mailbox as an inbox.
    private func settleQuestionMail(_ question: WorkroomQuestion) throws {
        let id = question.mailID.uuidString.lowercased()
        guard var message: MailMessage = try optional("mail", id), message.state == .inbox || message.state == .noticed else { return }
        message.state = .acked
        message.ackedAt = Self.now()
        try update("mail", id, state: message.state.rawValue, value: message)
    }

    private func replyAsPerson(_ person: WorkroomPerson, question: WorkroomQuestion, text: String) throws {
        _ = try workroomMail(from: person.mailAddress(host: try host().id), senderName: person.name, to: question.asker,
                             id: UUID(), text: text, replyTo: question.mailID)
    }

    private func answerSummary(_ question: WorkroomQuestion, answer: WorkroomAnswer, name: String) -> String {
        var lines = ["“\(Self.fenced(name))” answered “\(Self.fenced(question.draft.title))” (question \(question.id), revision \(answer.revision))."]
        for field in question.draft.form.fields {
            guard let values = answer.answers.first(where: { $0.field == field.id })?.values, !values.isEmpty else { continue }
            let shown = values.map { value in
                field.options?.first(where: { $0.id == value }).map { "\($0.label) [\($0.id)]" } ?? value
            }.joined(separator: "; ")
            lines.append("- \(field.label): \(Self.clipped(shown, to: 600))")
        }
        if !answer.comment.isEmpty { lines.append("Comment: \(Self.clipped(answer.comment, to: 4_000))") }
        lines.append("Read the full record with workroom_questions.")
        return Self.clipped(lines.joined(separator: "\n"))
    }

    private func spendAskRate(_ asker: MailAddress) throws {
        let now = Date().timeIntervalSince1970
        let prior: WorkroomAskRate? = try optional("workroomAskRate", asker.description)
        var rate = prior ?? WorkroomAskRate(windowStart: now, count: 0)
        if now - rate.windowStart >= 3_600 { rate = WorkroomAskRate(windowStart: now, count: 0) }
        guard rate.count < WorkroomLimits.asksPerHour else { throw ControllerError.invalidInput("ask_rate") }
        rate.count += 1
        if prior == nil { try insert("workroomAskRate", asker.description, value: rate) }
        else { try update("workroomAskRate", asker.description, value: rate) }
    }

    /// Mail text is bounded by `Limits.text`'s default; a summary is cut to fit, never refused.
    static func clipped(_ text: String, to maximum: Int = 30_000) -> String {
        guard text.utf8.count > maximum else { return text }
        var result = ""
        for character in text {
            guard result.utf8.count + String(character).utf8.count <= maximum - 3 else { break }
            result.append(character)
        }
        return result + "…"
    }
}

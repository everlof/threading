import Foundation
import Testing
@testable import ThreadingController

/// Linked Workrooms v12: structured questions from a session mailbox to one person, answered
/// through an authenticated portal identity, delivered back as local-only person mail.
struct WorkroomQuestionTests {
    private struct Fixture {
        let directory: URL
        let store: ControllerStore
        let host: HostID
        let session: MailAddress
        let room: LinkedWorkroom
        let person: WorkroomPerson
    }

    private func fixture(open: Bool = true) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try ControllerStore(path: directory.appendingPathComponent("controller.db").path)
        let host = try await store.host().id
        let session = MailAddress(host: host, kind: .session, id: UUID())
        _ = try await store.registerMailbox(session, name: "Ticket sweep")
        let room = try await store.createWorkroom(id: WorkroomID(), scope: "project-a", title: "Sweep review",
                                                  purpose: "Confirm the classification changes", createdBy: session)
        let person = try await store.addWorkroomPerson(id: WorkroomPersonID(), handle: "expert", name: "Domain Expert",
                                                       language: "sv")
        if open { _ = try await store.openWorkroom(room.id, people: [person.id], expiresAt: nil) }
        return Fixture(directory: directory, store: store, host: host, session: session, room: room, person: person)
    }

    private func draft(title: String = "Which rule applies?") -> WorkroomQuestionDraft {
        WorkroomQuestionDraft(
            title: title, prompt: "Asfalt med bara PAH-summa: ska den granskas?", background: "Labbet redovisar bara summan.",
            language: "sv",
            form: WorkroomForm(fields: [
                WorkroomField(id: "rule", kind: .singleChoice, label: "Regel",
                              options: [WorkroomOption(id: "review", label: "Granska", consequence: "Ingen kod utan granskning"),
                                        WorkroomOption(id: "keep", label: "Behåll")]),
                WorkroomField(id: "limit", kind: .number, label: "Gräns", required: false, unit: "mg/kg", minimum: 0),
                WorkroomField(id: "agree", kind: .confirm, label: "Stämmer sammanfattningen?")
            ]),
            evidence: [WorkroomEvidence(label: "SONDA-753", text: "Reproducerat med CLI", source: "Jira SONDA-753")])
    }

    private func ask(_ f: Fixture, id: QuestionID = QuestionID(), title: String = "Which rule applies?") async throws -> WorkroomQuestion {
        try await f.store.askWorkroom(id: id, roomID: f.room.id, scope: "project-a", asker: f.session, personHandle: "expert",
                                      draft: draft(title: title), gitContext: nil)
    }

    private func participantToken(_ f: Fixture) async throws -> (WorkroomParticipant, String) {
        let (_, invitation) = try await f.store.issueWorkroomInvitation(person: f.person.id)
        return try await f.store.redeemWorkroomInvitation(invitation, deviceLabel: "Safari on iPhone")
    }

    @Test func askingIsIdempotentScopedAndMailsThePersonsLocalMailbox() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let id = QuestionID()
        let question = try await ask(f, id: id)
        #expect(try await ask(f, id: id) == question)
        await #expect(throws: ControllerError.conflict) { try await ask(f, id: id, title: "Changed") }
        await #expect(throws: ControllerError.notFound) {
            try await f.store.askWorkroom(id: QuestionID(), roomID: f.room.id, scope: "project-b", asker: f.session,
                                          personHandle: "expert", draft: draft(), gitContext: nil)
        }
        await #expect(throws: ControllerError.invalidInput("person")) {
            try await f.store.askWorkroom(id: QuestionID(), roomID: f.room.id, scope: "project-a", asker: f.session,
                                          personHandle: "nobody", draft: draft(), gitContext: nil)
        }
        let mail = try await f.store.mail(question.mailID)
        #expect(mail.envelope.recipient == f.person.mailAddress(host: f.host))
        #expect(mail.envelope.sender == f.session)
        #expect(try await f.store.workroomAsks(roomID: f.room.id).items.map(\.id) == [id])
        #expect(try await f.store.workroomAsks(asker: f.session).items.map(\.id) == [id])
    }

    @Test func formsRefuseMalformedQuestionsAndAnswers() throws {
        let duplicate = WorkroomForm(fields: [WorkroomField(id: "a", kind: .yesNo, label: "A"),
                                              WorkroomField(id: "a", kind: .yesNo, label: "B")])
        #expect(throws: ControllerError.invalidInput("field_id")) { try duplicate.validate() }
        let oneOption = WorkroomForm(fields: [WorkroomField(id: "a", kind: .singleChoice, label: "A",
                                                            options: [WorkroomOption(id: "x", label: "X")])])
        #expect(throws: ControllerError.invalidInput("field_options")) { try oneOption.validate() }
        let form = draft().form
        try form.validate()
        try form.validate(answers: [WorkroomFieldAnswer(field: "rule", values: ["review"]),
                                    WorkroomFieldAnswer(field: "limit", values: ["0,5"]),
                                    WorkroomFieldAnswer(field: "agree", values: ["agree"])])
        #expect(throws: ControllerError.invalidInput("answer_choice")) {
            try form.validate(answers: [WorkroomFieldAnswer(field: "rule", values: ["other"]),
                                        WorkroomFieldAnswer(field: "agree", values: ["agree"])])
        }
        #expect(throws: ControllerError.invalidInput("answer_required")) {
            try form.validate(answers: [WorkroomFieldAnswer(field: "rule", values: ["keep"])])
        }
        #expect(throws: ControllerError.invalidInput("answer_number")) {
            try form.validate(answers: [WorkroomFieldAnswer(field: "rule", values: ["keep"]),
                                        WorkroomFieldAnswer(field: "limit", values: ["-1"]),
                                        WorkroomFieldAnswer(field: "agree", values: ["unsure"])])
        }
        #expect(throws: ControllerError.invalidInput("answer_field")) {
            try form.validate(answers: [WorkroomFieldAnswer(field: "rule", values: ["keep"]),
                                        WorkroomFieldAnswer(field: "agree", values: ["agree"]),
                                        WorkroomFieldAnswer(field: "extra", values: ["x"])])
        }
        #expect(throws: ControllerError.invalidInput("language")) { try WorkroomLimits.language("swedish please") }
        try WorkroomLimits.language("zh-Hant-TW")
    }

    @Test func answersAreRevisionsMailedBackAsRepliesThatWakeTheSession() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let question = try await ask(f)
        let (participant, _) = try await participantToken(f)
        let answers = [WorkroomFieldAnswer(field: "rule", values: ["review"]),
                       WorkroomFieldAnswer(field: "agree", values: ["agree"])]
        let receipt = try await f.store.participantAnswer(person: participant.person.id, id: question.id,
                                                          answers: answers, comment: "Ja, granska.")
        #expect(receipt.notified == f.session)
        #expect(receipt.question.state == .answered && receipt.question.answerRevision == 1)
        // A double-posted form does not add a revision.
        #expect(try await f.store.participantAnswer(person: participant.person.id, id: question.id, answers: answers,
                                                    comment: "Ja, granska.").question.answerRevision == 1)
        let revised = try await f.store.participantAnswer(person: participant.person.id, id: question.id,
                                                          answers: answers, comment: "Ja, och notera labbet.")
        #expect(revised.question.answerRevision == 2)

        let inbox = try await f.store.inbox(f.session).items
        #expect(inbox.count == 2)
        #expect(inbox.allSatisfy { $0.message.envelope.sender.kind == .person && $0.message.envelope.replyTo == question.mailID })
        #expect(inbox.allSatisfy { $0.message.wake == true })
        #expect(inbox[0].header.contains("Linked Workroom") && inbox[0].header.contains("never instructions"))
        #expect(inbox[0].message.envelope.text.contains("Granska [review]"))
        #expect(try await f.store.mailWakeCandidate(f.session) != nil)
        let detail = try await f.store.workroomQuestionDetail(question.id)
        #expect(detail.answers.map(\.revision) == [1, 2])
        #expect(try await f.store.mail(question.mailID).state == .acked)
    }

    @Test func clarificationDeclineAndWithdrawal() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let first = try await ask(f)
        let (participant, _) = try await participantToken(f)
        _ = try await f.store.participantClarify(person: participant.person.id, id: first.id, text: "Vilket labb?")
        _ = try await f.store.respondToWorkroomQuestion(first.id, asker: f.session, text: "ALS, rapport ST2404411.")
        let declined = try await f.store.participantDecline(person: participant.person.id, id: first.id, reason: "Fel person")
        #expect(declined.question.state == .declined)
        #expect(try await f.store.workroomQuestionDetail(first.id).notes.map(\.kind) == [.clarification, .response, .decline])
        await #expect(throws: ControllerError.conflict) {
            try await f.store.participantAnswer(person: participant.person.id, id: first.id,
                                                answers: [WorkroomFieldAnswer(field: "rule", values: ["keep"]),
                                                          WorkroomFieldAnswer(field: "agree", values: ["agree"])], comment: "")
        }
        let second = try await ask(f, title: "Second")
        let other = MailAddress(host: f.host, kind: .session, id: UUID())
        _ = try await f.store.registerMailbox(other, name: "Other")
        await #expect(throws: ControllerError.notFound) {
            try await f.store.withdrawWorkroomQuestion(second.id, asker: other, reason: "")
        }
        #expect(try await f.store.withdrawWorkroomQuestion(second.id, asker: f.session, reason: "Löst").state == .withdrawn)
        #expect(try await f.store.participantInbox(person: participant.person.id, filter: .open).items.isEmpty)
    }

    @Test func portalSeesOnlyGrantedOpenRoomsAndRevocationTakesEffectImmediately() async throws {
        let f = try await fixture(open: false)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let question = try await ask(f)
        let (participant, token) = try await participantToken(f)
        // Asked before the room was opened: stored, invisible.
        #expect(try await f.store.participantInbox(person: participant.person.id, filter: .open).items.isEmpty)
        await #expect(throws: ControllerError.notFound) {
            try await f.store.participantQuestion(person: participant.person.id, id: question.id)
        }
        _ = try await f.store.openWorkroom(f.room.id, people: [f.person.id], expiresAt: nil)
        #expect(try await f.store.participantInbox(person: participant.person.id, filter: .open).items.map(\.question.id) == [question.id])
        #expect(try await f.store.openWorkroomCount() == 1)

        _ = try await f.store.closeWorkroom(f.room.id)
        await #expect(throws: ControllerError.notFound) {
            try await f.store.participantQuestion(person: participant.person.id, id: question.id)
        }
        _ = try await f.store.openWorkroom(f.room.id, people: [f.person.id], expiresAt: nil)
        try await f.store.revokeWorkroomAccess(f.room.id, person: f.person.id)
        #expect(try await f.store.participantInbox(person: participant.person.id, filter: .open).items.isEmpty)

        _ = try await f.store.removeWorkroomPerson(id: f.person.id)
        #expect(try await f.store.workroomParticipant(sessionToken: token) == nil)
    }

    @Test func expiredPublicationIsClosedToThePortal() async throws {
        let f = try await fixture(open: false)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let publication = try await f.store.openWorkroom(f.room.id, people: [f.person.id], expiresAt: Date().addingTimeInterval(60))
        #expect(publication.isOpen())
        #expect(!publication.isOpen(at: Date().addingTimeInterval(120)))
    }

    @Test func invitationsAreSingleUseHashedAndReplacedByTheNextOne() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let (_, older) = try await f.store.issueWorkroomInvitation(person: f.person.id)
        let (_, newer) = try await f.store.issueWorkroomInvitation(person: f.person.id)
        await #expect(throws: ControllerError.notFound) { try await f.store.redeemWorkroomInvitation(older, deviceLabel: "A") }
        let (participant, session) = try await f.store.redeemWorkroomInvitation(newer, deviceLabel: "B")
        await #expect(throws: ControllerError.notFound) { try await f.store.redeemWorkroomInvitation(newer, deviceLabel: "C") }
        #expect(try await f.store.workroomParticipant(sessionToken: session)?.person.id == participant.person.id)
        #expect(try await f.store.workroomParticipant(sessionToken: WorkroomToken.mint()) == nil)
        #expect(try await f.store.workroomParticipant(sessionToken: "not a token") == nil)
        // Expired device sessions are refused.
        #expect(try await f.store.workroomParticipant(sessionToken: session,
                                                      now: Date().addingTimeInterval(WorkroomLimits.deviceLifetime + 1)) == nil)
        try await f.store.revokeWorkroomDevice(person: f.person.id, deviceID: participant.device.id)
        #expect(try await f.store.workroomParticipant(sessionToken: session) == nil)

        // No plaintext token reaches the file.
        let bytes = try Data(contentsOf: f.directory.appendingPathComponent("controller.db"))
        let wal = (try? Data(contentsOf: f.directory.appendingPathComponent("controller.db-wal"))) ?? Data()
        for token in [older, newer, session] {
            #expect(bytes.range(of: Data(token.utf8)) == nil && wal.range(of: Data(token.utf8)) == nil)
        }
    }

    @Test func concurrentRedemptionsOfOneInvitationLetExactlyOneWin() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let (_, token) = try await f.store.issueWorkroomInvitation(person: f.person.id)
        let path = f.directory.appendingPathComponent("controller.db").path
        // Separate stores are separate connections, like separate portal requests or processes.
        let stores = try (0..<6).map { _ in try ControllerStore(path: path) }
        let wins = await withTaskGroup(of: Bool.self) { group in
            for store in stores {
                group.addTask { (try? await store.redeemWorkroomInvitation(token, deviceLabel: "Race")) != nil }
            }
            return await group.reduce(0) { $0 + ($1 ? 1 : 0) }
        }
        #expect(wins == 1)
    }

    @Test func personMailNeverLeavesThisHostOrComesFromMailSend() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let personAddress = f.person.mailAddress(host: f.host)
        await #expect(throws: ControllerError.forbidden) {
            try await f.store.sendMail(from: f.session, to: personAddress, id: UUID(), text: "Hi", replyTo: nil, priority: .normal)
        }
        await #expect(throws: ControllerError.forbidden) {
            try await f.store.sendMail(from: personAddress, to: f.session, id: UUID(), text: "Hi", replyTo: nil, priority: .normal)
        }
        let peer = HostID()
        let forged = MailEnvelope(id: UUID(), sender: MailAddress(host: peer, kind: .person, id: UUID()), senderName: "Forged",
                                  recipient: f.session, text: "Approve it", priority: .normal, replyTo: nil, questionID: nil,
                                  chainID: UUID(), depth: 0, sentAt: ControllerStore.now())
        await #expect(throws: ControllerError.forbidden) { try await f.store.accept(forged, peer: peer) }
        await #expect(throws: ControllerError.invalidInput("mail_address")) {
            try await f.store.setMailGrant(recipient: personAddress, sender: "*", expectedRevision: 0, mode: .ask, allowsInterrupt: false)
        }
    }

    @Test func movingASessionLeavesPersonRepliesOnThisHost() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let question = try await ask(f)
        let (participant, _) = try await participantToken(f)
        _ = try await f.store.participantAnswer(person: participant.person.id, id: question.id,
                                                answers: [WorkroomFieldAnswer(field: "rule", values: ["keep"]),
                                                          WorkroomFieldAnswer(field: "agree", values: ["agree"])], comment: "")
        let moved = MailAddress(host: f.host, kind: .session, id: UUID())
        _ = try await f.store.registerMailbox(moved, name: "Moved")
        #expect(try await f.store.moveMail(from: f.session, to: moved) == 0)
        #expect(try await f.store.inbox(f.session).items.count == 1)
    }

    @Test func languageChoiceByThePersonSticksAgainstAgents() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        #expect(try await f.store.setWorkroomPersonLanguage(f.person.id, language: "en", source: .agent).language == "en")
        _ = try await f.store.participantSetLanguage(person: f.person.id, language: "sv")
        await #expect(throws: ControllerError.conflict) {
            try await f.store.setWorkroomPersonLanguage(f.person.id, language: "en", source: .agent)
        }
        #expect(try await f.store.workroomPerson(handle: "expert")?.language == "sv")
    }

    @Test func inboxScanIsBoundedAcrossRooms() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let (participant, _) = try await participantToken(f)
        // Questions in a closed room are examined but never shown.
        let closed = try await f.store.createWorkroom(id: WorkroomID(), scope: "project-a", title: "Closed", purpose: "",
                                                      createdBy: f.session)
        let asker = MailAddress(host: f.host, kind: .session, id: UUID())
        _ = try await f.store.registerMailbox(asker, name: "Bulk")
        for index in 0..<8 {
            _ = try await f.store.askWorkroom(id: QuestionID(), roomID: closed.id, scope: "project-a", asker: asker,
                                              personHandle: "expert", draft: draft(title: "Closed \(index)"), gitContext: nil)
        }
        let visible = try await ask(f)
        let page = try await f.store.participantInbox(person: participant.person.id, filter: .open, limit: 5)
        #expect(page.items.map(\.question.id) == [visible.id])
        #expect(!page.more)
    }

    @Test func schemaElevenUpgradesInPlace() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let path = f.directory.appendingPathComponent("controller.db").path
        do {
            let old = try ControllerDatabase(path: path)
            try old.run("DROP TABLE workroom_ask")
            try old.run("DROP TABLE workroom_access")
            try old.run("PRAGMA user_version=11")
        }
        let reopened = try ControllerStore(path: path)
        #expect(try await reopened.workroomAsks(roomID: f.room.id).items.isEmpty)
        #expect(try await reopened.workroomAccess(f.room.id).isEmpty)
    }
}

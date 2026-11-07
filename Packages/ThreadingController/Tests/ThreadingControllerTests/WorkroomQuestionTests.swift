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

    @Test func reviewQuestionsAndRepliesIgnoreExhaustedLegacyAndAgentMailQuotas() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        struct LegacyRate: Codable, Equatable, Sendable { let windowStart: Double; let count: Int }
        let now = Date().timeIntervalSince1970
        let agentRate = LegacyRate(windowStart: now, count: MailLimits.sendsPerMinute)
        let personAddress = f.person.mailAddress(host: f.host)
        try await f.store.insert("workroomAskRate", f.session.description,
                                 value: LegacyRate(windowStart: now, count: 10))
        try await f.store.insert("mailRate", f.session.description, value: agentRate)
        try await f.store.insert("mailRate", personAddress.description, value: agentRate)
        await #expect(throws: ControllerError.invalidInput("send_rate")) {
            try await f.store.sendMail(from: f.session, to: f.session, id: UUID(), text: "Ordinary agent mail",
                                       replyTo: nil, priority: .normal, ownerAdmitted: true)
        }

        // Reopening must not revive the old hourly block or require anyone to reset counters.
        let reopened = try ControllerStore(path: f.directory.appendingPathComponent("controller.db").path)
        let answers = [WorkroomFieldAnswer(field: "rule", values: ["review"]),
                       WorkroomFieldAnswer(field: "agree", values: ["agree"])]
        for index in 0..<25 {
            let question = try await reopened.askWorkroom(
                id: QuestionID(), roomID: f.room.id, scope: "project-a", asker: f.session,
                personHandle: "expert", draft: draft(title: "Decision \(index)"), gitContext: nil
            )
            _ = try await reopened.participantAnswer(person: f.person.id, id: question.id,
                                                       answers: answers, comment: "")
        }
        #expect(try await reopened.inbox(f.session, limit: 50).items.count == 25)
        for address in [f.session, personAddress] {
            let unchanged: LegacyRate? = try await reopened.optional("mailRate", address.description)
            #expect(unchanged == agentRate)
        }
    }

    @Test func aFullReviewRoomPreservesRetriesAndReleasesCapacityWithoutWaiting() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let first = try await ask(f)
        for index in 1..<WorkroomLimits.openQuestionsPerRoom {
            _ = try await ask(f, title: "Decision \(index)")
        }
        #expect(WorkroomLimits.openQuestionsPerRoom >= 211)
        #expect(try await f.store.workroomSummary(f.room.id).openQuestions == WorkroomLimits.openQuestionsPerRoom)
        #expect(try await f.store.openWorkroomQuestionCount(f.room.id, person: f.person.id) == WorkroomLimits.openQuestionsPerRoom)
        #expect(try await f.store.openWorkroomQuestionCount(f.room.id, person: WorkroomPersonID()) == 0)
        #expect(try await ask(f, id: first.id) == first)
        let overflowID = QuestionID()
        await #expect(throws: ControllerError.invalidInput("room_full")) {
            try await ask(f, id: overflowID)
        }
        await #expect(throws: ControllerError.notFound) { try await f.store.mail(overflowID.rawValue) }
        await #expect(throws: ControllerError.notFound) { try await f.store.workroomQuestionDetail(overflowID) }

        _ = try await f.store.withdrawWorkroomQuestion(first.id, asker: f.session, reason: "Resolved")
        #expect(try await f.store.openWorkroomQuestionCount(f.room.id, person: f.person.id) == WorkroomLimits.openQuestionsPerRoom - 1)
        _ = try await ask(f, id: overflowID)
        var openIDs: [QuestionID] = []
        var cursor: Int64 = 0
        for _ in 0...WorkroomLimits.openQuestionsPerRoom / 100 {
            let page = try await f.store.participantInbox(person: f.person.id, filter: .open, cursor: cursor, limit: 100)
            #expect(page.items.count <= 100)
            openIDs += page.items.map(\.question.id)
            if !page.more { break }
            #expect(page.next > cursor)
            cursor = page.next
        }
        #expect(openIDs.count == WorkroomLimits.openQuestionsPerRoom)
        #expect(Set(openIDs).count == openIDs.count)
        #expect(!openIDs.contains(first.id) && openIDs.contains(overflowID))
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

    @Test func extendingAnInvitationPreservesItsTokenAcrossRestartAndItsSingleUse() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let (original, token) = try await f.store.issueWorkroomInvitation(person: f.person.id)
        let expiry = try #require(ControllerStore.date(original.expiresAt))
        let extended = try await f.store.extendWorkroomInvitation(
            person: f.person.id, invitationID: original.id, expectedExpiry: original.expiresAt,
            now: expiry.addingTimeInterval(-60)
        )
        #expect(extended.id == original.id && extended.issuedAt == original.issuedAt)
        #expect(extended.expiresAt == ControllerStore.timestamp(expiry.addingTimeInterval(WorkroomLimits.invitationLifetime)))
        await #expect(throws: ControllerError.conflict) {
            try await f.store.extendWorkroomInvitation(person: f.person.id, invitationID: original.id,
                                                       expectedExpiry: original.expiresAt)
        }
        let reopened = try ControllerStore(path: f.directory.appendingPathComponent("controller.db").path)
        #expect(try await reopened.latestWorkroomInvitation(person: f.person.id) == extended)
        let redeemed = try await reopened.redeemWorkroomInvitation(token, deviceLabel: "Safari", now: expiry.addingTimeInterval(1))
        #expect(redeemed.0.person.id == f.person.id)
        await #expect(throws: ControllerError.notFound) {
            try await reopened.redeemWorkroomInvitation(token, deviceLabel: "Again", now: expiry.addingTimeInterval(2))
        }
        await #expect(throws: ControllerError.notFound) {
            try await reopened.extendWorkroomInvitation(person: f.person.id, invitationID: extended.id,
                                                        expectedExpiry: extended.expiresAt)
        }
        for name in ["controller.db", "controller.db-wal"] {
            let bytes = (try? Data(contentsOf: f.directory.appendingPathComponent(name))) ?? Data()
            #expect(bytes.range(of: Data(token.utf8)) == nil)
        }
    }

    @Test func expiredPendingLinksCanBeExtendedWithoutReopeningRooms() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let (original, token) = try await f.store.issueWorkroomInvitation(person: f.person.id)
        let now = try #require(ControllerStore.date(original.expiresAt)).addingTimeInterval(60)
        await #expect(throws: ControllerError.notFound) {
            try await f.store.redeemWorkroomInvitation(token, deviceLabel: "Expired", now: now)
        }
        let closed = try await f.store.closeWorkroom(f.room.id)
        let extended = try await f.store.extendWorkroomInvitation(
            person: f.person.id, invitationID: original.id, expectedExpiry: original.expiresAt, now: now
        )
        #expect(extended.expiresAt == ControllerStore.timestamp(now.addingTimeInterval(WorkroomLimits.invitationLifetime)))
        #expect(try await f.store.workroomSummary(f.room.id).publication == closed)
        _ = try await f.store.redeemWorkroomInvitation(token, deviceLabel: "Renewed", now: now.addingTimeInterval(1))
    }

    @Test func invitationExtensionRefusesStaleIdentityRemovedPeopleAndInvalidDurations() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let (original, _) = try await f.store.issueWorkroomInvitation(person: f.person.id)
        for duration in [0, -1, Double.infinity, Double.nan, WorkroomLimits.invitationLifetime + 1] {
            await #expect(throws: ControllerError.invalidInput("lifetime")) {
                try await f.store.extendWorkroomInvitation(person: f.person.id, invitationID: original.id,
                                                           expectedExpiry: original.expiresAt, by: duration)
            }
        }
        let (replacement, _) = try await f.store.issueWorkroomInvitation(person: f.person.id)
        await #expect(throws: ControllerError.notFound) {
            try await f.store.extendWorkroomInvitation(person: f.person.id, invitationID: original.id,
                                                       expectedExpiry: original.expiresAt)
        }
        #expect(try await f.store.latestWorkroomInvitation(person: f.person.id) == replacement)
        _ = try await f.store.removeWorkroomPerson(id: f.person.id)
        await #expect(throws: ControllerError.notFound) {
            try await f.store.extendWorkroomInvitation(person: f.person.id, invitationID: replacement.id,
                                                       expectedExpiry: replacement.expiresAt)
        }
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

    @Test func anAgentReplyIsANewMessageUntilThePersonOpensOrActsOnIt() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let (participant, _) = try await participantToken(f)
        let person = participant.person.id
        let first = try await ask(f, title: "First")
        let second = try await ask(f, title: "Second")
        let before = try await f.store.participantInboxVersion(person: person)
        _ = try await f.store.participantClarify(person: person, id: first.id, text: "Vilket labb?")
        let mail = try #require(try await f.store.inbox(f.session).items.first)
        #expect(mail.message.envelope.text.contains("Vilket labb?"))
        #expect(mail.message.envelope.text.contains("workroom_respond, action message"))
        #expect(mail.message.wake == true)

        _ = try await f.store.respondToWorkroomQuestion(first.id, asker: f.session, text: "ALS, rapport ST2404411.")
        let replied = try await f.store.participantInboxVersion(person: person)
        #expect(replied != before)
        // Each question is in one section: the reply takes it out of the open list.
        let replies = try await f.store.participantInbox(person: person, filter: .replies)
        #expect(replies.items.map(\.question.id) == [first.id])
        #expect(replies.items.first?.reply == "ALS, rapport ST2404411.")
        #expect(try await f.store.participantInbox(person: person, filter: .open).items.map(\.question.id) == [second.id])

        // A second reply moves the question to the top again; the newest reply sorts first.
        _ = try await f.store.respondToWorkroomQuestion(second.id, asker: f.session, text: "Och den här?")
        _ = try await f.store.respondToWorkroomQuestion(first.id, asker: f.session, text: String(repeating: "å", count: 400))
        let both = try await f.store.participantInbox(person: person, filter: .replies)
        #expect(both.items.map(\.question.id) == [first.id, second.id])
        #expect((both.items.first?.reply?.utf8.count ?? 0) <= WorkroomLimits.replyPreviewBytes)
        let paged = try await f.store.participantInbox(person: person, filter: .replies, limit: 1)
        #expect(paged.items.map(\.question.id) == [first.id])
        let rest = try await f.store.participantInbox(person: person, filter: .replies, cursor: paged.next, limit: 1)
        #expect(rest.items.map(\.question.id) == [second.id])

        // Opening a question reads its replies; answering another clears that one.
        _ = try await f.store.participantQuestion(person: person, id: first.id)
        _ = try await f.store.participantAnswer(person: person, id: second.id,
                                                answers: [WorkroomFieldAnswer(field: "rule", values: ["keep"]),
                                                          WorkroomFieldAnswer(field: "agree", values: ["agree"])], comment: "")
        #expect(try await f.store.participantInbox(person: person, filter: .replies).items.isEmpty)
        #expect(try await f.store.participantInbox(person: person, filter: .open).items.map(\.question.id) == [first.id])
        #expect(try await f.store.participantInbox(person: person, filter: .recent).items.map(\.question.id) == [second.id])

        // A reply on an answered question brings it back; a withdrawal takes it away.
        _ = try await f.store.respondToWorkroomQuestion(second.id, asker: f.session, text: "Tack!")
        #expect(try await f.store.participantInbox(person: person, filter: .recent).items.isEmpty)
        #expect(try await f.store.participantInbox(person: person, filter: .replies).items.map(\.question.id) == [second.id])
        _ = try await f.store.withdrawWorkroomQuestion(second.id, asker: f.session, reason: "")
        #expect(try await f.store.participantInbox(person: person, filter: .replies).items.isEmpty)
    }

    @Test func aConversationHoldsSixtyMessagesAndAClosingNoteBeyondThem() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let (participant, _) = try await participantToken(f)
        let question = try await ask(f)
        for index in 0..<(WorkroomLimits.notes / 2) {
            _ = try await f.store.participantClarify(person: participant.person.id, id: question.id, text: "Fråga \(index)")
            _ = try await f.store.respondToWorkroomQuestion(question.id, asker: f.session, text: "Svar \(index)")
        }
        await #expect(throws: ControllerError.invalidInput("notes")) {
            try await f.store.participantClarify(person: participant.person.id, id: question.id, text: "En till")
        }
        _ = try await f.store.participantDecline(person: participant.person.id, id: question.id, reason: "Klart")
        let detail = try await f.store.participantQuestion(person: participant.person.id, id: question.id)
        #expect(detail.notes.count == WorkroomLimits.notes + 1)
        #expect(detail.notes.last?.kind == .decline)
    }

    @Test func theNextQuestionWrapsSkipsClosedRoomsAndEndsAtTheLast() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let (participant, _) = try await participantToken(f)
        let person = participant.person.id
        let closed = try await f.store.createWorkroom(id: WorkroomID(), scope: "project-a", title: "Closed", purpose: "",
                                                      createdBy: f.session)
        let first = try await ask(f, title: "First")
        let hidden = try await f.store.askWorkroom(id: QuestionID(), roomID: closed.id, scope: "project-a", asker: f.session,
                                                   personHandle: "expert", draft: draft(title: "Hidden"), gitContext: nil)
        let second = try await ask(f, title: "Second")
        let third = try await ask(f, title: "Third")
        #expect(try await f.store.participantNextQuestion(person: person, after: first.id) == second.id)
        #expect(try await f.store.participantNextQuestion(person: person, after: hidden.id) == second.id)
        #expect(try await f.store.participantNextQuestion(person: person, after: third.id) == first.id)
        for question in [first, second] {
            _ = try await f.store.participantDecline(person: person, id: question.id, reason: "Nej")
        }
        #expect(try await f.store.participantNextQuestion(person: person, after: third.id) == nil)
        #expect(try await f.store.participantNextQuestion(person: person, after: first.id) == third.id)
    }

    @Test func pageFingerprintsChangeWithWhatThePageShows() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let (participant, _) = try await participantToken(f)
        let person = participant.person.id
        let question = try await ask(f)
        let start = try await f.store.participantQuestionVersion(person: person, id: question.id)
        #expect(start == question.pageVersion)
        let inbox = try await f.store.participantInboxVersion(person: person)
        #expect(try await f.store.participantInboxVersion(person: person) == inbox)
        _ = try await f.store.respondToWorkroomQuestion(question.id, asker: f.session, text: "Hej")
        let replied = try await f.store.participantQuestionVersion(person: person, id: question.id)
        #expect(replied != start)
        #expect(try await f.store.participantQuestion(person: person, id: question.id).question.pageVersion == replied)
        _ = try await ask(f, title: "Another")
        #expect(try await f.store.participantInboxVersion(person: person) != inbox)
        let other = try await f.store.addWorkroomPerson(id: WorkroomPersonID(), handle: "other", name: "Other", language: "en")
        await #expect(throws: ControllerError.notFound) {
            try await f.store.participantQuestionVersion(person: other.id, id: question.id)
        }
    }

    @Test func theOwnerCommentsWithoutAnsweringAndBothOthersHearIt() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let (participant, _) = try await participantToken(f)
        let person = participant.person.id
        let question = try await ask(f)
        let note = try await f.store.ownerCommentOnWorkroomQuestion(question.id, ownerName: "David",
                                                                    text: "Tänk på asfalt med tjära.")
        #expect(note.author == .owner && note.kind == .comment && note.name == "David")
        // The person sees it as a new message, with who wrote it.
        let replies = try await f.store.participantInbox(person: person, filter: .replies)
        #expect(replies.items.map(\.question.id) == [question.id])
        #expect(replies.items.first?.reply == "David: Tänk på asfalt med tjära.")
        // The asking session hears it as a reply on the question's mail, and knows who wrote it.
        let mail = try #require(try await f.store.inbox(f.session).items.first)
        #expect(mail.message.envelope.replyTo == question.mailID)
        #expect(mail.message.envelope.text.contains("“David”, who owns this Mac, commented"))
        // The question is unchanged: still open, no answer.
        let detail = try await f.store.workroomQuestionDetail(question.id)
        #expect(detail.question.state == .open && detail.answers.isEmpty)
        #expect(detail.notes.map(\.author) == [.owner])
        _ = try await f.store.withdrawWorkroomQuestion(question.id, asker: f.session, reason: "")
        await #expect(throws: ControllerError.conflict) {
            try await f.store.ownerCommentOnWorkroomQuestion(question.id, ownerName: "David", text: "Sent")
        }
    }

    @Test func theOwnerPagesEveryQuestionNewestFirst() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let other = try await f.store.createWorkroom(id: WorkroomID(), scope: "project-b", title: "Other", purpose: "",
                                                     createdBy: f.session)
        var asked: [QuestionID] = []
        for index in 0..<5 { asked.append(try await ask(f, title: "Q\(index)").id) }
        asked.append(try await f.store.askWorkroom(id: QuestionID(), roomID: other.id, scope: "project-b", asker: f.session,
                                                   personHandle: "expert", draft: draft(title: "Elsewhere"),
                                                   gitContext: nil).id)
        let first = try await f.store.ownerWorkroomQuestions(limit: 4)
        #expect(first.items.map(\.question.id) == Array(asked.reversed().prefix(4)))
        #expect(first.more && first.items.first?.roomTitle == "Other" && first.items.first?.personName == "Domain Expert")
        let rest = try await f.store.ownerWorkroomQuestions(before: first.next, limit: 4)
        #expect(rest.items.map(\.question.id) == Array(asked.reversed().dropFirst(4)))
        #expect(!rest.more)
    }

    @Test func waitingCountsOpenAndUnreadOnceInVisibleRooms() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let (participant, _) = try await participantToken(f)
        let person = participant.person.id
        let closed = try await f.store.createWorkroom(id: WorkroomID(), scope: "project-a", title: "Closed", purpose: "",
                                                      createdBy: f.session)
        _ = try await f.store.askWorkroom(id: QuestionID(), roomID: closed.id, scope: "project-a", asker: f.session,
                                          personHandle: "expert", draft: draft(title: "Hidden"), gitContext: nil)
        let first = try await ask(f, title: "First")
        let second = try await ask(f, title: "Second")
        #expect(try await f.store.participantWaitingCount(person: person) == 2)
        // A message on an open question does not count it twice.
        _ = try await f.store.respondToWorkroomQuestion(first.id, asker: f.session, text: "Hej")
        #expect(try await f.store.participantWaitingCount(person: person) == 2)
        _ = try await f.store.participantAnswer(person: person, id: second.id,
                                                answers: [WorkroomFieldAnswer(field: "rule", values: ["keep"]),
                                                          WorkroomFieldAnswer(field: "agree", values: ["agree"])], comment: "")
        #expect(try await f.store.participantWaitingCount(person: person) == 1)
        // A message on an answered question brings it back until it is read.
        _ = try await f.store.respondToWorkroomQuestion(second.id, asker: f.session, text: "Tack")
        #expect(try await f.store.participantWaitingCount(person: person) == 2)
        _ = try await f.store.participantQuestion(person: person, id: second.id)
        #expect(try await f.store.participantWaitingCount(person: person) == 1)
    }

    @Test func aRoomMovesToItsRepositoryWithItsQuestionsAndOnlyOnce() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let question = try await ask(f)
        let repository = "repository:/repo/sonda/.git"
        #expect(try await f.store.rescopeWorkroom(f.room.id, from: "project-a", to: repository))
        #expect(!(try await f.store.rescopeWorkroom(f.room.id, from: "project-a", to: repository)))
        #expect(try await f.store.workrooms(scope: "project-a").items.isEmpty)
        let moved = try #require(try await f.store.workrooms(scope: repository).items.first)
        #expect(moved.id == f.room.id && moved.createdBy == f.room.createdBy && moved.title == f.room.title)
        // Its questions, access and publication are keyed by the room, so they move with it.
        _ = try await f.store.askWorkroom(id: QuestionID(), roomID: f.room.id, scope: repository, asker: f.session,
                                          personHandle: "expert", draft: draft(title: "After"), gitContext: nil)
        await #expect(throws: ControllerError.notFound) {
            try await f.store.askWorkroom(id: QuestionID(), roomID: f.room.id, scope: "project-a", asker: f.session,
                                          personHandle: "expert", draft: draft(title: "Old scope"), gitContext: nil)
        }
        #expect(try await f.store.workroomAsks(roomID: f.room.id).items.first?.id == question.id)
        #expect(try await f.store.workroomPublication(f.room.id).isOpen())
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

/// A session is tied to the rooms it created or asked in, until they close.
struct WorkroomTieTests {
    @Test func creatingOrAskingTiesAMailboxUntilTheRoomCloses() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ControllerStore(path: directory.appendingPathComponent("controller.db").path)
        let host = try await store.host().id
        let creator = MailAddress(host: host, kind: .session, id: UUID())
        let asker = MailAddress(host: host, kind: .session, id: UUID())
        let bystander = MailAddress(host: host, kind: .session, id: UUID())
        for (address, name) in [(creator, "Creator"), (asker, "Asker"), (bystander, "Bystander")] {
            _ = try await store.registerMailbox(address, name: name)
        }
        let room = try await store.createWorkroom(id: WorkroomID(), scope: "p", title: "Room", purpose: "", createdBy: creator)
        _ = try await store.addWorkroomPerson(id: WorkroomPersonID(), handle: "expert", name: "Expert", language: "sv")
        _ = try await store.askWorkroom(id: QuestionID(), roomID: room.id, scope: "p", asker: asker, personHandle: "expert",
                                        draft: WorkroomQuestionDraft(title: "Q", prompt: "Why?", language: "sv"),
                                        gitContext: nil)
        #expect(try await store.workroomTies(creator).map(\.id) == [room.id])
        #expect(try await store.workroomTies(asker).map(\.id) == [room.id])
        #expect(try await store.workroomTies(bystander).isEmpty)
        // Re-asking does not duplicate the tie.
        _ = try await store.askWorkroom(id: QuestionID(), roomID: room.id, scope: "p", asker: asker, personHandle: "expert",
                                        draft: WorkroomQuestionDraft(title: "Q2", prompt: "And?", language: "sv"),
                                        gitContext: nil)
        #expect(try await store.workroomTies(asker).count == 1)
        _ = try await store.openWorkroom(room.id, people: [try #require(await store.workroomPerson(handle: "expert")).id], expiresAt: nil)
        _ = try await store.closeWorkroom(room.id)
        #expect(try await store.workroomTies(creator).isEmpty)
    }
}

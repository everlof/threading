import XCTest
import ThreadingController
import ThreadingRemoteKit
@testable import Threading

/// Linked Workrooms through the remote door: who may ask, which requests parse, what a phone is
/// shown, and that the two vocabularies a form is spoken in stay one vocabulary.
@MainActor
final class WorkroomRemoteBridgeTests: XCTestCase {

    // MARK: - Viewers

    func testOnlyAWorkroomMembershipOrAnOwnerDeviceIsAViewer() {
        let person = WorkroomPersonID()
        let participant = RemoteAuthorization(shareID: "m", capability: .interact, scope: .workroomPerson(person),
                                              principal: .guest)
        XCTAssertEqual(WorkroomRemoteViewer(participant, workroomsEnabled: true), .participant(person))
        let owner = RemoteAuthorization(shareID: "o", capability: .interact, scope: .allSessions)
        XCTAssertEqual(WorkroomRemoteViewer(owner, workroomsEnabled: true), .owner(canComment: true))
        let viewOnlyOwner = RemoteAuthorization(shareID: "v", capability: .view, scope: .allSessions)
        XCTAssertEqual(WorkroomRemoteViewer(viewOnlyOwner, workroomsEnabled: true), .owner(canComment: false))
        let chatGuest = RemoteAuthorization(shareID: "g", capability: .interact, scope: .session(SessionID()))
        XCTAssertNil(WorkroomRemoteViewer(chatGuest, workroomsEnabled: true))
        // Switching Workrooms off closes the routes to everyone, the person included.
        XCTAssertNil(WorkroomRemoteViewer(participant, workroomsEnabled: false))
        XCTAssertNil(WorkroomRemoteViewer(owner, workroomsEnabled: false))
    }

    func testAWorkroomMembershipReachesNoChatAndNoTerminal() {
        let scope = RemoteScope.workroomPerson(WorkroomPersonID())
        XCTAssertFalse(scope.covers(SessionID()))
        XCTAssertFalse(scope.covers(TerminalID()))
        let authorization = RemoteAuthorization(shareID: "m", capability: .interact, scope: scope, principal: .guest)
        XCTAssertFalse(authorization.canManageHost)
        XCTAssertFalse(authorization.canApprovePermissions)
        XCTAssertFalse(authorization.canUseUniversalSearch)
        XCTAssertFalse(authorization.canReadHostUsage)
    }

    // MARK: - Routes

    func testRoutesParseBeforeAnythingIsRead() {
        let question = QuestionID()
        let none: (String) -> String? = { _ in nil }
        XCTAssertEqual(WorkroomRemoteRoute(method: "GET", subpath: RemoteWorkroomPath.inbox, query: none),
                       .inbox(replies: 0, open: 0, recent: 0))
        XCTAssertEqual(WorkroomRemoteRoute(method: "GET", subpath: RemoteWorkroomPath.inbox, query: {
            $0 == RemoteWorkroomPath.Cursor.open.rawValue ? "40" : nil
        }), .inbox(replies: 0, open: 40, recent: 0))
        XCTAssertNil(WorkroomRemoteRoute(method: "GET", subpath: RemoteWorkroomPath.inbox, query: { _ in "-1" }))
        XCTAssertEqual(WorkroomRemoteRoute(method: "GET", subpath: RemoteWorkroomPath.state, query: none), .state)
        XCTAssertEqual(WorkroomRemoteRoute(method: "GET", subpath: "\(RemoteWorkroomPath.question)/\(question)", query: none),
                       .question(question))
        func post(_ action: RemoteWorkroomPath.Action, _ body: some Encodable) -> WorkroomRemoteRoute? {
            WorkroomRemoteRoute(method: "POST", subpath: "\(RemoteWorkroomPath.question)/\(question)/\(action.rawValue)",
                                query: none, body: (try? JSONEncoder().encode(body)) ?? Data())
        }
        let answer = RemoteWorkroomAnswerRequestDTO(
            answers: [RemoteWorkroomFieldAnswerDTO(field: "ok", values: [RemoteWorkroomYesNo.yes.rawValue])], comment: "")
        XCTAssertEqual(post(.answer, answer), .answer(question, answer))
        XCTAssertEqual(post(.message, RemoteWorkroomMessageRequestDTO(text: "Hej")), .message(question, "Hej"))
        XCTAssertEqual(post(.decline, RemoteWorkroomMessageRequestDTO(text: "Nej")), .decline(question, "Nej"))
        XCTAssertEqual(post(.message, RemoteWorkroomMessageRequestDTO(text: "Hej"))?.isMutation, true)
        // A write whose body is not its request is no request.
        XCTAssertNil(post(.answer, RemoteWorkroomMessageRequestDTO(text: "Hej")))
        // A read is never a write, an unknown action is nothing, and an id is one segment.
        XCTAssertNil(WorkroomRemoteRoute(method: "POST", subpath: RemoteWorkroomPath.inbox, query: none))
        XCTAssertNil(WorkroomRemoteRoute(method: "GET", subpath: "\(RemoteWorkroomPath.question)/\(question)/answer",
                                         query: none))
        XCTAssertNil(WorkroomRemoteRoute(method: "POST", subpath: "\(RemoteWorkroomPath.question)/\(question)/approve",
                                         query: none))
        XCTAssertNil(WorkroomRemoteRoute(method: "GET", subpath: "\(RemoteWorkroomPath.question)/not-an-id", query: none))
        XCTAssertNil(WorkroomRemoteRoute(method: "GET", subpath: "rooms", query: none))
    }

    // MARK: - Projection

    func testAParticipantAnswersAndTheOwnerOnlyComments() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let detail = try await fixture.store.workroomQuestionDetail(fixture.question.id)
        let participant = WorkroomRemoteBridge.project(detail, viewer: .participant(detail.question.person), next: nil)
        XCTAssertTrue(participant.canAnswer && participant.canMessage && participant.canDecline)
        XCTAssertEqual(participant.viewer, .participant)
        let owner = WorkroomRemoteBridge.project(detail, viewer: .owner(canComment: true), next: nil)
        XCTAssertFalse(owner.canAnswer || owner.canDecline)
        XCTAssertTrue(owner.canMessage)
        XCTAssertFalse(WorkroomRemoteBridge.project(detail, viewer: .owner(canComment: false), next: nil).canMessage)
        _ = try await fixture.store.participantDecline(person: fixture.person.id, id: fixture.question.id, reason: "Nej")
        let closed = WorkroomRemoteBridge.project(try await fixture.store.workroomQuestionDetail(fixture.question.id),
                                                  viewer: .participant(detail.question.person), next: nil)
        XCTAssertFalse(closed.canAnswer || closed.canMessage || closed.canDecline)
    }

    func testTheConversationIsInStoredOrderInThePersonsWords() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let (store, session, person, question) = (fixture.store, fixture.session, fixture.person, fixture.question)
        _ = try await store.participantClarify(person: person.id, id: question.id, text: "Alla labb?")
        _ = try await store.respondToWorkroomQuestion(question.id, asker: session, text: "Ja.")
        _ = try await store.participantAnswer(person: person.id, id: question.id,
                                              answers: [WorkroomFieldAnswer(field: "ok", values: [WorkroomYesNo.yes.rawValue])],
                                              comment: "Granska.")
        _ = try await store.ownerCommentOnWorkroomQuestion(question.id, ownerName: "David", text: "Bra.")

        let dto = WorkroomRemoteBridge.project(try await store.workroomQuestionDetail(question.id),
                                               viewer: .participant(person.id), next: nil)
        XCTAssertEqual(dto.entries.map(\.author), [.person, .agent, .person, .owner])
        XCTAssertEqual(dto.entries.map(\.kind), [.message, .message, .answer, .message])
        XCTAssertEqual(dto.entries[2].shown, [RemoteWorkroomShownAnswerDTO(label: "Stämmer det?", value: "Ja")])
        XCTAssertEqual(dto.entries[2].text, "Granska.")
        XCTAssertEqual(dto.entries[3].authorName, "David")
        XCTAssertEqual(dto.latestAnswer, [RemoteWorkroomFieldAnswerDTO(field: "ok", values: ["yes"])])
        let version = try await store.participantQuestionVersion(person: person.id, id: question.id)
        XCTAssertEqual(dto.version, version)
    }

    // MARK: - Checkouts

    /// Every checkout and worktree of a repository reaches the same rooms, so a chat that moves to
    /// another worktree keeps the rooms it created and asked in.
    func testRoomsBelongToTheRepositoryNotTheCheckout() {
        var main = Project(name: "sonda", folderURL: URL(fileURLWithPath: "/repo/sonda"))
        var worktree = Project(name: "sonda-341", folderURL: URL(fileURLWithPath: "/repo/sonda-341"))
        main.lastKnownRepositoryIdentity = "/repo/sonda/.git"
        worktree.lastKnownRepositoryIdentity = "/repo/sonda/.git"
        XCTAssertEqual(WorkroomAgentCommandService.scope(for: main), WorkroomAgentCommandService.scope(for: worktree))
        let folder = Project(name: "notes", folderURL: URL(fileURLWithPath: "/notes"))
        XCTAssertEqual(WorkroomAgentCommandService.scope(for: folder),
                       WorkroomAgentCommandService.legacyScope(for: folder.id))
        XCTAssertNotEqual(WorkroomAgentCommandService.scope(for: folder), WorkroomAgentCommandService.scope(for: main))
    }

    // MARK: - Invitation code

    /// The code carries the app's own invitation, so the camera opens Threading directly; the
    /// copied link stays the web link. Copy Link keeps the sheet up and says it copied.
    func testTheInvitationCodeOpensTheAppAndCopyingKeepsItOpen() throws {
        let payload = "threading://pair#" + String(repeating: "a", count: 64)
        let web = try XCTUnwrap(RemoteInvitationWebLink.url(appPayload: payload, origin: RemoteInvitationWebLink.productionOrigin))
        XCTAssertEqual(WorkroomAppInvitationAlert.scannedPayload(for: web), payload)
        let other = try XCTUnwrap(URL(string: "https://192.168.1.4:8760#token.code"))
        XCTAssertEqual(WorkroomAppInvitationAlert.scannedPayload(for: other), other.absoluteString)

        let alert = WorkroomAppInvitationAlert.makeAlert(web, personName: "Viktor", expiresAt: Date())
        XCTAssertTrue(alert.messageText.contains("Viktor") && alert.informativeText.contains("Viktor"))
        XCTAssertEqual(alert.buttons.count, 2)
        let code = try XCTUnwrap(alert.accessoryView as? ScannableCodeView)
        XCTAssertTrue(code.hasCode)
        let pasteboard = NSPasteboard.general
        let before = code.caption
        XCTAssertEqual(alert.shouldChooseButton?(WorkroomAppInvitationDefaults.copyButtonIndex), false)
        XCTAssertNotEqual(code.caption, before)
        XCTAssertEqual(pasteboard.string(forType: .string)?.hasPrefix(RemoteInvitationWebLink.productionOrigin.absoluteString), true)
        XCTAssertEqual(alert.shouldChooseButton?(0), true)
    }

    // MARK: - One vocabulary

    func testTheWireAndTheFormSpellAnswersTheSameWay() {
        XCTAssertEqual(RemoteWorkroomYesNo.allCases.map(\.rawValue), WorkroomYesNo.allCases.map(\.rawValue))
        XCTAssertEqual(RemoteWorkroomConfirmation.allCases.map(\.rawValue), WorkroomConfirmation.allCases.map(\.rawValue))
        for kind in WorkroomFieldKind.allCases {
            guard case .unknown = RemoteWorkroomFieldKind(rawValue: kind.rawValue) else { continue }
            XCTFail("the wire has no name for the form's \(kind.rawValue)")
        }
        for state in [WorkroomQuestionState.open, .answered, .declined, .withdrawn] {
            guard case .unknown = RemoteWorkroomQuestionState(rawValue: state.rawValue) else { continue }
            XCTFail("the wire has no name for the state \(state.rawValue)")
        }
    }

    func testOnlyABrokerThatKnowsWorkroomsIsSentOne() {
        let current = RemoteNotificationBrokerCompatibility.workroomVersion
        XCTAssertTrue(RemoteNotificationBrokerCompatibility.delivers(.workroom, brokerVersion: current))
        XCTAssertFalse(RemoteNotificationBrokerCompatibility.delivers(.workroom, brokerVersion: current - 1))
        XCTAssertEqual(RemoteNotificationKind.workroom.lifecycle, .independentEvent)
    }

    func testAWorkroomMembershipSurvivesTheShareStore() throws {
        let person = WorkroomPersonID()
        let record = RemoteGuestShareRecord(
            id: "share-w", targetKind: .workroomPerson, sessionID: person.description,
            invitationToken: String(repeating: "c", count: 43), capability: .interact, canApprovePermissions: false,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000), expiresAt: Date(timeIntervalSince1970: 1_700_086_400),
            members: []
        )
        let store = RemoteGuestShareKeychainStore(dataProtection: false, keychain: InMemoryKeychainItemAccess())
        try store.save([record])
        XCTAssertEqual(try store.load(), [record])
    }

    // MARK: - Fixtures

    /// A real store with one open room, one person and one yes/no question to them.
    private struct Fixture {
        let directory: URL
        let store: ControllerStore
        let session: MailAddress
        let person: WorkroomPerson
        let question: WorkroomQuestion

        init() async throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("workroom-remote-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            store = try ControllerStore(path: directory.appendingPathComponent("controller.db").path)
            session = MailAddress(host: try await store.host().id, kind: .session, id: UUID())
            _ = try await store.registerMailbox(session, name: "Ticket sweep")
            let room = try await store.createWorkroom(id: WorkroomID(), scope: "p", title: "Sweep", purpose: "",
                                                      createdBy: session)
            person = try await store.addWorkroomPerson(id: WorkroomPersonID(), handle: "viktor", name: "Viktor",
                                                       language: "sv")
            _ = try await store.openWorkroom(room.id, people: [person.id], expiresAt: nil)
            question = try await store.askWorkroom(
                id: QuestionID(), roomID: room.id, scope: "p", asker: session, personHandle: "viktor",
                draft: WorkroomQuestionDraft(
                    title: "Granska?", prompt: "Bara summan.", language: "sv",
                    form: WorkroomForm(fields: [WorkroomField(id: "ok", kind: .yesNo, label: "Stämmer det?")])
                ),
                gitContext: nil)
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }
    }
}

import AppKit
import XCTest
import ThreadingRemoteKit
@testable import Threading

@MainActor
final class ConversationQuestionTests: XCTestCase {
    static var parameters: [String: Any] {
        ["threadId": "thread-1", "turnId": "turn-1", "itemId": "ask-1", "isBlocking": true,
         "questions": [["id": "density", "header": "Density", "question": "How much work detail should the chat show?",
                        "isOther": true, "isSecret": false,
                        "options": [["label": "Compact", "description": "Keep completed work behind a disclosure."],
                                    ["label": "Expanded", "description": "Show every step in the transcript."]]]]]
    }

    func testRequestPreservesIDsAndRejectsIncompleteAndOversizedAnswers() throws {
        let request = try XCTUnwrap(ConversationQuestionRequest.codex(Self.parameters))
        XCTAssertEqual(request.questions.map(\.id), ["density"])
        XCTAssertTrue(request.blocksTurn)
        XCTAssertTrue(request.accepts(["density": "Compact"]))
        XCTAssertTrue(request.accepts(["density": "Show only failed tools"]))
        XCTAssertFalse(request.accepts([:]))
        XCTAssertFalse(request.accepts(["different-id": "Compact"]))
        XCTAssertFalse(request.accepts(["density": "   "]))
        XCTAssertFalse(request.accepts(["density": String(repeating: "x", count: 8_001)]))
    }

    func testMalformedDuplicateOversizedAndSecretQuestionsAreRefusedWhole() throws {
        let original = try XCTUnwrap(Self.parameters["questions"] as? [[String: Any]])
        for edit: ([String: Any]) -> [String: Any] in [
            { var q = $0; q["id"] = ""; return q },
            { var q = $0; q["isSecret"] = true; return q },
            { var q = $0; q["question"] = String(repeating: "x", count: 2_001); return q },
            { var q = $0; q["options"] = "invalid"; return q }
        ] {
            var params = Self.parameters
            params["questions"] = [edit(original[0])]
            XCTAssertNil(ConversationQuestionRequest.codex(params))
        }
        var params = Self.parameters
        params["questions"] = original + original
        XCTAssertNil(ConversationQuestionRequest.codex(params))
        params["questions"] = Array(repeating: original[0], count: 1_000)
        XCTAssertNil(ConversationQuestionRequest.codex(params))
    }

    func testConcurrentRequestIDsAndServerResolutionCannotCrossAnswers() throws {
        let broker = CodexQuestionRequests()
        var callbacks: [([String: String]?) -> Void] = []
        var replies: [JSONRPCRequestID] = []
        var resolved: [UUID] = []
        broker.onPresent = { _, answer in callbacks.append(answer) }
        broker.respond = { id, result, error in
            XCTAssertNil(error)
            XCTAssertNotNil(result?["answers"])
            replies.append(id)
        }
        broker.onResolved = { resolved.append($0) }
        for id: JSONRPCRequestID in [.integer(1), .string("1")] {
            broker.receive(id: id, parameters: Self.parameters, threadID: "thread-1", turnID: "turn-1")
        }
        XCTAssertEqual(callbacks.count, 2)
        broker.resolve(id: .integer(1))
        callbacks[0](["density": "Compact"])
        callbacks[1](["density": "Expanded"])
        callbacks[1](["density": "Compact"])
        XCTAssertEqual(replies, [.string("1")])
        XCTAssertEqual(Set(resolved).count, 2)
        broker.invalidate()
        XCTAssertEqual(resolved.count, 2)
    }

    func testInvalidationDropsLateAnswerAndRejectsForeignTurn() {
        let broker = CodexQuestionRequests()
        var answer: (([String: String]?) -> Void)?
        var sends = 0
        broker.onPresent = { _, callback in answer = callback }
        broker.respond = { _, _, _ in sends += 1 }
        broker.receive(id: .integer(1), parameters: Self.parameters, threadID: "thread-1", turnID: "turn-1")
        broker.invalidate()
        answer?(["density": "Compact"])
        XCTAssertEqual(sends, 0)
        broker.receive(id: .integer(2), parameters: Self.parameters, threadID: "foreign", turnID: "turn-1")
        XCTAssertEqual(sends, 1)
    }

    func testCardRequiresExplicitSelectionAndRepliesExactlyOnce() throws {
        let request = try XCTUnwrap(ConversationQuestionRequest.codex(Self.parameters))
        var replies: [[String: String]?] = []
        let card = ConversationQuestionCard(request: request) { replies.append($0) }
        XCTAssertTrue(card.answers.isEmpty)
        card.submit([:])
        XCTAssertTrue(replies.isEmpty)
        card.submit(["density": "Compact"])
        card.submit(["density": "Expanded"])
        XCTAssertEqual(replies.count, 1)
        XCTAssertEqual(replies[0], ["density": "Compact"])
    }

    func testQuestionBlocksOnlyItsOwnRequestAndTeardownInvalidatesTheCard() throws {
        let (controller, _) = NativeChatShowcaseTests.fixture(.working)
        controller.isTurnInFlight = true
        let request = try XCTUnwrap(ConversationQuestionRequest.codex(Self.parameters))
        var replies = 0
        controller.presentQuestion(request) { _ in replies += 1 }
        let card = try XCTUnwrap(controller.questionCards[request.id])
        XCTAssertEqual(controller.runtimeSnapshot.blocker, .awaitingUser)
        controller.removeQuestion(id: UUID())
        XCTAssertEqual(controller.questionCards.count, 1)
        controller.terminate()
        card.submit(["density": "Compact"])
        XCTAssertEqual(replies, 0)
        XCTAssertTrue(controller.questionCards.isEmpty)
    }

    func testNonblockingQuestionDoesNotReplaceWorkingState() throws {
        var parameters = Self.parameters
        parameters["isBlocking"] = false
        let request = try XCTUnwrap(ConversationQuestionRequest.codex(parameters))
        let (controller, _) = NativeChatShowcaseTests.fixture(.working)
        controller.isTurnInFlight = true
        controller.presentQuestion(request) { _ in }
        XCTAssertEqual(controller.activity, .working)
        XCTAssertEqual(controller.runtimeSnapshot.blocker, .none)
        controller.terminate()
    }

    func testWaitingStopsTheStatusClockAndResumingKeepsTheTurnStart() throws {
        let (controller, _) = NativeChatShowcaseTests.fixture(.working)
        let start = controller.workingStartedAt
        XCTAssertNotNil(controller.workingStatusTimer)
        let request = try XCTUnwrap(ConversationQuestionRequest.codex(Self.parameters))
        controller.presentQuestion(request) { _ in }
        XCTAssertNil(controller.workingStatusTimer)
        XCTAssertTrue(controller.orbView.isHidden)
        XCTAssertEqual(controller.statusLabel.stringValue, L10n.string("Waiting for your answer"))
        controller.removeQuestion(id: request.id)
        XCTAssertNotNil(controller.workingStatusTimer)
        XCTAssertEqual(controller.workingStartedAt, start)
        controller.terminate()
        XCTAssertNil(controller.workingStatusTimer)
    }

    func testWorkDisclosureIsKeyboardAccessibleInsideTheTranscriptTable() throws {
        let (controller, host) = NativeChatShowcaseTests.fixture(.working)
        defer { controller.terminate() }
        func find(in view: NSView) -> ThemedDisclosureRow? {
            if let row = view as? ThemedDisclosureRow,
               row.accessibilityIdentifier() == "conversation.work-disclosure" { return row }
            return view.subviews.lazy.compactMap { find(in: $0) }.first
        }
        host.layoutSubtreeIfNeeded()
        let fold = try XCTUnwrap(find(in: controller.tableView))
        XCTAssertTrue(fold.acceptsFirstResponder)
        XCTAssertEqual(fold.accessibilityRole(), .disclosureTriangle)
        let count = controller.presentationItems.count
        XCTAssertTrue(fold.accessibilityPerformPress())
        XCTAssertGreaterThan(controller.presentationItems.count, count)
        XCTAssertTrue(fold.performPrimaryAction())
        XCTAssertEqual(controller.presentationItems.count, count)
    }
    func testRemoteQuestionProjectionPreservesIDsAndGatesReplyAuthority() throws {
        let request = try XCTUnwrap(ConversationQuestionRequest.codex(Self.parameters))
        let snapshot = RemoteConversationSnapshotDTO(rows: [], canSend: false, questions: [request.remoteRequest])
        let viewer = RemoteAuthorization(shareID: "view", capability: .view, scope: .allSessions)
        let owner = RemoteAuthorization(shareID: "owner", capability: .interact, scope: .allSessions)
        XCTAssertFalse(RemoteConversationWirePolicy.authorized(snapshot, for: viewer).questions[0].canAnswer)
        XCTAssertFalse(RemoteConversationWirePolicy.authorized(snapshot, for: owner, canWrite: false).questions[0].canAnswer)
        XCTAssertTrue(RemoteConversationWirePolicy.authorized(snapshot, for: owner).questions[0].canAnswer)
        let initial = RemoteConversationWirePolicy.initial(snapshot, revision: 1)
        XCTAssertEqual(initial.questions, snapshot.questions)
        let delta = try XCTUnwrap(RemoteConversationWirePolicy.deltaWithUnchangedRows(
            from: .init(rows: [], canSend: false), to: snapshot, baseRevision: 0, revision: 1))
        XCTAssertEqual(delta.questions, snapshot.questions)
    }

    func testRemoteAnswerSettlesOnlyItsExactCardOnce() throws {
        let controller = requireConversationViewController(
            agentSession: AgentSession(kind: .codex, title: "Remote questions", usesNativeUI: true),
            project: Project(name: "Questions", folderURL: URL(fileURLWithPath: NSTemporaryDirectory()))
        )
        defer { controller.terminate() }
        let first = try XCTUnwrap(ConversationQuestionRequest.codex(Self.parameters))
        let second = try XCTUnwrap(ConversationQuestionRequest.codex(Self.parameters))
        var firstReplies = 0
        var secondReplies = 0
        controller.presentQuestion(first) { _ in firstReplies += 1 }
        controller.presentQuestion(second) { _ in secondReplies += 1 }
        XCTAssertFalse(controller.answerRemoteQuestion(id: UUID().uuidString, answers: ["density": "Compact"]))
        XCTAssertFalse(controller.answerRemoteQuestion(id: first.id.uuidString, answers: ["wrong": "Compact"]))
        XCTAssertTrue(controller.answerRemoteQuestion(id: first.id.uuidString, answers: ["density": "Compact"]))
        XCTAssertFalse(controller.answerRemoteQuestion(id: first.id.uuidString, answers: ["density": "Expanded"]))
        XCTAssertEqual(firstReplies, 1)
        XCTAssertEqual(secondReplies, 0)
        XCTAssertEqual(controller.remoteSnapshot.questions.map(\.id), [second.id.uuidString])
    }

    func testQuestionPagingInvalidatesItsOwnRowHeight() throws {
        var parameters = Self.parameters
        var questions = try XCTUnwrap(parameters["questions"] as? [[String: Any]])
        questions.append(["id": "review", "header": "Review", "question": "What should we review?",
                          "isOther": false, "isSecret": false,
                          "options": (1...6).map { ["label": "Choice \($0)", "description": "A detailed explanation of this choice."] }])
        parameters["questions"] = questions
        let request = try XCTUnwrap(ConversationQuestionRequest.codex(parameters))
        let (controller, host) = NativeChatShowcaseTests.fixture(.working)
        defer { controller.terminate() }
        controller.presentQuestion(request) { _ in }
        host.layoutSubtreeIfNeeded()
        let card = try XCTUnwrap(controller.questionCards[request.id])
        let firstHeight = card.frame.height
        func find<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
            (view as? T).map { [$0] } ?? view.subviews.flatMap { find(type, in: $0) }
        }
        let choice = try XCTUnwrap(find(ConversationChoiceRow.self, in: card).first)
        XCTAssertTrue(choice.accessibilityPerformPress())
        let next = try XCTUnwrap(find(ThemedButton.self, in: card).first {
            $0.accessibilityIdentifier() == "conversation.question.submit"
        })
        let center = next.convert(NSPoint(x: next.bounds.midX, y: next.bounds.midY), to: host)
        let hit = host.hitTest(center)
        XCTAssertTrue(hit === next || hit?.isDescendant(of: next) == true,
                      "The visible Next button must receive pointer events; hit: \(String(describing: hit))")
        XCTAssertTrue(next.accessibilityPerformPress())
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(card.page, 1)
        XCTAssertGreaterThan(card.frame.height, firstHeight)
        XCTAssertEqual(controller.questionOrder, [request.id])
    }

}

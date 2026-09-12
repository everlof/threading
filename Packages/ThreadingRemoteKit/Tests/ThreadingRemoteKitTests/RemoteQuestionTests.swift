import XCTest
@testable import ThreadingRemoteKit

final class RemoteQuestionTests: XCTestCase {
    func request(id: String = UUID().uuidString) -> RemoteQuestionRequestDTO {
        .init(id: id, questions: [.init(id: "density", header: "Density", prompt: "Which density?",
              options: [.init(label: "Compact", detail: "Show less work")], allowsOther: false)], blocksTurn: true)
    }
    func testQuestionsRoundTripAndKeepPermissionIdentitySeparate() throws {
        let question = request()
        let snapshot = RemoteConversationSnapshotDTO(rows: [], canSend: false,
            permission: .init(id: "permission", toolName: "Edit", summary: "A.swift"), questions: [question])
        let decoded = try JSONDecoder().decode(RemoteConversationSnapshotDTO.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(decoded, snapshot)
        var state = RemoteConversationState()
        state.apply(decoded)
        state.apply(RemoteConversationDeltaDTO(baseRevision: 0, revision: 1, streamingText: "", canSend: false,
            permission: snapshot.permission, questions: []))
        XCTAssertTrue(state.questions.isEmpty)
        XCTAssertEqual(state.permission?.id, "permission")
    }
    func testLegacyHostsHaveNoPendingQuestionAndStaleDeltaCannotReviveOne() throws {
        let old = try JSONDecoder().decode(RemoteConversationSnapshotDTO.self,
            from: Data(#"{"rows":[],"canSend":true}"#.utf8))
        XCTAssertTrue(old.questions.isEmpty)
        var state = RemoteConversationState(revision: 3)
        XCTAssertEqual(state.apply(RemoteConversationDeltaDTO(baseRevision: 2, revision: 3,
            streamingText: "", canSend: false, questions: [request()])), .requiresSnapshot)
        XCTAssertTrue(state.questions.isEmpty)
    }
    func testAnswerValidatesExactIDsValuesAndSize() throws {
        let question = request()
        XCTAssertTrue(question.accepts(["density": "Compact"]))
        XCTAssertFalse(question.accepts(["other-id": "Compact"]))
        XCTAssertFalse(question.accepts(["density": "Expanded"]))
        XCTAssertFalse(question.accepts(["density": String(repeating: "x", count: 8001)]))
        let answer = RemoteClientMessage(type: "questionAnswer", id: question.id,
                                        decision: "answer", answers: ["density": "Compact"])
        XCTAssertEqual(try JSONDecoder().decode(RemoteClientMessage.self, from: JSONEncoder().encode(answer)), answer)
        XCTAssertFalse(question.allowingAnswers(false).canAnswer)
    }
    func testMalformedQuestionIsNeverPartiallyDisplayed() {
        let question = request()
        let invalid = RemoteQuestionRequestDTO(id: question.id, questions: question.questions + question.questions, blocksTurn: true)
        XCTAssertFalse(invalid.isValid)
        var state = RemoteConversationState()
        state.apply(RemoteConversationSnapshotDTO(rows: [], canSend: false, questions: [invalid]))
        XCTAssertTrue(state.questions.isEmpty)
        let oversized = RemoteQuestionRequestDTO(id: UUID().uuidString, questions: [
            .init(id: "q", header: "Q", prompt: String(repeating: "x", count: 2001), options: [], allowsOther: true)
        ], blocksTurn: true)
        XCTAssertFalse(oversized.isValid)
    }
}

import XCTest
@testable import Threading

@MainActor
final class ConversationHandoffRuntimeTests: XCTestCase {
    func testContinuingFreezesExplicitSourceAndProvisionalDestination() throws {
        var source = AgentSession(kind: .claude, title: "Initial", model: "source-model")
        source.customTitle = "Source at handoff"
        let targetID = SessionID()
        var handoff = try XCTUnwrap(ConversationHandoff.continuing(
            source: source,
            targetID: targetID,
            targetKind: .codex,
            targetModel: "chosen-target-model",
            targetTitle: "Destination"
        ))
        source.customTitle = "Later rename"
        source.model = "later-source-model"
        handoff.recordTargetModel("reported-target-model")
        handoff.recordTargetModel("later-target-model")

        let restored = try JSONDecoder().decode(
            ConversationHandoff.self, from: JSONEncoder().encode(handoff)
        )
        XCTAssertTrue(restored.isValid(destinationID: targetID, destinationKind: .codex))
        XCTAssertEqual(restored.source?.sessionID, source.id)
        XCTAssertEqual(restored.source?.title, "Source at handoff")
        XCTAssertEqual(restored.source?.model, "source-model")
        XCTAssertEqual(restored.target?.model, "reported-target-model")
    }

    func testRepeatedContinuationRefreshesOnlyTheDirectSource() throws {
        var origin = AgentSession(kind: .claude, title: "Origin", model: "origin-model")
        origin.customTitle = "Origin at handoff"
        let middleID = SessionID()
        let first = try XCTUnwrap(ConversationHandoff.continuing(
            source: origin, targetID: middleID, targetKind: .codex,
            targetModel: "initial-middle-model", targetTitle: "Middle"
        ))
        var middle = AgentSession(
            configuration: .codex(reasoningEffort: nil), title: "Middle",
            model: "current-middle-model", handoff: first, id: middleID
        )
        middle.customTitle = "Middle at second handoff"
        let targetID = SessionID()
        let second = try XCTUnwrap(ConversationHandoff.continuing(
            source: middle, targetID: targetID, targetKind: .claude,
            targetModel: nil, targetTitle: "Final"
        ))

        XCTAssertEqual(second.endpoints.count, 3)
        XCTAssertEqual(second.endpoints.first, first.endpoints.first)
        XCTAssertEqual(second.source?.sessionID, middleID)
        XCTAssertEqual(second.source?.model, "current-middle-model")
        XCTAssertEqual(second.source?.title, "Middle at second handoff")
        XCTAssertEqual(first.target?.model, "initial-middle-model")
        XCTAssertTrue(second.isValid(destinationID: targetID, destinationKind: .claude))
    }

    func testContinuingRefusesSameRuntimeOrSameSession() {
        let source = AgentSession(kind: .claude, title: "Source", model: "source-model")
        XCTAssertNil(ConversationHandoff.continuing(
            source: source, targetID: SessionID(), targetKind: .claude,
            targetModel: nil, targetTitle: "Same runtime"
        ))
        XCTAssertNil(ConversationHandoff.continuing(
            source: source, targetID: source.id, targetKind: .codex,
            targetModel: nil, targetTitle: "Same session"
        ))
    }
}

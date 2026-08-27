import XCTest
@testable import Threading

@MainActor
final class AgentRuntimeActivityEdgeTests: XCTestCase {
    func testDiscardingANativeConversationBroadcastsItsDormantActivity() {
        let session = AgentSession(kind: .claude, title: "Discard activity edge")
        var project = Project(
            name: "Activity",
            folderURL: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        )
        project.sessions = [session]

        XCTAssertNotNil(AgentRuntime.shared.makeConversation(for: session, in: project))
        defer { AgentRuntime.shared.discard(sessionID: session.id) }

        let edge = expectation(description: "discard posts the common activity edge")
        let observations = AppEventObservations()
        observations.observe(SessionActivityDidChange.self) { event in
            guard event.sessionID == session.id else { return }
            edge.fulfill()
        }

        AgentRuntime.shared.discard(sessionID: session.id)
        wait(for: [edge], timeout: 1)

        XCTAssertEqual(AgentRuntime.shared.activity(sessionID: session.id), .dormant)
        observations.removeAll()
    }

    func testCheckoutMoveTransfersNativeOutboxExactlyOnce() throws {
        let runtime = AgentRuntime(currentSessionProjection: CurrentSessionProjection { _ in nil })
        let sessionID = SessionID()
        var outbox = ConversationOutbox()
        _ = outbox.append(ConversationPrompt(text: "first queued prompt"))
        _ = outbox.append(ConversationPrompt(text: "second queued prompt"))

        runtime.preserveCheckoutMoveOutbox(outbox, for: sessionID)

        XCTAssertEqual(try XCTUnwrap(runtime.takeCheckoutMoveOutbox(sessionID: sessionID)), outbox)
        XCTAssertNil(runtime.takeCheckoutMoveOutbox(sessionID: sessionID))
    }
}

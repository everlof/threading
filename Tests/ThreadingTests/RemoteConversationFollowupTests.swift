import XCTest
import ThreadingRemoteKit
@testable import Threading

@MainActor
final class RemoteConversationFollowupTests: HostedStoreTestCase {
    private static let provider = """
    import json, sys, time
    def out(value):
        print(json.dumps(value), flush=True)
    for line in sys.stdin:
        message = json.loads(line)
        if message.get("type") == "control_request":
            out({"type":"control_response", "response":{"subtype":"success", "request_id":message.get("request_id"), "response":{}}})
        elif message.get("type") == "user":
            text = str(message.get("message", {}).get("content", ""))
            out({"type":"system", "subtype":"init", "session_id":"followup-fixture", "model":"claude-opus-5-5", "tools":[], "slash_commands":[]})
            time.sleep(0.5)
            reply = "Handled: " + text
            out({"type":"assistant", "message":{"id":"reply-" + text, "role":"assistant", "content":[{"type":"text", "text":reply}]}})
            out({"type":"result", "subtype":"success", "is_error":False, "result":reply, "duration_ms":500, "num_turns":1})
    """

    func testRemoteFollowupUsesHostQueueAndDoesNotClearTheMacDraft() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProjectStore.shared
        let project = try XCTUnwrap(store.addProject(folderURL: directory))
        let session = try XCTUnwrap(store.addSession(to: project.id, kind: .claude, usesNativeUI: true, title: "Followups"))
        XCTAssertTrue(store.update(sessionID: session.id) { $0.backgroundHost = false }.succeeded)
        let controller = try XCTUnwrap(ConversationViewController(
            agentSession: session, project: project,
            currentSessionProjection: CurrentSessionProjection { id in store.project(withID: project.id)?.sessions.first { $0.id == id } },
            launchPlanProvider: { _, _, _ in .init(executable: "/usr/bin/python3", arguments: ["-u", "-c", Self.provider], resumeState: .unavailable) },
            customizationLookup: { _ in .empty }
        ))
        _ = controller.view
        defer { controller.terminate(preservingViewport: false) }
        controller.launch()
        controller.sendInitialPrompt("First task")
        XCTAssertTrue(waitUntil { controller.isRunning && !controller.remoteSnapshot.canSend && controller.isTurnInFlight })
        controller.promptView.stringValue = "Draft on Mac"
        let owner = RemoteAuthorization(shareID: "owner", capability: .interact, scope: .allSessions, principal: .ownerDevice)
        XCTAssertTrue(controller.sendRemoteFollowup("Follow-up task", context: [], mode: .queue, authorization: owner))
        XCTAssertEqual(controller.remoteSnapshot.delivery?.messages.first(where: {
            $0.summary == "Follow-up task"
        })?.state, .queued)
        XCTAssertEqual(controller.promptView.stringValue, "Draft on Mac")
        XCTAssertTrue(waitUntil {
            controller.timeline.rows.contains { if case .assistant(let text) = $0 { return text.contains("Follow-up task") }; return false }
        })
        XCTAssertTrue(waitUntil { controller.remoteSnapshot.canSend })
        XCTAssertFalse(controller.sendRemoteFollowup("Too late to steer", context: [], mode: .steer, authorization: owner))
        XCTAssertFalse(controller.outbox.items.contains { $0.summary == "Too late to steer" })
        XCTAssertEqual(controller.promptView.stringValue, "Draft on Mac")
    }

    private func waitUntil(_ predicate: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(12)
        while !predicate(), Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        return predicate()
    }
}

import XCTest
import ThreadingController
@testable import Threading

/// A chat tied to a Linked Workroom does not stop on a question in its terminal; every other chat
/// is answered with silence.
@MainActor
final class WorkroomQuestionGuardTests: XCTestCase {

    func testAClosingQuestionIsRecognisedAndAQuestionMarkInAURLIsNot() {
        XCTAssertTrue(WorkroomQuestionGuard.endsOnQuestion("Done with the parser.\n\nShould I also update the PDF?"))
        XCTAssertTrue(WorkroomQuestionGuard.endsOnQuestion("Klart.\n\nSka jag fortsätta med 770? Säg till."))
        XCTAssertTrue(WorkroomQuestionGuard.endsOnQuestion("Which option do you prefer?**"))
        XCTAssertFalse(WorkroomQuestionGuard.endsOnQuestion("All tests pass. Committed as 983b9095f."))
        XCTAssertFalse(WorkroomQuestionGuard.endsOnQuestion("See https://example.test/q?id=4 for the log."))
        XCTAssertFalse(WorkroomQuestionGuard.endsOnQuestion("Summary.\n\n```\nwhy?\n```"))
        XCTAssertFalse(WorkroomQuestionGuard.endsOnQuestion("Why would it fail? Because the lock was stale.\n\n" + String(repeating: "Details. ", count: 120)))
    }

    func testTheReasonRoutesTheUsersQuestionsToTheOwnerWhenOneIsSet() {
        let withOwner = WorkroomQuestionGuard.reason(rooms: ["Sweep"], owner: ("David", "david"), event: .stop)
        XCTAssertTrue(withOwner.contains("workroom_ask") && withOwner.contains("person \"david\"") && withOwner.contains("“Sweep”"))
        let without = WorkroomQuestionGuard.reason(rooms: ["Sweep"], owner: nil, event: .preToolUse)
        XCTAssertTrue(without.contains("state the assumption"))
        XCTAssertTrue(without.hasPrefix("Threading: "))
    }

    func testOnlyATiedChatIsDeniedItsQuestionToolAndBlockedOncePerTurn() async throws {
        let settings = AppSettings.shared
        let prior = settings.workroomsEnabled
        settings.workroomsEnabled = true
        defer { settings.workroomsEnabled = prior }
        let tied = SessionID(UUID()), untied = SessionID(UUID())
        let ask: [String: Any] = ["tool_name": "AskUserQuestion"]
        let stop: [String: Any] = ["last_assistant_message": "Ska jag fortsätta?", "turn_id": "t1"]

        let untiedAsk = await WorkroomQuestionGuard.decide(untied, event: .preToolUse, payload: ask)
        XCTAssertNil(untiedAsk)
        let store = try await MacMailbox.shared.controllerStore()
        let address = try await MacMailbox.shared.register(tied, name: "Tied chat")
        _ = try await store.createWorkroom(id: WorkroomID(), scope: "project:test", title: "Sweep", purpose: "", createdBy: address)

        let denied = await WorkroomQuestionGuard.decide(tied, event: .preToolUse, payload: ask)
        let output = try XCTUnwrap(denied?["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(output["permissionDecision"] as? String, "deny")
        let otherTool = await WorkroomQuestionGuard.decide(tied, event: .preToolUse, payload: ["tool_name": "Bash"])
        XCTAssertNil(otherTool)

        let blocked = await WorkroomQuestionGuard.decide(tied, event: .stop, payload: stop)
        XCTAssertEqual(blocked?["decision"] as? String, "block")
        let again = await WorkroomQuestionGuard.decide(tied, event: .stop, payload: stop)
        XCTAssertNil(again, "a turn is blocked at most once")
        let continuing = await WorkroomQuestionGuard.decide(
            tied, event: .stop, payload: ["last_assistant_message": "Ny fråga?", "stop_hook_active": true])
        XCTAssertNil(continuing, "a stop the hook already continued is never blocked")
        let statement = await WorkroomQuestionGuard.decide(
            tied, event: .stop, payload: ["last_assistant_message": "Klart.", "turn_id": "t2"])
        XCTAssertNil(statement)
    }

    func testClaudeSettingsCarryTheAnsweringEntriesBesideTheLifecycleOnes() throws {
        let session = SessionID(UUID())
        let settings = try XCTUnwrap(MCPSessionRegistry.hookSettings(for: session, brokersPermissions: false, reportsLifecycle: true))
        let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        func commands(_ name: String) -> [(String?, String)] {
            (hooks[name] as? [[String: Any]] ?? []).flatMap { group in
                ((group["hooks"] as? [[String: Any]]) ?? []).map { (group["matcher"] as? String, $0["command"] as? String ?? "") }
            }
        }
        XCTAssertTrue(commands("PreToolUse").contains { $0.0 == "AskUserQuestion" && $0.1.contains("/question-guard/") })
        XCTAssertTrue(commands("Stop").contains { $0.0 == nil && $0.1.contains("/question-guard/") && $0.1.hasSuffix("|| true") })
    }
}

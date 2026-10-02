import XCTest

@testable import Threading

/// Claude writes its first `system/init` only once it starts the opening prompt (CLI 2.1.287:
/// an `initialize` control request alone returns a `control_response` and no `system/init`).
/// A background launch sends that prompt immediately, so the init lands inside the opening
/// turn. Reading it as Ready ended the turn for the runtime: an unattended automation run was
/// settled as "The automation ended without reporting a result." within a second of starting,
/// while its agent went on working.
@MainActor
final class ConversationOpeningTurnTests: XCTestCase {

    private func makeController() -> ConversationViewController {
        let controller = requireConversationViewController(
            agentSession: AgentSession(kind: .claude, title: "Automation", usesNativeUI: true),
            project: Project(name: "Automation", folderURL: URL(fileURLWithPath: NSTemporaryDirectory())),
            customizationLookup: { _ in .empty }
        )
        _ = controller.view
        return controller
    }

    private func startOpeningTurn(on controller: ConversationViewController) {
        controller.apply(controller.timeline.appendUserMessage(
            ConversationUserMessage(text: "Run the saved automation")
        ))
        controller.apply(.status(.working(word: "Working")))
    }

    private func deliver(_ event: StreamEvent, to controller: ConversationViewController) {
        for change in controller.timeline.apply(event) { controller.apply(change) }
    }

    func testClaudeInitDuringTheOpeningTurnDoesNotEndIt() {
        let controller = makeController()
        startOpeningTurn(on: controller)
        XCTAssertTrue(controller.runtimeSnapshot.hasOpenTurn)

        deliver(.initialised(sessionID: nil, model: "claude-opus-5-5"), to: controller)

        XCTAssertTrue(controller.isTurnInFlight)
        XCTAssertTrue(controller.runtimeSnapshot.hasOpenTurn)
        XCTAssertTrue(controller.runtimeSnapshot.hasPendingOutcome)
        XCTAssertEqual(controller.presentedStatus, .working(word: "Working"))
    }

    func testTheOpeningTurnStillEndsAtItsOwnFinish() {
        let controller = makeController()
        startOpeningTurn(on: controller)
        deliver(.initialised(sessionID: nil, model: "claude-opus-5-5"), to: controller)

        deliver(.turnFinished(text: "Done", outcome: .completed, metrics: .empty), to: controller)

        XCTAssertFalse(controller.isTurnInFlight)
        XCTAssertFalse(controller.runtimeSnapshot.hasOpenTurn)
    }

    func testInitWithNoTurnInFlightStillReportsReadyWithItsModel() {
        let controller = makeController()

        deliver(.initialised(sessionID: nil, model: "claude-opus-5-5"), to: controller)

        XCTAssertFalse(controller.isTurnInFlight)
        XCTAssertEqual(controller.presentedStatus, .ready(model: "claude-opus-5-5", lastTurn: nil))
    }
}

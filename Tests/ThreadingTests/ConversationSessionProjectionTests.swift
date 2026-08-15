import XCTest
@testable import Threading

@MainActor
final class ConversationSessionProjectionTests: XCTestCase {
    func testConversationReadsMutableSessionStateFromInjectedProjection() throws {
        let initial = AgentSession(kind: .codex, title: "Projected")
        let project = Project(
            name: "Projected",
            folderURL: URL(fileURLWithPath: "/tmp/projected-conversation")
        )
        var projected: AgentSession? = initial
        let projection = CurrentSessionProjection { sessionID in
            projected.flatMap { $0.id == sessionID ? $0 : nil }
        }

        let controller = try XCTUnwrap(ConversationViewController(
            agentSession: initial,
            project: project,
            currentSessionProjection: projection
        ))

        XCTAssertEqual(controller.sessionID, initial.id)
        XCTAssertEqual(controller.currentSession?.title, "Projected")

        projected?.title = "Current title"
        projected?.model = "gpt-5.2-codex"

        XCTAssertEqual(controller.currentSession?.title, "Current title")
        XCTAssertEqual(controller.currentSession?.model, "gpt-5.2-codex")

        projected = nil
        XCTAssertNil(controller.currentSession)
    }

    func testRequiredProjectionRefusesRemovedSession() {
        let sessionID = SessionID()
        let projection = CurrentSessionProjection { _ in nil }

        XCTAssertThrowsError(try projection.requireSession(for: sessionID)) { error in
            XCTAssertEqual(
                (error as? CurrentSessionUnavailableError)?.sessionID,
                sessionID
            )
        }
    }

    func testSchedulingQueriesTheInjectedWorkingDirectory() {
        let sessionID = SessionID()
        var requested: SessionID?
        let projection = CurrentSessionProjection(
            resolve: { _ in nil },
            workingDirectory: { candidate in
                requested = candidate
                return "/tmp/injected-session-worktree"
            }
        )

        XCTAssertEqual(
            projection.workingDirectory(for: sessionID),
            "/tmp/injected-session-worktree"
        )
        XCTAssertEqual(requested, sessionID)
    }

    func testScheduledTimingUsesTheProjectedWatchedSessionTitle() {
        let message = ScheduledMessage(
            whenSessionFinishes: SessionID(),
            target: .session(SessionID()),
            text: "Continue"
        )

        XCTAssertEqual(
            ScheduledTiming.sentence(
                for: message,
                watchedSessionTitle: "Current projected title"
            ),
            "When “Current projected title” finishes"
        )
    }
}

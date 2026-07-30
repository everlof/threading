import AppKit
import XCTest
@testable import Threading

/// The wording behind "Close" and "Archive" on a running session.
///
/// The two actions read as near-synonyms in a menu, and for a while they behaved almost
/// unrelatedly: Close stopped the agent and kept the row, Archive hid the row and left the
/// agent running with nothing listing it. The confirmation alerts are where the difference
/// is actually said, so these tests hold each one to naming what a user cannot guess from
/// the verb alone: that the agent stops, where the session ends up, and that its
/// conversation survives. Built separately from being asked — the same seam the sidebar's
/// menu builders offer — so no modal is involved.
@MainActor
final class SessionLifecycleConfirmationTests: XCTestCase {

    private func session(_ title: String = "Refactor the parser") -> AgentSession {
        AgentSession(kind: .claude, title: title)
    }

    func testTheCloseAlertSaysTheSessionStaysAndCanBeResumed() {
        let request = SessionCoordinator.closeConfirmation(for: session())

        XCTAssertTrue(request.title.contains("Close"))
        XCTAssertTrue(request.title.contains("Refactor the parser"))
        XCTAssertTrue(
            request.message.contains("stays in the sidebar"),
            "closing keeps the row; the alert is where that is said"
        )
        XCTAssertTrue(request.message.contains("resumed"))
    }

    func testTheArchiveAlertSaysTheAgentStopsAndWhereTheSessionGoes() {
        let request = SessionCoordinator.archiveConfirmation(for: session())

        XCTAssertTrue(request.title.contains("Archive"))
        XCTAssertTrue(request.title.contains("Refactor the parser"))
        XCTAssertTrue(
            request.message.contains("will stop"),
            "archiving a running session stops its agent, and the alert must say so"
        )
        XCTAssertTrue(
            request.message.contains("Archived"),
            "the alert names where an archived session can be found again"
        )
        XCTAssertTrue(request.message.contains("restored"))
    }

    /// Cancel stays the way out on both: interrupting a running agent is never the only
    /// button on offer. Structural now that the request carries exactly one confirm title and
    /// one cancel title, so what is worth asserting is that the built alert still says so.
    func testBothAlertsOfferCancelLast() {
        let alerts = [
            ConfirmationAlert.makeAlert(SessionCoordinator.closeConfirmation(for: session())),
            ConfirmationAlert.makeAlert(SessionCoordinator.archiveConfirmation(for: session()))
        ]

        for alert in alerts {
            XCTAssertEqual(alert.buttons.count, 2)
            XCTAssertEqual(alert.buttons.last?.title, "Cancel")
        }
    }

    /// The two were one setting, and switching off the archive prompt used to switch off the
    /// close prompt with it. Each carries its own registered prompt now, and each one's
    /// settings copy has to name where the session ends up — the same thing the alert says,
    /// because that is what someone deciding whether to stop being asked needs to know.
    func testBothLifecyclePromptsCanBeSwitchedOffAndSayWhereTheSessionGoes() {
        let close = try? XCTUnwrap(ConfirmationPrompt.closeRunningSession.suppression)
        let archive = try? XCTUnwrap(ConfirmationPrompt.archiveRunningSession.suppression)

        XCTAssertTrue(close?.settingsSubtitle.contains("sidebar") == true)
        XCTAssertTrue(archive?.settingsSubtitle.contains("Archived") == true)
        XCTAssertNotEqual(
            close?.settingsTitle,
            archive?.settingsTitle,
            "one row each, or switching off the one you meant switches off the other"
        )
    }

    func testCrossProviderContinuationSaysItCreatesANewSessionAndKeepsTheOriginal() {
        let request = SessionCoordinator.continuationConfirmation(
            for: session(),
            destination: .codex
        )

        XCTAssertTrue(request.title.contains("Codex"))
        XCTAssertTrue(request.message.contains("new session"))
        XCTAssertTrue(request.message.contains("read-only snapshot"))
        XCTAssertTrue(request.message.contains("original session stays"))
        XCTAssertEqual(request.prompt, .continueRunningSessionWithAnotherProvider)
    }
}

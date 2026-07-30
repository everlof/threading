import AppKit
import XCTest
@testable import Threading

/// The gate every confirmation goes through.
///
/// Each test here is a bug the call sites used to be one edit away from: a "Don't ask again"
/// box honoured after Cancel, a box offered beside an irreversible action, Return landing on a
/// destructive button, and a fourth option falling through `default:` because the named modal
/// responses stop at three. Everything is built rather than run, so no modal is involved.
@MainActor
final class ConfirmationAlertTests: XCTestCase {

    private func request(
        _ prompt: ConfirmationPrompt = .archiveRunningSession
    ) -> ConfirmationRequest {
        ConfirmationRequest(
            prompt: prompt,
            title: "Archive “Refactor the parser”?",
            message: "The agent will stop.",
            confirmTitle: "Archive"
        )
    }

    // MARK: - Remembering

    /// Ticking the box and then pressing Cancel must not silence the prompt: the *next*
    /// invocation would go straight through on an action the user had just declined.
    func testTheBoxIsHonouredOnlyWhenTheActionWasAccepted() {
        XCTAssertTrue(ConfirmationAlert.remembers(accepted: true, suppressionChecked: true))
        XCTAssertFalse(ConfirmationAlert.remembers(accepted: false, suppressionChecked: true))
        XCTAssertFalse(ConfirmationAlert.remembers(accepted: true, suppressionChecked: false))
        XCTAssertFalse(ConfirmationAlert.remembers(accepted: false, suppressionChecked: false))
    }

    /// A suppressed prompt is not put up at all and reads as confirmed — the guard runs before
    /// the alert is built, which is what makes this assertable without a modal.
    func testASuppressedPromptIsNotAskedAndReadsAsConfirmed() throws {
        let suite = "ConfirmationAlert.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        settings.setAsks(false, before: .archiveRunningSession)

        XCTAssertTrue(ConfirmationAlert.ask(request(), settings: settings))
    }

    // MARK: - Building

    func testOnlyASuppressiblePromptGetsASuppressionBox() {
        for prompt in ConfirmationPrompt.allCases {
            let alert = ConfirmationAlert.makeAlert(request(prompt))
            XCTAssertEqual(
                alert.showsSuppressionButton,
                prompt.suppression != nil,
                "\(prompt.rawValue)"
            )
        }
    }

    func testTheSuppressionBoxSaysWhatItDoes() {
        let alert = ConfirmationAlert.makeAlert(request())
        XCTAssertEqual(alert.suppressionButton?.title, "Don't ask again")
    }

    /// The rule `ExtensionCommandInvoker` applied by hand to exactly one alert, now stated once
    /// for all eight: the chord that dismisses a dialog is not the one that deletes.
    func testAnIrreversibleConfirmationPutsReturnOnCancel() {
        let alert = ConfirmationAlert.makeAlert(request(.removeProject))

        XCTAssertEqual(alert.buttons.first?.keyEquivalent, "")
        XCTAssertEqual(alert.buttons.last?.keyEquivalent, "\r")
        XCTAssertTrue(alert.buttons.first?.hasDestructiveAction == true)
    }

    /// Deliberately the other way for a grant: the agent is blocked while the sheet is up and
    /// approving is the common answer, so Return stays on the affirmative button.
    func testASecurityGrantLeavesReturnOnTheAction() {
        let alert = ConfirmationAlert.makeAlert(request(.approveToolPermission))

        XCTAssertNotEqual(alert.buttons.first?.keyEquivalent, "")
        XCTAssertFalse(alert.buttons.first?.hasDestructiveAction == true)
    }

    func testAChoiceOffersEveryOptionPlusTheWayOut() {
        let alert = ConfirmationAlert.makeAlert(choice())

        XCTAssertEqual(alert.buttons.count, 4)
        XCTAssertEqual(alert.buttons.last?.title, "Cancel")
        XCTAssertFalse(
            alert.showsSuppressionButton,
            "a remembered answer has to be an answer; three of them are not one"
        )
    }

    /// A choice that does not apply is disabled rather than dropped, so the indices the caller
    /// reads back keep meaning the same thing.
    func testADisabledOptionKeepsItsPlace() {
        let alert = ConfirmationAlert.makeAlert(choice(viewOnlyEnabled: false))

        XCTAssertFalse(alert.buttons[0].isEnabled)
        XCTAssertTrue(alert.buttons[1].isEnabled)
        XCTAssertEqual(alert.buttons[2].title, "Copy Collaborator + Approval Link")
    }

    // MARK: - Deleting

    /// Delete Session shipped with no confirmation at all, next to a Close that had one — which
    /// read as Delete being the lesser of the two. It asks now, whatever the session is doing,
    /// and it never offers the box.
    func testDeletingASessionAlwaysAsksAndSaysWhatSurvives() {
        let session = AgentSession(kind: .claude, title: "Refactor the parser")
        let request = ProjectSidebarViewController.deleteConfirmation(
            for: session,
            isRunning: false
        )

        XCTAssertTrue(request.title.contains("Refactor the parser"))
        XCTAssertTrue(
            request.message.contains("imported again"),
            "\"Delete\" reads as the conversation going too; it does not"
        )

        let alert = ConfirmationAlert.makeAlert(request)
        XCTAssertFalse(alert.showsSuppressionButton, "a delete is not switchable off")
        XCTAssertEqual(alert.buttons.first?.keyEquivalent, "", "Return must not delete")
    }

    /// A running agent is a second consequence, so the sheet names it rather than leaving the
    /// user to discover it after the row is gone.
    func testDeletingARunningSessionSaysTheAgentStopsToo() {
        let session = AgentSession(kind: .claude, title: "Refactor the parser")
        let running = ProjectSidebarViewController.deleteConfirmation(
            for: session,
            isRunning: true
        )

        XCTAssertTrue(running.message.contains("will stop"))
        XCTAssertTrue(running.message.contains("imported again"))
    }

    // MARK: - Quitting

    /// Quitting is nearer to closing a session than to deleting one — the conversations resume
    /// — so it may be switched off, and the sheet has to say that rather than leaving someone
    /// to guess whether Quit loses their work.
    func testTheQuitAlertSaysTheConversationsSurviveAndCanBeSwitchedOff() {
        let request = AppDelegate.quitConfirmation(runningSessionCount: 3)

        XCTAssertTrue(request.title.contains("3"), "the count is the reason it is asking")
        XCTAssertTrue(request.message.contains("resumed"))
        XCTAssertNotNil(ConfirmationPrompt.quitWithRunningAgents.suppression)
        XCTAssertTrue(ConfirmationAlert.makeAlert(request).showsSuppressionButton)
    }

    /// "1 agents" is the kind of thing nobody notices until it ships, and the singular is the
    /// common case: one chat working while you reach for Cmd+Q.
    func testTheQuitAlertReadsProperlyForASingleAgent() {
        let title = AppDelegate.quitConfirmation(runningSessionCount: 1).title

        XCTAssertTrue(title.contains("one agent"), title)
        XCTAssertFalse(title.contains("agents"), title)
    }

    /// The share sheet ships four buttons and the named modal responses stop at three, so its
    /// fourth used to arrive through a `default:` clause that also catches every unrelated
    /// dismissal. Arithmetic reads all four back and still says `nil` for the way out.
    func testAFourthOptionIsStillReadBack() {
        let first = NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        let response = { NSApplication.ModalResponse(rawValue: first + $0) }

        XCTAssertEqual(ConfirmationAlert.chosenIndex(response(0), optionCount: 4), 0)
        XCTAssertEqual(ConfirmationAlert.chosenIndex(response(2), optionCount: 4), 2)
        XCTAssertEqual(ConfirmationAlert.chosenIndex(response(3), optionCount: 4), 3)
        XCTAssertNil(
            ConfirmationAlert.chosenIndex(response(4), optionCount: 4),
            "the button after the last option is Cancel"
        )
        XCTAssertNil(ConfirmationAlert.chosenIndex(.abort, optionCount: 4))
        XCTAssertNil(ConfirmationAlert.chosenIndex(response(1), optionCount: 1))
    }

    private func choice(viewOnlyEnabled: Bool = true) -> ChoiceRequest {
        ChoiceRequest(
            prompt: .shareChatLink,
            title: "Share “Refactor the parser”",
            message: "This single-use invitation opens only this chat.",
            options: [
                ConfirmationOption(title: "Copy View-Only Link", isEnabled: viewOnlyEnabled),
                ConfirmationOption(title: "Copy Collaborator Link"),
                ConfirmationOption(title: "Copy Collaborator + Approval Link")
            ]
        )
    }
}

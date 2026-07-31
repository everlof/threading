import XCTest
@testable import Threading

/// The warning that stands in front of a macOS privacy prompt.
///
/// An agent runs `screencapture`, and macOS puts up a dialog saying *Threading* would like to
/// record the screen — no session named, no command shown, no reason given. Threading cannot
/// intercept that dialog; it can only see the call coming and say what it is about first. So
/// there are two things worth pinning: that the forecast fires on the commands that need a
/// grant and stays quiet on the ones that merely mention one, and that the briefing it raises
/// answers the tool call rather than adding a second question behind it.
@MainActor
final class SystemGrantForecastTests: XCTestCase {

    private let session = SessionID()
    private var originalStatus: ((SystemPrivacyPermission) -> SystemPrivacyStatus?)!

    override func setUp() {
        super.setUp()
        originalStatus = PermissionBroker.systemGrantStatus
        PermissionBroker.discardSystemGrantBriefings()
    }

    override func tearDown() {
        PermissionBroker.present = nil
        PermissionBroker.explainSystemGrant = nil
        PermissionBroker.systemGrantStatus = originalStatus
        PermissionBroker.discardSystemGrantBriefings()
        PermissionBroker.discard(sessionID: session)
        super.tearDown()
    }

    // MARK: - The Table

    func testACaptureCommandForecastsScreenRecording() {
        XCTAssertEqual(
            SystemGrantForecast.grant(forCommand: "screencapture -x shot.png"),
            .screenRecording
        )
    }

    /// The three ways the binary is not the first word of the line. Each was seen in a real
    /// rollout before it was a rule.
    func testTheBinaryIsFoundPastAChainAWrapperAndAPath() {
        for command in [
            "cd /tmp && screencapture -x shot.png",
            "sudo screencapture -x shot.png",
            "/usr/sbin/screencapture -x shot.png",
            "mkdir -p out; screencapture -R 0,0,100,100 out/a.png"
        ] {
            XCTAssertEqual(
                SystemGrantForecast.grant(forCommand: command),
                .screenRecording,
                "\"\(command)\" would have raised an unexplained system prompt"
            )
        }
    }

    /// Naming a binary is not running it. Matching anywhere in the line would have put a card
    /// in front of a grep, which is the interruption this exists to remove.
    func testMentioningACommandWithoutRunningItForecastsNothing() {
        for command in [
            "grep screencapture notes.txt",
            "ls -la ~/Pictures",
            "echo cliclick",
            "rg --files-with-matches osascript"
        ] {
            XCTAssertNil(
                SystemGrantForecast.grant(forCommand: command),
                "\"\(command)\" was briefed for a prompt it cannot raise"
            )
        }
    }

    func testAPointerDriverForecastsAccessibility() {
        XCTAssertEqual(SystemGrantForecast.grant(forCommand: "cliclick c:100,200"), .accessibility)
    }

    /// `osascript` is the one that has to be read further in: it is how an agent inspects a
    /// window as readily as how it clicks a button, and only the second needs the grant.
    func testAppleScriptIsJudgedOnWhetherItDrivesInput() {
        XCTAssertEqual(
            SystemGrantForecast.grant(
                forCommand: #"osascript -e 'tell application "System Events" to keystroke "a"'"#
            ),
            .accessibility
        )
        XCTAssertEqual(
            SystemGrantForecast.grant(
                forCommand: #"osascript -e 'tell application "System Events" to click button 1 of window 1 of process "Finder"'"#
            ),
            .accessibility
        )
        XCTAssertNil(
            SystemGrantForecast.grant(
                forCommand: #"osascript -e 'tell application "System Events" to get name of every process'"#
            ),
            "listing processes asks macOS for Automation, which is a different gate with no "
                + "readable status — forecasting it would be a guess"
        )
    }

    /// Only a shell call reaches a binary of its own. Every other tool runs inside the CLI,
    /// whose file access is the folder grant this deliberately refuses to guess at.
    func testOnlyAShellCallIsForecast() {
        XCTAssertNil(SystemGrantForecast.grant(for: request(tool: "Read", input: [
            "file_path": "/tmp/screencapture.png"
        ])))
        XCTAssertEqual(
            SystemGrantForecast.grant(for: request(tool: "Bash", input: [
                "command": "screencapture -x /tmp/a.png"
            ])),
            .screenRecording
        )
    }

    /// The folder grant has no API that reads it without also requesting it, so a forecast for
    /// it could only ever be a guess — and a wrong guess is a card in front of a folder the user
    /// approved two years ago. `SystemPrivacyStatus.askedWhenNeeded` exists for the same reason.
    func testOnlyGrantsThatCanBeReadWithoutPromptingAreForecast() {
        let reader = SystemPrivacyStatusReader(
            accessibilityTrusted: { false },
            screenRecordingAllowed: { false },
            notificationStatus: { $0(.notAllowed) }
        )
        XCTAssertNil(reader.immediateStatus(of: .filesAndFolders))
        XCTAssertNil(reader.immediateStatus(of: .notifications))
        XCTAssertEqual(reader.immediateStatus(of: .accessibility), .notAllowed)
        XCTAssertEqual(reader.immediateStatus(of: .screenRecording), .notAllowed)
    }

    // MARK: - The Briefing

    func testTheUserIsToldWhichGrantAndWhichCommandBeforeMacOSAsks() {
        withoutTheGrant()
        var briefed: (SystemPrivacyPermission, PermissionRequest)?
        PermissionBroker.explainSystemGrant = { permission, request, proceed in
            briefed = (permission, request)
            proceed(true)
        }

        _ = decision(tool: "Bash", input: ["command": "screencapture -x /tmp/a.png"])

        XCTAssertEqual(briefed?.0, .screenRecording)
        XCTAssertEqual(briefed?.1.summary, "screencapture -x /tmp/a.png")
    }

    /// Declining has to stop the command, not merely the explanation. The alternative — letting
    /// it run and leaving the user to press Deny on the system dialog instead — hands the agent
    /// an unexplained failure and the user the dialog they were trying to avoid.
    func testDecliningTheBriefingDeniesTheCall() {
        withoutTheGrant()
        PermissionBroker.explainSystemGrant = { _, _, proceed in proceed(false) }

        let answer = decision(tool: "Bash", input: ["command": "screencapture -x /tmp/a.png"])

        XCTAssertFalse(isAllowed(answer))
        XCTAssertTrue(reason(of: answer).contains("Screen Recording"), reason(of: answer))
    }

    /// The briefing shows the command, the session and the grant — strictly more than the
    /// ordinary approval card. A second sheet immediately behind it would be the app asking
    /// twice about one decision, which is how people learn to click through both.
    func testApprovingTheBriefingIsTheApprovalAndDoesNotAskAgain() {
        withoutTheGrant()
        PermissionBroker.explainSystemGrant = { _, _, proceed in proceed(true) }

        var cardsShown = 0
        PermissionBroker.present = { _, completion in
            cardsShown += 1
            completion(.deny(reason: "test"))
        }

        let answer = decision(tool: "Bash", input: ["command": "screencapture -x /tmp/a.png"])

        XCTAssertTrue(isAllowed(answer))
        XCTAssertEqual(cardsShown, 0, "the user was asked twice about one command")
    }

    /// Approving the briefing answers *this* call. A standing allow is a choice made in words,
    /// and nothing on that sheet offers one.
    func testApprovingTheBriefingIsNotAStandingApproval() {
        withoutTheGrant()
        PermissionBroker.explainSystemGrant = { _, _, proceed in proceed(true) }
        _ = decision(tool: "Bash", input: ["command": "screencapture -x /tmp/a.png"])

        var asked = false
        PermissionBroker.present = { _, completion in
            asked = true
            completion(.deny(reason: "test"))
        }
        _ = decision(tool: "Bash", input: ["command": "rm -rf /tmp/build"])

        XCTAssertTrue(asked, "a later command ran on the back of the briefing's approval")
    }

    /// A grant already given raises no system prompt, so there is nothing to warn about. This
    /// is what keeps the sheet from appearing on a machine where Screen Recording has been on
    /// for a year.
    func testAGrantAlreadyHeldIsNeverBriefed() {
        PermissionBroker.systemGrantStatus = { _ in .allowed }
        var briefed = false
        PermissionBroker.explainSystemGrant = { _, _, proceed in
            briefed = true
            proceed(true)
        }
        var asked = false
        PermissionBroker.present = { _, completion in
            asked = true
            completion(.deny(reason: "test"))
        }

        _ = decision(tool: "Bash", input: ["command": "screencapture -x /tmp/a.png"])

        XCTAssertFalse(briefed, "a grant the user already gave was explained anyway")
        XCTAssertTrue(asked, "the ordinary approval card was skipped")
    }

    /// macOS asks Threading once, not once per session — and a user who let the command run and
    /// then pressed Deny on the *system* dialog will never see that dialog again. Briefing them
    /// a second time would be warning about a prompt that can no longer appear.
    func testAGrantIsExplainedOnceAcrossTheApp() {
        withoutTheGrant()
        var briefings = 0
        PermissionBroker.explainSystemGrant = { _, _, proceed in
            briefings += 1
            proceed(true)
        }

        _ = decision(tool: "Bash", input: ["command": "screencapture -x /tmp/a.png"])
        _ = decision(tool: "Bash", input: ["command": "screencapture -x /tmp/b.png"])
        _ = decision(
            tool: "Bash",
            input: ["command": "screencapture -x /tmp/c.png"],
            session: SessionID()
        )

        XCTAssertEqual(briefings, 1)
    }

    /// Declining is not an answer to keep. The command never ran, so macOS was never asked, so
    /// the next attempt is a fresh request and gets the same explanation.
    func testADeclinedBriefingIsAskedAgain() {
        withoutTheGrant()
        var briefings = 0
        PermissionBroker.explainSystemGrant = { _, _, proceed in
            briefings += 1
            proceed(false)
        }

        _ = decision(tool: "Bash", input: ["command": "screencapture -x /tmp/a.png"])
        _ = decision(tool: "Bash", input: ["command": "screencapture -x /tmp/b.png"])

        XCTAssertEqual(briefings, 2)
    }

    /// Losing the explanation must not also lose the call. Without a window to explain in, the
    /// system prompt arrives unannounced — which is what happens today, and is a great deal
    /// better than the tool call disappearing.
    func testWithNothingToExplainWithTheCallStillGetsDecided() {
        withoutTheGrant()
        PermissionBroker.explainSystemGrant = nil
        var asked = false
        PermissionBroker.present = { _, completion in
            asked = true
            completion(.allow(reason: "test"))
        }

        let answer = decision(tool: "Bash", input: ["command": "screencapture -x /tmp/a.png"])

        XCTAssertTrue(asked)
        XCTAssertTrue(isAllowed(answer))
    }

    /// Every mode is briefed except the one that refuses everything. Bypass included: no mode
    /// Threading offers can promise macOS stays quiet. `dontAsk` is excluded because approving
    /// a briefing *is* the tool's approval, so briefing there would turn the mode that promises
    /// to refuse rather than interrupt into an allow.
    func testOnlyTheModeThatRefusesEverythingSkipsTheBriefing() {
        for mode in AgentPermissionMode.allCases {
            XCTAssertEqual(
                PermissionBroker.briefingApplies(in: mode),
                mode != .dontAsk,
                "\(mode)"
            )
        }
        XCTAssertTrue(
            PermissionBroker.briefingApplies(in: nil),
            "a session with no stated mode is the common case and must still be warned"
        )
    }

    // MARK: - The Sheet

    /// Everything the system dialog leaves out. The user's questions, in the order they ask
    /// them: what is about to happen, why now, which of six chats, and why does the dialog say
    /// Threading when Claude is the one running.
    func testTheSheetAnswersWhatTheSystemDialogDoesNot() {
        let sheet = MainWindowController.systemGrantConfirmation(
            permission: .screenRecording,
            agent: "Claude Code",
            command: "screencapture -x /tmp/a.png",
            sessionName: "Fix UI alignment",
            projectName: "AnotherTerminal"
        )

        XCTAssertTrue(sheet.title.contains("Claude Code"), sheet.title)
        XCTAssertTrue(sheet.title.contains("Screen Recording"), sheet.title)
        XCTAssertTrue(sheet.message.contains("screencapture -x /tmp/a.png"), sheet.message)
        XCTAssertTrue(sheet.message.contains("Fix UI alignment · AnotherTerminal"), sheet.message)
        XCTAssertTrue(
            sheet.message.contains("say Threading rather than Claude Code"),
            "the sheet does not explain why the coming dialog names the wrong program"
        )
    }

    /// Return stays on Continue and there is no "Don't ask again": switching this off would
    /// restore the unexplained system dialog, which is the bug rather than the quieter setting.
    func testTheSheetOffersContinueAndDenyAndCannotBeSwitchedOff() {
        let sheet = MainWindowController.systemGrantConfirmation(
            permission: .accessibility,
            agent: "Codex",
            command: "cliclick c:10,10",
            sessionName: nil,
            projectName: nil
        )

        XCTAssertEqual(sheet.confirmTitle, "Continue")
        XCTAssertEqual(sheet.cancelTitle, "Deny")
        XCTAssertNil(ConfirmationPrompt.approveSystemPermissionPrompt.suppression)
        XCTAssertFalse(ConfirmationPrompt.approveSystemPermissionPrompt.defaultsToCancel)
        XCTAssertFalse(ConfirmationAlert.makeAlert(sheet).showsSuppressionButton)
    }

    /// A chat Threading cannot name is no reason to leave the sentence dangling — the grant and
    /// the command are what carry it.
    func testTheSheetStillReadsWhenTheSessionCannotBeNamed() {
        let sheet = MainWindowController.systemGrantConfirmation(
            permission: .screenRecording,
            agent: nil,
            command: "screencapture -x /tmp/a.png",
            sessionName: nil,
            projectName: nil
        )

        XCTAssertTrue(sheet.title.contains("An agent"), sheet.title)
        XCTAssertFalse(sheet.message.contains("\n\n\n"), "an empty line was left where the "
            + "session name would have gone")
    }

    // MARK: - Helpers

    /// States that the machine does not hold the grant, so the tests never depend on what this
    /// developer happens to have approved in System Settings.
    private func withoutTheGrant() {
        PermissionBroker.systemGrantStatus = { _ in .notAllowed }
    }

    private func request(tool: String, input: [String: JSONValue]) -> PermissionRequest {
        PermissionRequest(sessionID: session, toolName: tool, input: input)
    }

    private func decision(
        tool: String,
        input: [String: JSONValue],
        session: SessionID? = nil
    ) -> PermissionDecision {
        var result: PermissionDecision?
        PermissionBroker.decide(
            PermissionRequest(
                sessionID: session ?? self.session,
                toolName: tool,
                input: input
            )
        ) { result = $0 }

        guard let result else {
            XCTFail("the broker never answered for \(tool)")
            return .deny(reason: "no answer")
        }
        return result
    }

    private func isAllowed(_ decision: PermissionDecision) -> Bool {
        if case .allow = decision { return true }
        return false
    }

    private func reason(of decision: PermissionDecision) -> String {
        switch decision {
        case .allow(let text), .deny(let text): return text
        }
    }
}

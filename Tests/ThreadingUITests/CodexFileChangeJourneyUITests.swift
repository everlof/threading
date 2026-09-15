import XCTest

@MainActor
final class CodexFileChangeJourneyUITests: XCTestCase {
    private static let journey = "File change and relaunch recovery"
    private static let prompt = "In this synthetic repository, replace the exact contents of status.txt from before to after."

    private var application: XCUIApplication?
    private var sandbox: UIScenarioSandbox?

    override func setUpWithError() throws {
        continueAfterFailure = false
        sandbox = try UIScenarioSandbox.make()
    }

    override func tearDownWithError() throws {
        application?.terminate()
        application = nil
        try sandbox?.remove()
        sandbox = nil
    }

    /// Crosses the actual app-server pipes, provider parser, native conversation renderer,
    /// checkout watcher, Git Review pane, durable project store, and transcript replay.
    func testRecordedCodexTurnMutatesFileAndRecoversAfterRelaunch() throws {
        let sandbox = try XCTUnwrap(sandbox)
        let fixture = try sandbox.prepareCodexFileChangeFixture()
        let statusFile = fixture.project.appendingPathComponent("status.txt")

        let firstLaunch = XCUIApplication()
        sandbox.configure(firstLaunch)
        // The floating usage card needs a gutter beside the readable conversation column.
        let targetSize = UIWindowContract.configure(firstLaunch, preferred: CGSize(width: 1800, height: 900))
        fixture.configure(firstLaunch, scenarioRoot: sandbox.root)
        application = firstLaunch
        sandbox.launch(firstLaunch)

        let firstWindow = firstLaunch.windows.firstMatch
        XCTAssertTrue(firstWindow.waitForExistence(timeout: 20))
        UIWindowContract.assertApplied(to: firstWindow, expected: targetSize)

        let prompt = firstLaunch.textViews["composer.prompt.text"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 20), "native conversation composer did not appear")
        prompt.click()
        prompt.typeText(Self.prompt)
        let submit = firstLaunch.buttons["composer.prompt.submit"]
        XCTAssertTrue(submit.waitForExistence(timeout: 5))
        submit.click()

        XCTAssertTrue(
            firstLaunch.staticTexts["Updated status.txt."].waitForExistence(timeout: 15),
            "the streamed Codex answer never reached the conversation"
        )
        let sessionUsageButton = firstLaunch.descendants(matching: .any)["session.status.usage"]
        XCTAssertTrue(
            sessionUsageButton.waitForExistence(timeout: 15),
            "the Session Status Card never received the completed turn's usage receipt"
        )
        assertTurnEvidenceRecovered(in: firstLaunch, context: "the live turn")
        assertFile(statusFile, eventuallyEquals: "after\n")
        try recordScenarioScreenshot(
            checkpoint: "file-change-01-completed-turn",
            order: 1,
            title: "Completed agent turn",
            description: "The streamed Codex reply is complete and the changed status.txt file is visible in the conversation.",
            journey: Self.journey,
            in: sandbox,
            of: firstWindow
        )

        let displayPanel = firstLaunch.buttons["Display panel"]
        XCTAssertTrue(
            displayPanel.waitForExistence(timeout: 5),
            "the display-panel toggle did not appear"
        )
        displayPanel.click()
        let infoSection = firstLaunch.radioButtons["session-overview.section.info"]
        XCTAssertTrue(
            infoSection.waitForExistence(timeout: 10),
            "the empty panel did not open a default Overview"
        )
        XCTAssertTrue(
            firstLaunch.buttons["Finder"].waitForExistence(timeout: 10),
            "Overview did not open with its right-hand Info section focused"
        )
        let infoLoaded = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                firstLaunch.staticTexts["Processes"].exists
                    || firstLaunch.staticTexts["This session isn’t running."].exists
            },
            object: nil
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [infoLoaded], timeout: 10),
            .completed,
            "Overview Info had not completed its first process reading"
        )
        XCTAssertTrue(
            firstLaunch.staticTexts["Usage"].waitForExistence(timeout: 10),
            "Overview Info did not show the session usage section"
        )
        XCTAssertTrue(
            firstLaunch.staticTexts["Total"].waitForExistence(timeout: 5),
            "Overview Info did not show the indexed session total"
        )
        try recordScenarioScreenshot(
            checkpoint: "file-change-02-overview-info",
            order: 2,
            title: "Usage and runtime in Overview Info",
            description: "An otherwise empty panel opens one Overview tab with its right-hand Info section focused.",
            journey: Self.journey,
            in: sandbox,
            of: firstWindow
        )

        let activitySection = firstLaunch.radioButtons["session-overview.section.activity"]
        XCTAssertTrue(
            activitySection.waitForExistence(timeout: 5),
            "Overview did not expose its Activity section"
        )
        activitySection.click()
        let activitySummary = firstLaunch.descendants(matching: .any)["activity.summary"]
        XCTAssertTrue(
            activitySummary.waitForExistence(timeout: 10),
            "Overview did not switch from Info to Activity"
        )
        let activityLoaded = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", " actions"),
            object: activitySummary
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [activityLoaded], timeout: 10),
            .completed,
            "Overview Activity was still loading when evidence was captured"
        )
        try recordScenarioScreenshot(
            checkpoint: "file-change-03-overview-activity",
            order: 3,
            title: "Work in Overview Activity",
            description: "The same Overview tab switches to Activity and accounts for work in the synthetic checkout.",
            journey: Self.journey,
            in: sandbox,
            of: firstWindow
        )

        firstLaunch.typeKey("r", modifierFlags: [.command, .shift])
        let reviewedFile = firstLaunch.staticTexts["git-review.file.name"]
        XCTAssertTrue(
            reviewedFile.waitForExistence(timeout: 10),
            "Git Review did not show the changed file"
        )
        XCTAssertEqual(
            reviewedFile.value as? String,
            "status.txt",
            "Git Review showed the wrong changed file"
        )
        XCTAssertFalse(
            firstLaunch.descendants(matching: .any)["git.status.overlay"].exists,
            "the branch card covered conversation ink after Git Review narrowed the pane"
        )
        try recordScenarioScreenshot(
            checkpoint: "file-change-02-git-review",
            order: 4,
            title: "Changed file in Git Review",
            description: "Git Review identifies status.txt in the synthetic checkout after the agent mutation.",
            journey: Self.journey,
            in: sandbox,
            of: firstWindow
        )

        firstLaunch.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(
            firstLaunch.wait(for: .notRunning, timeout: 10),
            "Threading did not complete a clean quit before relaunch"
        )

        let secondLaunch = XCUIApplication()
        let secondTargetSize = sandbox.configure(secondLaunch)
        fixture.configure(secondLaunch, scenarioRoot: sandbox.root)
        application = secondLaunch
        sandbox.launch(secondLaunch)

        let secondWindow = secondLaunch.windows.firstMatch
        XCTAssertTrue(secondWindow.waitForExistence(timeout: 20))
        UIWindowContract.assertApplied(to: secondWindow, expected: secondTargetSize)
        XCTAssertTrue(
            secondLaunch.staticTexts[Self.prompt].waitForExistence(timeout: 20),
            "the recorded user turn was not recovered from the provider transcript"
        )
        XCTAssertTrue(
            secondLaunch.staticTexts["Updated status.txt."].waitForExistence(timeout: 10),
            "the recorded assistant answer was not recovered after relaunch"
        )
        assertTurnEvidenceRecovered(in: secondLaunch, context: "the replayed turn")
        assertFile(statusFile, eventuallyEquals: "after\n")
        try recordScenarioScreenshot(
            checkpoint: "file-change-03-relaunch-recovery",
            order: 5,
            title: "Conversation recovered after relaunch",
            description: "A clean quit and relaunch restores both the user's prompt and the completed agent response.",
            journey: Self.journey,
            in: sandbox,
            of: secondWindow
        )
    }

    private func assertTurnEvidenceRecovered(
        in application: XCUIApplication,
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        // AppKit exposes the fold's visible NSTextField as the stable child in a table row;
        // XCUI does not preserve the custom NSView disclosure role through that container.
        // Assert the user-visible semantic title rather than an implementation-specific role.
        let worked = application.staticTexts.matching(
            NSPredicate(format: "value BEGINSWITH %@", "Worked")
        ).firstMatch
        XCTAssertTrue(
            worked.waitForExistence(timeout: 10),
            "\(context) lost its work disclosure",
            file: file,
            line: line
        )
        XCTAssertTrue(
            application.staticTexts["1 changed file"].waitForExistence(timeout: 10),
            "\(context) lost its changed-files summary",
            file: file,
            line: line
        )
        XCTAssertTrue(
            application.descendants(matching: .any)["status.txt"].waitForExistence(timeout: 10),
            "\(context) lost the changed path",
            file: file,
            line: line
        )
    }

    private func assertFile(
        _ url: URL,
        eventuallyEquals expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let changed = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                (try? String(contentsOf: url, encoding: .utf8)) == expected
            },
            object: nil
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [changed], timeout: 10),
            .completed,
            "\(url.lastPathComponent) did not become \(expected.debugDescription)",
            file: file,
            line: line
        )
    }
}

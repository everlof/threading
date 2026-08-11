import XCTest

@MainActor
final class CodexFileChangeJourneyUITests: XCTestCase {
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
        let targetSize = sandbox.configure(firstLaunch)
        fixture.configure(firstLaunch, scenarioRoot: sandbox.root)
        application = firstLaunch
        firstLaunch.launch()

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
        assertFile(statusFile, eventuallyEquals: "after\n")
        recordScenarioScreenshot(named: "file-change-01-completed-turn", of: firstWindow)

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
        recordScenarioScreenshot(named: "file-change-02-git-review", of: firstWindow)

        firstLaunch.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(
            firstLaunch.wait(for: .notRunning, timeout: 10),
            "Threading did not complete a clean quit before relaunch"
        )

        let secondLaunch = XCUIApplication()
        let secondTargetSize = sandbox.configure(secondLaunch)
        fixture.configure(secondLaunch, scenarioRoot: sandbox.root)
        application = secondLaunch
        secondLaunch.launch()

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
        assertFile(statusFile, eventuallyEquals: "after\n")
        recordScenarioScreenshot(named: "file-change-03-relaunch-recovery", of: secondWindow)
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

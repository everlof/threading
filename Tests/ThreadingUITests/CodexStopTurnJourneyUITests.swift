import XCTest

@MainActor
final class CodexStopTurnJourneyUITests: XCTestCase {
    private static let interruptedPrompt = "Keep working until I stop this synthetic turn."
    private static let recoveryPrompt = "Reply with exactly: Ready for another turn."
    private static let recoveryAnswer = "Ready for another turn."

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

    /// Proves Stop crosses the real app-server boundary, settles as an interruption rather than
    /// a failure, leaves the checkout untouched, and returns the same conversation to a usable
    /// Ready state for the next turn.
    func testStoppingCodexTurnLeavesConversationUsable() throws {
        let sandbox = try XCTUnwrap(sandbox)
        let fixture = try sandbox.prepareCodexStopTurnFixture()
        let statusFile = fixture.project.appendingPathComponent("status.txt")

        let app = XCUIApplication()
        let targetSize = sandbox.configure(app)
        fixture.configure(app, scenarioRoot: sandbox.root)
        application = app
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 20))
        UIWindowContract.assertApplied(to: window, expected: targetSize)

        let prompt = app.textViews["composer.prompt.text"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 20), "native conversation composer did not appear")
        submit(Self.interruptedPrompt, through: prompt, in: app)

        let action = app.buttons["composer.prompt.submit"]
        assertEventually(action, labelBeginsWith: "Stop", timeout: 10)
        recordScenarioScreenshot(named: "stop-turn-01-working", of: window)
        action.click()

        assertEventually(action, labelBeginsWith: "Send", timeout: 10)
        XCTAssertEqual(try String(contentsOf: statusFile, encoding: .utf8), "before\n")
        recordScenarioScreenshot(named: "stop-turn-02-interrupted-and-ready", of: window)

        submit(Self.recoveryPrompt, through: prompt, in: app)
        XCTAssertTrue(
            app.staticTexts[Self.recoveryAnswer].waitForExistence(timeout: 15),
            "the conversation did not accept a turn after Stop"
        )
        XCTAssertEqual(try String(contentsOf: statusFile, encoding: .utf8), "before\n")
        recordScenarioScreenshot(named: "stop-turn-03-next-turn-completed", of: window)
    }

    private func submit(
        _ text: String,
        through prompt: XCUIElement,
        in application: XCUIApplication
    ) {
        prompt.click()
        prompt.typeText(text)
        let submit = application.buttons["composer.prompt.submit"]
        XCTAssertTrue(submit.waitForExistence(timeout: 5))
        submit.click()
    }

    private func assertEventually(
        _ element: XCUIElement,
        labelBeginsWith expectedPrefix: String,
        timeout: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label BEGINSWITH %@", expectedPrefix),
            object: element
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: timeout),
            .completed,
            "expected accessibility label beginning with \(expectedPrefix.debugDescription), "
                + "found \(element.label.debugDescription)",
            file: file,
            line: line
        )
    }
}

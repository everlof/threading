import XCTest

@MainActor
final class CodexStopTurnJourneyUITests: XCTestCase {
    private static let journey = "Stop and continue"
    private static let interruptedPrompt = "Keep working until I stop this synthetic turn."
    private static let partialReply = "Working until stopped…"
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
        sandbox.launch(app)

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 20))
        UIWindowContract.assertApplied(to: window, expected: targetSize)

        let prompt = app.textViews["composer.prompt.text"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 20), "native conversation composer did not appear")
        submit(Self.interruptedPrompt, through: prompt, in: app)

        let action = app.buttons["composer.prompt.submit"]
        assertEventually(action, labelBeginsWith: "Stop", timeout: 10)
        try recordScenarioScreenshot(
            checkpoint: "stop-turn-01-working",
            order: 1,
            title: "Turn is working",
            description: "The active Codex turn exposes Stop as the composer's primary action.",
            journey: Self.journey,
            in: sandbox,
            of: window
        )
        action.click()

        assertEventually(action, labelBeginsWith: "Send", timeout: 10)
        XCTAssertTrue(
            app.staticTexts[Self.partialReply].waitForExistence(timeout: 5),
            "the partial provider reply disappeared when the turn was interrupted"
        )
        XCTAssertTrue(
            app.staticTexts["Interrupted"].waitForExistence(timeout: 5),
            "the stopped turn has no durable terminal marker"
        )
        XCTAssertEqual(try String(contentsOf: statusFile, encoding: .utf8), "before\n")
        try recordScenarioScreenshot(
            checkpoint: "stop-turn-02-interrupted-and-ready",
            order: 2,
            title: "Interrupted and ready",
            description: "After Stop crosses the provider boundary, the same conversation returns to a send-ready state.",
            journey: Self.journey,
            in: sandbox,
            of: window
        )

        submit(Self.recoveryPrompt, through: prompt, in: app)
        XCTAssertTrue(
            app.staticTexts[Self.recoveryAnswer].waitForExistence(timeout: 15),
            "the conversation did not accept a turn after Stop"
        )
        XCTAssertEqual(try String(contentsOf: statusFile, encoding: .utf8), "before\n")
        try recordScenarioScreenshot(
            checkpoint: "stop-turn-03-next-turn-completed",
            order: 3,
            title: "Next turn completed",
            description: "The interrupted conversation accepts another prompt and renders its exact successful response.",
            journey: Self.journey,
            in: sandbox,
            of: window
        )
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

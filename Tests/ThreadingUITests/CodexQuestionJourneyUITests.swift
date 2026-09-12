import XCTest

@MainActor
final class CodexQuestionJourneyUITests: XCTestCase {
    private var application: XCUIApplication?
    private var sandbox: UIScenarioSandbox?
    override func setUpWithError() throws {
        continueAfterFailure = false
        sandbox = try UIScenarioSandbox.make()
    }
    override func tearDownWithError() throws {
        application?.terminate(); application = nil
        try sandbox?.remove(); sandbox = nil
    }
    func testQuestionWaitsForExplicitAnswersAndResumesTheSameChat() throws {
        let sandbox = try XCTUnwrap(sandbox)
        let fixture = try sandbox.prepareCodexQuestionFixture()
        let receipt = fixture.project.appendingPathComponent("answers.json")
        let app = XCUIApplication()
        let targetSize = sandbox.configure(app)
        fixture.configure(app, scenarioRoot: sandbox.root)
        application = app; sandbox.launch(app)
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 20))
        UIWindowContract.assertApplied(to: window, expected: targetSize)
        let prompt = app.textViews["composer.prompt.text"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 20))
        prompt.click(); prompt.typeText("Ask me how to review this chat.")
        app.buttons["composer.prompt.submit"].click()
        let first = app.descendants(matching: .any)["conversation.question.option.density.0"].firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 15))
        let next = app.buttons["conversation.question.submit"]
        XCTAssertFalse(next.isEnabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: receipt.path))
        try recordScenarioScreenshot(checkpoint: "question-01-waiting", order: 1, title: "Waiting for your choice",
            description: "The actual provider request has no selected answer and does not submit on arrival.",
            journey: "Answer an inline question", in: sandbox, of: window)
        first.click()
        XCTAssertTrue(next.isEnabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: receipt.path))
        next.click()
        let second = app.descendants(matching: .any)["conversation.question.option.review.0"].firstMatch
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        XCTAssertFalse(next.isEnabled)
        second.click()
        try recordScenarioScreenshot(checkpoint: "question-02-review", order: 2, title: "Review the final choice",
            description: "Each page keeps its original question ID. The final answer still requires an explicit send.",
            journey: "Answer an inline question", in: sandbox, of: window)
        next.click()
        XCTAssertTrue(app.staticTexts["Answer received: Compact and Interactions."].waitForExistence(timeout: 15))
        XCTAssertEqual(try String(contentsOf: receipt, encoding: .utf8), "{\"density\":\"Compact\",\"review\":\"Interactions\"}\n")
        XCTAssertFalse(next.exists)
        try recordScenarioScreenshot(checkpoint: "question-03-complete", order: 3, title: "Answer delivered, chat continues",
            description: "The fixture received the exact two answers through app-server and the pending card is gone.",
            journey: "Answer an inline question", in: sandbox, of: window)
    }
}

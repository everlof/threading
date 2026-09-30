import XCTest

@MainActor
final class AutomationJourneyUITests: XCTestCase {
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
    func testHumanCreatesPausedAutomationAndItSurvivesRelaunch() throws {
        let sandbox = try XCTUnwrap(sandbox)
        let fixture = try sandbox.prepareCodexQuestionFixture()
        let app = XCUIApplication()
        _ = sandbox.configure(app)
        fixture.configure(app, scenarioRoot: sandbox.root)
        application = app; sandbox.launch(app)
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 20))
        let automations = app.buttons["Automations"]
        XCTAssertTrue(automations.waitForExistence(timeout: 10))
        automations.click()
        let create = app.buttons["automation.new"]
        XCTAssertTrue(create.waitForExistence(timeout: 10)); create.click()
        let name = app.textFields["automation.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10)); name.click(); name.typeText("Morning project report")
        let instructions = app.textViews["automation.instructions"]
        instructions.click(); instructions.typeText("Summarize changes from yesterday. Report any failures.")
        try recordScenarioScreenshot(checkpoint: "automation-editor", order: 1, title: "Create a recurring task",
            description: "The shipping automation editor exposes the saved task, permissions, recurrence and archive behavior.",
            journey: "Recurring automations", in: sandbox, of: window)
        app.popUpButtons["When offline"].click()
        app.typeKey(.escape, modifierFlags: [])
        try recordScenarioScreenshot(checkpoint: "automation-schedule", order: 2, title: "Schedule and successful-run behavior",
            description: "The editor keeps recurrence, missed-run policy and success-only archiving in the saved configuration.",
            journey: "Recurring automations", in: sandbox, of: window)
        app.buttons["automation.save"].click()
        XCTAssertTrue(app.staticTexts["Morning project report"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Review & Activate"].exists)
        try recordScenarioScreenshot(checkpoint: "automation-paused", order: 3, title: "Saved and waiting for activation",
            description: "The new schedule is durable and paused; saving it starts no agent.",
            journey: "Recurring automations", in: sandbox, of: window)
        app.terminate(); sandbox.launch(app)
        XCTAssertTrue(app.buttons["Automations"].waitForExistence(timeout: 20)); app.buttons["Automations"].click()
        XCTAssertTrue(app.staticTexts["Morning project report"].waitForExistence(timeout: 10))
        try recordScenarioScreenshot(checkpoint: "automation-restored", order: 4, title: "Automation survives relaunch",
            description: "The same saved task remains paused after restarting the actual application.",
            journey: "Recurring automations", in: sandbox, of: app.windows.firstMatch)
    }
}

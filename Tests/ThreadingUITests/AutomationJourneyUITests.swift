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
        XCTAssertFalse(app.outlines.staticTexts["Automations"].exists)
        app.menuBars.menuBarItems["View"].click()
        app.menuItems["Project Automations"].click()
        let create = app.buttons["automation.new"]
        XCTAssertTrue(create.waitForExistence(timeout: 10)); create.click()
        let name = app.textFields["automation.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10)); name.click(); name.typeText("Morning project report")
        XCTAssertFalse(app.popUpButtons["Project"].isEnabled)
        XCTAssertTrue(app.popUpButtons["automation.account"].exists)
        XCTAssertTrue(app.popUpButtons["automation.model"].exists)
        XCTAssertTrue(app.popUpButtons["automation.effort"].exists)
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
        let files = try FileManager.default.contentsOfDirectory(at: fixture.project.appendingPathComponent(".threading/automations"), includingPropertiesForKeys: nil)
        let saved = try XCTUnwrap(files.first { $0.lastPathComponent.first != "." })
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.appendingPathComponent("automation.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.appendingPathComponent("instructions.md").path))
        XCTAssertTrue(app.buttons["Review & Activate"].exists)
        try recordScenarioScreenshot(checkpoint: "automation-paused", order: 3, title: "Saved and waiting for activation",
            description: "The new schedule is durable and paused; saving it starts no agent.",
            journey: "Recurring automations", in: sandbox, of: window)
        app.terminate(); sandbox.launch(app)
        let restoredRow = app.outlines.staticTexts["Automations"].firstMatch
        XCTAssertTrue(restoredRow.waitForExistence(timeout: 20)); restoredRow.click()
        XCTAssertTrue(app.staticTexts["Morning project report"].waitForExistence(timeout: 10))
        try recordScenarioScreenshot(checkpoint: "automation-restored", order: 4, title: "Automation survives relaunch",
            description: "The same saved task remains paused after restarting the actual application.",
            journey: "Recurring automations", in: sandbox, of: app.windows.firstMatch)
        app.buttons["Review & Activate"].click()
        XCTAssertTrue(app.buttons["Activate"].waitForExistence(timeout: 10))
        app.buttons["Activate"].click()
        XCTAssertTrue(app.staticTexts["Active"].waitForExistence(timeout: 10))
        try Data("Changed outside Threading; review this revision again.".utf8).write(to: saved.appendingPathComponent("instructions.md"))
        XCTAssertTrue(app.buttons["Review & Activate"].waitForExistence(timeout: 35))
        try recordScenarioScreenshot(checkpoint: "automation-restored-file-change", order: 5, title: "File change pauses the activated task",
            description: "The same project automation returns to review after an outside edit, preserving its identity across save, relaunch and activation.",
            journey: "Recurring automations", in: sandbox, of: app.windows.firstMatch)
    }

    func testProjectReviewFileChangePauseAndDirtyCheckoutWorkspaceLaunch() throws {
        let sandbox = try XCTUnwrap(sandbox)
        let fixture = try sandbox.prepareCodexQuestionFixture()
        let folder = fixture.project.appendingPathComponent(".threading/automations/workspace-task")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "formatVersion": 1, "id": "workspace-task", "name": "Workspace report", "instructions": "instructions.md",
            "resources": [], "agent": "codex", "executionMode": "taskLocalEdits", "checkoutPolicy": "automationWorkspace",
            "maximumRuntimeMinutes": 60, "conditions": [], "permissions": ["mode": "allowList", "rules": []],
            "options": ["archiveOnSuccess": true, "missedRunPolicy": "latest", "schedule": [
                "kind": "daily", "timeZone": "Europe/Stockholm", "hour": 9, "minute": 30, "days": [],
                "intervalMinutes": 60, "anchor": "1970-01-01T00:00:00Z"]],
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: folder.appendingPathComponent("automation.json"))
        let instructions = folder.appendingPathComponent("instructions.md")
        try Data("Verify the automation workspace.".utf8).write(to: instructions)
        try Data("Uncommitted product work must survive.".utf8).write(to: fixture.project.appendingPathComponent("dirty.txt"))
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try FileManager.default.removeItem(at: fixture.freshTape)
        try FileManager.default.copyItem(at: repository.appendingPathComponent("Fixtures/AgentScenarios/codex-automation-workspace-fresh.json"), to: fixture.freshTape)
        let app = XCUIApplication()
        _ = sandbox.configure(app)
        fixture.configure(app, scenarioRoot: sandbox.root)
        app.launchEnvironment["THREADING_UI_SCENARIO_AUTOMATION_WORKSPACE"] = "1"
        application = app
        sandbox.launch(app)
        let row = app.outlines.staticTexts["Automations"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20)); row.click()
        XCTAssertTrue(app.staticTexts["Workspace report"].waitForExistence(timeout: 20))
        app.buttons["Review & Activate"].click()
        XCTAssertTrue(app.buttons["Activate"].waitForExistence(timeout: 10))
        try recordScenarioScreenshot(checkpoint: "automation-project-review", order: 1, title: "Review project files",
            description: "The shipping host sheet shows the exact resource fingerprint, workspace and resolved permissions.",
            journey: "Project automations", in: sandbox, of: app.windows.firstMatch)
        app.buttons["Activate"].click()
        XCTAssertTrue(app.staticTexts["Active"].waitForExistence(timeout: 10))
        app.buttons["Details"].firstMatch.click()
        app.buttons["Run now"].click()
        let proof = fixture.project.appendingPathComponent(".threading/local/automations/workspace-task/runs/started.txt")
        let started = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in FileManager.default.fileExists(atPath: proof.path) }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [started], timeout: 25), .completed)
        XCTAssertEqual(try String(contentsOf: fixture.project.appendingPathComponent("dirty.txt")), "Uncommitted product work must survive.")
        try Data("Changed outside Threading; review again.".utf8).write(to: instructions)
        XCTAssertTrue(app.buttons["Review & Activate"].waitForExistence(timeout: 35))
        try recordScenarioScreenshot(checkpoint: "automation-project-paused", order: 2, title: "Outside edit pauses future runs",
            description: "An edited project instruction returns the schedule to host review while its ordinary chat remains under its project.",
            journey: "Project automations", in: sandbox, of: app.windows.firstMatch)
    }
}

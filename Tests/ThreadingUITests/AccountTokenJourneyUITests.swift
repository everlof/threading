import XCTest

@MainActor
final class AccountTokenJourneyUITests: XCTestCase {
    func testOpenTypeCancelAndReopenTokenPrompt() throws {
        continueAfterFailure = false
        let sandbox = try UIScenarioSandbox.make()
        let home = sandbox.root.appendingPathComponent(".claude-token-fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data("{\"oauthAccount\":{\"emailAddress\":\"token.fixture@example.test\"}}".utf8)
            .write(to: home.appendingPathComponent(".claude.json"))

        let app = XCUIApplication()
        sandbox.configure(app)
        defer { app.terminate(); try? sandbox.remove() }
        sandbox.launch(app)
        app.typeKey(",", modifierFlags: .command)
        let accounts = app.radioButtons["Agents & Accounts"].firstMatch
        XCTAssertTrue(accounts.waitForExistence(timeout: 10))
        accounts.click()
        let use = app.buttons["Use Token…"].firstMatch
        XCTAssertTrue(use.waitForExistence(timeout: 10))

        for iteration in 1...2 {
            use.click()
            let field = app.secureTextFields["account-token.value"]
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            field.click()
            field.typeText("sk-ant-oat01-FAKE-FIXTURE-VALUE")
            XCTAssertFalse((field.value as? String ?? "").isEmpty)
            try recordScenarioScreenshot(
                checkpoint: "token-prompt-\(iteration)", order: iteration,
                title: "One-year token prompt accepts secure input",
                description: "The production Accounts action opens a masked field and remains dismissible after typing.",
                journey: "One-year sign-in", in: sandbox,
                of: app.windows.firstMatch
            )
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(use.waitForExistence(timeout: 5))
            XCTAssertFalse(field.exists)
        }
    }
}

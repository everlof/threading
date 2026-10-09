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
        let parentClickPoint = CGPoint(x: accounts.frame.midX, y: accounts.frame.midY)

        for iteration in 1...2 {
            use.click()
            let field = app.secureTextFields["account-token.value"]
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            field.click()
            // Anchor the screen click to the foreground app. A coordinate derived from `app`
            // would let XCTest activate Threading first, hiding the click-through regression.
            let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
            finder.activate()
            XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
            let finderOrigin = finder.frame.origin
            finder.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
                dx: parentClickPoint.x - finderOrigin.x,
                dy: parentClickPoint.y - finderOrigin.y
            )).click()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5),
                          "clicking the blocked parent must activate Threading")
            // No second click on the field: the sheet must recover keyboard ownership itself.
            app.typeText("sk-ant-oat01-FAKE-FIXTURE-VALUE")
            XCTAssertFalse((field.value as? String ?? "").isEmpty)
            try recordScenarioScreenshot(
                checkpoint: "token-prompt-\(iteration)", order: iteration,
                title: "One-year token prompt accepts secure input",
                description: "After switching to Finder, clicking the blocked parent brings Threading and its prompt forward. Typing reaches the secure field without clicking the dialog.",
                journey: "One-year sign-in", in: sandbox,
                of: app.windows.firstMatch
            )
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(use.waitForExistence(timeout: 5))
            XCTAssertFalse(field.exists)
        }
    }
}

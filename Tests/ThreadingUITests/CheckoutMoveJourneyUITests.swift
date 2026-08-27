import XCTest

@MainActor
final class CheckoutMoveJourneyUITests: XCTestCase {
    private static let journey = "Move chat between checkouts"
    private static let activePrompt = "Keep working while I move this chat."
    private static let resumedPrompt = "Reply with exactly: Moved and ready."
    private static let targetBranch = "fix/checkout-move"

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

    /// Crosses the real session menu, durable active-turn fence, Git checkpoint barrier,
    /// provider relaunch, canonical project lookup and Git Review checkout scope.
    func testActiveCodexTurnMovesAndResumesInSiblingCheckout() throws {
        let sandbox = try XCTUnwrap(sandbox)
        let fixture = try sandbox.prepareCodexCheckoutMoveFixture()

        let app = XCUIApplication()
        let targetSize = sandbox.configure(app)
        fixture.configure(app, scenarioRoot: sandbox.root)
        application = app
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 20))
        UIWindowContract.assertApplied(to: window, expected: targetSize)

        let prompt = app.textViews["composer.prompt.text"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 20))
        submit(Self.activePrompt, through: prompt, in: app)

        let submitButton = app.buttons["composer.prompt.submit"]
        assertEventually(submitButton, labelBeginsWith: "Stop", timeout: 10)
        openCheckoutMenu(in: app)
        let target = app.menuItems[Self.targetBranch]
        XCTAssertTrue(target.waitForExistence(timeout: 5), "the sibling checkout was not offered")
        target.click()

        openMoveSubmenu(in: app)
        XCTAssertTrue(
            app.menuItems["Pending: \(Self.targetBranch)"].waitForExistence(timeout: 5),
            "the active turn did not retain a visible pending checkout move"
        )
        try recordScenarioScreenshot(
            checkpoint: "checkout-move-01-pending",
            order: 1,
            title: "Checkout move queued",
            description: "The running turn stays in place while its durable target is visible in the shared session menu.",
            journey: Self.journey,
            in: sandbox,
            of: window
        )
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])

        submitButton.click()
        assertEventually(submitButton, labelBeginsWith: "Send", timeout: 15)
        XCTAssertTrue(
            app.staticTexts[Self.targetBranch].waitForExistence(timeout: 15),
            "the session did not publish the target checkout's refreshed branch"
        )

        submit(Self.resumedPrompt, through: prompt, in: app)
        XCTAssertTrue(
            app.staticTexts["Moved and ready."].waitForExistence(timeout: 15),
            "the original Codex conversation did not resume after the checkout move"
        )
        try recordScenarioScreenshot(
            checkpoint: "checkout-move-02-resumed",
            order: 2,
            title: "Conversation resumed in target checkout",
            description: "The same provider conversation accepts its next turn after relaunch in fix/checkout-move.",
            journey: Self.journey,
            in: sandbox,
            of: window
        )

        app.typeKey("r", modifierFlags: [.command, .shift])
        let reviewedFile = app.staticTexts["git-review.file.name"]
        XCTAssertTrue(reviewedFile.waitForExistence(timeout: 10))
        XCTAssertEqual(reviewedFile.value as? String, "target-only.txt")
        try recordScenarioScreenshot(
            checkpoint: "checkout-move-03-git-review",
            order: 3,
            title: "Git Review follows the moved chat",
            description: "Git Review reads the untracked file that exists only in the target checkout.",
            journey: Self.journey,
            in: sandbox,
            of: window
        )
    }

    private func openCheckoutMenu(in application: XCUIApplication) {
        openMoveSubmenu(in: application)
    }

    private func openMoveSubmenu(in application: XCUIApplication) {
        let context = application.buttons["Session context menu"]
        XCTAssertTrue(context.waitForExistence(timeout: 5))
        context.click()
        let move = application.menuItems["Move to Checkout"]
        XCTAssertTrue(move.waitForExistence(timeout: 5))
        move.click()
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
            "expected accessibility label beginning with \(expectedPrefix.debugDescription), found \(element.label.debugDescription)",
            file: file,
            line: line
        )
    }
}

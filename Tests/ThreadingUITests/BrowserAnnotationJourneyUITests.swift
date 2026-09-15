import XCTest

@MainActor
final class BrowserAnnotationJourneyUITests: XCTestCase {
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

    func testSavedAnnotationsSendByButtonAndCommandReturn() throws {
        let sandbox = try XCTUnwrap(sandbox)
        let app = XCUIApplication()
        application = app
        let fixture = try sandbox.prepareCodexBrowserAnnotationsFixture()
        _ = sandbox.configure(app)
        fixture.configure(app, scenarioRoot: sandbox.root)
        sandbox.launch(app)
        XCTAssertTrue(app.textViews["composer.prompt.text"].waitForExistence(timeout: 20))

        app.typeKey("b", modifierFlags: [.command, .shift])
        let address = app.textFields["browser.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        address.click()
        address.typeKey("a", modifierFlags: .command)
        address.typeText("about:blank\n")
        let annotate = app.buttons["Annotate Page"]
        XCTAssertTrue(annotate.waitForExistence(timeout: 5))
        annotate.click()
        let canvas = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "Browser Annotation Canvas")
        ).firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.35)).click()
        let note = app.textFields["browser.annotation.note"]
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        note.typeText("Move this action beside its heading\n")
        let send = app.buttons["browser.annotation.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        XCTAssertEqual(send.title, "Send (1)")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.project.appendingPathComponent("annotation-received-1.txt").path
        ), "Enter must save without starting a provider turn")
        try recordScenarioScreenshot(
            checkpoint: "browser-annotations-pending", order: 1, title: "Note ready to send",
            description: "Enter saves a browser note and reveals its counted Send button.",
            journey: "Send browser annotations", in: sandbox, of: app.windows.firstMatch
        )
        send.click()
        XCTAssertTrue(app.staticTexts["Annotations received 1."].waitForExistence(timeout: 10))
        XCTAssertEqual(try String(contentsOf: fixture.project.appendingPathComponent("annotation-received-1.txt"), encoding: .utf8), "received\n")

        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.35)).click()
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        note.typeText("Give this section more space")
        note.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Annotations received 2."].waitForExistence(timeout: 10))
        XCTAssertEqual(try String(contentsOf: fixture.project.appendingPathComponent("annotation-received-2.txt"), encoding: .utf8), "received\n")
        try recordScenarioScreenshot(
            checkpoint: "browser-annotations-sent", order: 2, title: "Annotations delivered",
            description: "The owning conversation accepts both the button send and Command-Return from the editor.",
            journey: "Send browser annotations", in: sandbox, of: app.windows.firstMatch
        )
    }
}

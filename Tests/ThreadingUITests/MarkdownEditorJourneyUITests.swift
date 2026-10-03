import XCTest

@MainActor
final class MarkdownEditorJourneyUITests: XCTestCase {
    func testEditCancelCloseSaveAndReopenDocument() throws {
        continueAfterFailure = false
        let sandbox = try UIScenarioSandbox.make()
        let app = XCUIApplication()
        sandbox.configure(app)
        defer { app.terminate(); try? sandbox.remove() }
        sandbox.launch(app)
        app.menuBars.menuBarItems["File"].click()
        app.menuItems["New Markdown Document"].click()
        let source = app.textViews["markdown-editor.source"]
        XCTAssertTrue(source.waitForExistence(timeout: 10))
        source.click()
        let text = "# My note\n\nSaved from Threading."
        source.typeText(text)
        app.typeKey("w", modifierFlags: .command)
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.click()
        XCTAssertEqual(source.value as? String, text)
        app.typeKey("s", modifierFlags: .command)
        let save = app.sheets.buttons["Save"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        app.typeKey("g", modifierFlags: [.command, .shift])
        app.typeText(sandbox.root.path + "/")
        app.typeKey(.return, modifierFlags: [])
        let filename = app.sheets.textFields.firstMatch
        XCTAssertTrue(filename.waitForExistence(timeout: 5))
        filename.click()
        app.typeKey("a", modifierFlags: .command)
        filename.typeText("note.md")
        save.click()
        let url = sandbox.root.appendingPathComponent("note.md")
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? String(contentsOf: url, encoding: .utf8)) == text
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 10), .completed)
        try recordScenarioScreenshot(
            checkpoint: "markdown-01-saved", order: 1, title: "Markdown source and live preview",
            description: "The standalone editor saved the complete source after cancelling a dirty close.",
            journey: "Markdown documents", in: sandbox, of: app.windows.containing(.textView, identifier: "markdown-editor.source").firstMatch
        )
        app.typeKey("w", modifierFlags: .command)
        app.menuBars.menuBarItems["File"].click()
        app.menuItems["Open Markdown Document…"].click()
        app.typeKey("g", modifierFlags: [.command, .shift])
        app.typeText(url.path)
        app.typeKey(.return, modifierFlags: [])
        app.buttons["Open"].firstMatch.click()
        XCTAssertTrue(source.waitForExistence(timeout: 10))
        XCTAssertEqual(source.value as? String, text)
    }
}

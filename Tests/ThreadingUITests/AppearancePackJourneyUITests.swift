import XCTest

@MainActor
final class AppearancePackJourneyUITests: XCTestCase {
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

    func testCreateActivateRelaunchAndDeactivatePackFromPalette() throws {
        let sandbox = try XCTUnwrap(sandbox)
        let app = XCUIApplication()
        _ = sandbox.configure(app)
        application = app
        sandbox.launch(app)
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20))

        invoke("Create Appearance Pack", in: app)
        let name = app.textFields["appearance-pack.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        name.click()
        name.typeText("Evening")
        app.buttons["Save Pack"].click()
        waitForState(in: sandbox) { state in
            (state["packs"] as? [[String: Any]])?.first?["name"] as? String == "Evening"
                && state["activePackID"] == nil
        }

        search("Activate Evening Pack", in: app)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "Activate Evening Pack")
            .firstMatch.waitForExistence(timeout: 10))
        try recordScenarioScreenshot(checkpoint: "pack-saved", order: 1,
            title: "Saved pack in the command palette", description: "The named theme recipe is available to activate; saving it did not change appearance.",
            journey: "Appearance packs", in: sandbox, of: app.windows.firstMatch)
        app.typeKey(.return, modifierFlags: [])
        waitForState(in: sandbox) { $0["activePackID"] is String }
        let selected = try XCTUnwrap(readState(in: sandbox)?["activePackID"] as? String)
        app.terminate()
        sandbox.launch(app)
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20))
        search("Deactivate Evening Pack", in: app)
        let row = app.descendants(matching: .any).matching(identifier: "Deactivate Evening Pack").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertEqual(readState(in: sandbox)?["activePackID"] as? String, selected)
        try recordScenarioScreenshot(checkpoint: "pack-restored", order: 2,
            title: "Active pack survives relaunch", description: "The restored pack remains available through the command palette's host-owned off switch.",
            journey: "Appearance packs", in: sandbox, of: app.windows.firstMatch)
        app.typeKey(.return, modifierFlags: [])
        waitForState(in: sandbox) { $0["activePackID"] == nil }
        XCTAssertEqual((readState(in: sandbox)?["packs"] as? [[String: Any]])?.count, 1)

        invoke("Use Cyberpunk Theme", in: app)
        waitForState(in: sandbox) { ($0["standaloneThemeID"] as? String) == "cyberpunk" }
        try recordScenarioScreenshot(checkpoint: "theme-command", order: 3,
            title: "Select a theme directly", description: "A standalone theme command uses the same durable appearance owner as packs.",
            journey: "Appearance packs", in: sandbox, of: app.windows.firstMatch)
    }

    private func invoke(_ query: String, in app: XCUIApplication) {
        search(query, in: app)
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", query)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        app.typeKey(.return, modifierFlags: [])
    }

    private func search(_ query: String, in app: XCUIApplication) {
        app.typeKey("p", modifierFlags: [.command, .shift])
        let field = app.descendants(matching: .any).matching(identifier: "Command search").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.typeText(query)
    }

    private func readState(in sandbox: UIScenarioSandbox) -> [String: Any]? {
        let file = sandbox.root.appendingPathComponent("Library/Application Support/Threading/Customization/appearance.json")
        guard let data = try? Data(contentsOf: file),
              let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return envelope["value"] as? [String: Any]
    }

    private func waitForState(in sandbox: UIScenarioSandbox, matching predicate: @escaping ([String: Any]) -> Bool) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.readState(in: sandbox).map(predicate) ?? false
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed)
    }
}

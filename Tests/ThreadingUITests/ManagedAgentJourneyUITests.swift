import XCTest

/// The real settings route restores a verified generation, persists it across app restart,
/// and lets the user inspect and cancel a reinstall without changing that selection.
@MainActor
final class ManagedAgentJourneyUITests: XCTestCase {
    func testRollbackPersistsAndCancellingReinstallKeepsTheSelection() throws {
        continueAfterFailure = false
        let sandbox = try UIScenarioSandbox.make()
        let receipt = sandbox.root.appendingPathComponent("AgentTools/claude/active.json")
        let app = XCUIApplication()
        sandbox.configure(app)
        app.launchEnvironment["THREADING_UI_SCENARIO_MANAGED_AGENTS"] = "1"
        defer { app.terminate(); try? sandbox.remove() }
        sandbox.launch(app)
        XCTAssertEqual(try selectedVersion(at: receipt), "2.0.0")
        openAgentTools(in: app)
        app.buttons["settings.general.agent-tools.claude.options"].click()
        let rollback = app.menuItems["Restore Previous Version"].firstMatch
        XCTAssertTrue(rollback.waitForExistence(timeout: 5))
        // Themed menus live in the app window; native NSMenu traversal cannot click them.
        rollback.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? self.selectedVersion(at: receipt)) == "1.0.0"
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 15), .completed)
        try recordScenarioScreenshot(checkpoint: "managed-agent-rollback", order: 1,
            title: "Previous client version restored",
            description: "The shipping settings action verifies the previous executable and selects its immutable generation.",
            journey: "Managed agent installations", in: sandbox, of: app.windows.firstMatch)

        app.terminate()
        sandbox.launch(app)
        openAgentTools(in: app)
        XCTAssertEqual(try selectedVersion(at: receipt), "1.0.0")
        let install = app.buttons["settings.general.agent-tools.claude.install"]
        XCTAssertTrue(install.waitForExistence(timeout: 5))
        install.click()
        let primary = app.buttons["agent-cli-install.primary"]
        XCTAssertTrue(primary.waitForExistence(timeout: 5))
        XCTAssertEqual(primary.title, "Install")
        try recordScenarioScreenshot(checkpoint: "managed-agent-reinstall", order: 2,
            title: "Reinstall waits for an explicit action",
            description: "The attached installer names the tested version and private location before any download starts.",
            journey: "Managed agent installations", in: sandbox, of: app.windows.firstMatch)
        app.buttons["agent-cli-install.close"].click()
        XCTAssertFalse(primary.exists)
        XCTAssertEqual(try selectedVersion(at: receipt), "1.0.0")
    }

    private func openAgentTools(in app: XCUIApplication) {
        app.typeKey(",", modifierFlags: .command)
        let general = app.radioButtons["General"].firstMatch
        XCTAssertTrue(general.waitForExistence(timeout: 10))
        general.click()
        let options = app.buttons["settings.general.agent-tools.claude.options"]
        XCTAssertTrue(options.waitForExistence(timeout: 5))
        let scroll = app.scrollViews.element(boundBy: max(0, app.scrollViews.count - 1))
        for _ in 0..<12 {
            if options.isHittable { break }
            scroll.scroll(byDeltaX: 0, deltaY: -500)
        }
        XCTAssertTrue(options.isHittable)
    }

    nonisolated private func selectedVersion(at receipt: URL) throws -> String? {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: receipt)) as? [String: Any]
        return (object?["active"] as? [String: String])?["version"]
    }
}

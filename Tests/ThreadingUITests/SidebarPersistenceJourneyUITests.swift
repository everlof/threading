import XCTest

@MainActor
final class SidebarPersistenceJourneyUITests: XCTestCase {
    func testArrangementSurvivesAppRelaunch() throws {
        continueAfterFailure = false
        let sandbox = try UIScenarioSandbox.make()
        let app = XCUIApplication()
        sandbox.configure(app)
        defer { app.terminate(); try? sandbox.remove() }
        sandbox.launch(app)
        closeLaunchBrowser(in: app)

        for title in ["Headings for Lone Branches", "Compact Tree", "Show Five Chats per Project"] {
            openArrangement(in: app)
            app.menuItems[title].click()
        }
        openArrangement(in: app)
        app.menuItems.matching(NSPredicate(format: "label BEGINSWITH %@", "Sort by")).firstMatch.click()
        let nameOrder = app.menuItems["Sort by Name"]
        XCTAssertTrue(nameOrder.waitForExistence(timeout: 5))
        nameOrder.click()
        openArrangement(in: app)
        app.menuItems["Z to A"].click()
        openArrangement(in: app)
        app.menuItems.matching(NSPredicate(format: "label BEGINSWITH %@", "Group by")).firstMatch.click()
        let noGrouping = app.menuItems["None"]
        XCTAssertTrue(noGrouping.waitForExistence(timeout: 5))
        noGrouping.click()

        for checkpoint in 1...2 {
            if checkpoint == 2 {
                app.typeKey(.escape, modifierFlags: [])
                app.terminate()
                sandbox.launch(app)
                closeLaunchBrowser(in: app)
            }
            openArrangement(in: app)
            assertSelected("Headings for Lone Branches", false, in: app)
            assertSelected("Compact Tree", true, in: app)
            assertSelected("Show Five Chats per Project", false, in: app)
            assertSelected("Z to A", true, in: app)
            assertSelected("A to Z", false, in: app)
            XCTAssertFalse(app.menuItems["Headings for Lone Branches"].isEnabled)
            XCTAssertTrue(app.menuItems.matching(NSPredicate(
                format: "label BEGINSWITH %@ AND label CONTAINS %@", "Group by", "None"
            )).firstMatch.exists)
            try recordScenarioScreenshot(
                checkpoint: "sidebar-arrangement-\(checkpoint)", order: checkpoint,
                title: checkpoint == 1 ? "Chosen sidebar arrangement" : "Arrangement after relaunch",
                description: "Compact tree, all chats, no branch grouping or lone-branch headings and reverse name order remain selected.",
                journey: "Sidebar persistence", in: sandbox, of: app.windows.firstMatch
            )
        }
    }

    private func openArrangement(in app: XCUIApplication) {
        let button = app.buttons["Grouping and Sorting"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.click()
        XCTAssertTrue(app.menuItems["Compact Tree"].waitForExistence(timeout: 5))
    }

    private func closeLaunchBrowser(in app: XCUIApplication) {
        let address = app.textFields["browser.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 20))
        app.typeKey("w", modifierFlags: .command)
        XCTAssertFalse(address.exists)
    }

    private func assertSelected(
        _ title: String, _ selected: Bool, in app: XCUIApplication,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let item = app.menuItems[title]
        XCTAssertTrue(item.exists, title, file: file, line: line)
        XCTAssertEqual((item.value as? NSNumber)?.boolValue, selected, title, file: file, line: line)
    }
}

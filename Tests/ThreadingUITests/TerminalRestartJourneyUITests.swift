import Darwin
import XCTest

@MainActor
final class TerminalRestartJourneyUITests: XCTestCase {
    func testBlankTerminalRestartsFromSessionMenu() throws {
        continueAfterFailure = false
        let sandbox = try UIScenarioSandbox.make()
        let fixture = try sandbox.prepareCodexCheckoutMoveFixture()
        let app = XCUIApplication()
        sandbox.configure(app)
        fixture.configure(app, scenarioRoot: sandbox.root)
        app.launchEnvironment["THREADING_UI_SCENARIO_TERMINAL"] = "1"
        defer { app.terminate(); try? sandbox.remove() }
        sandbox.launch(app)
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 20))
        let launches = sandbox.root.appendingPathComponent("terminal-launches.txt")
        let first = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            Self.processIDs(at: launches).count == 1
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [first], timeout: 20), .completed)
        let oldPID = try XCTUnwrap(Self.processIDs(at: launches).first)
        let rowTitle = app.staticTexts["sidebar.session.title"]
        XCTAssertTrue(rowTitle.waitForExistence(timeout: 5))
        rowTitle.rightClick()
        let restart = app.menuItems["Restart Terminal"]
        XCTAssertTrue(restart.waitForExistence(timeout: 5))
        try recordScenarioScreenshot(
            checkpoint: "terminal-restart-01-menu", order: 1,
            title: "Restart a blank terminal",
            description: "The shared session menu offers recovery without typing into the terminal.",
            journey: "Restart terminal", in: sandbox, of: window
        )
        restart.click()
        let second = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            Self.processIDs(at: launches).count == 2
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [second], timeout: 20), .completed)
        XCTAssertNotEqual(Self.processIDs(at: launches).last, oldPID)
        let records = try String(contentsOf: launches, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(records.map { String($0.split(separator: " ").last ?? "") },
                       Array(repeating: "00000000-0000-0000-0000-000000000102", count: 2),
                       "restart changed the saved provider conversation")
        XCTAssertEqual(kill(oldPID, 0), -1, "the old terminal process survived the restart")
        XCTAssertEqual(errno, ESRCH)
        try recordScenarioScreenshot(
            checkpoint: "terminal-restart-02-resumed", order: 2,
            title: "Fresh terminal for the same chat",
            description: "The old process is gone and the same session has launched its replacement.",
            journey: "Restart terminal", in: sandbox, of: window
        )
    }
    nonisolated private static func processIDs(at url: URL) -> [Int32] {
        ((try? String(contentsOf: url, encoding: .utf8)) ?? "")
            .split(separator: "\n").compactMap { $0.split(separator: " ").first.flatMap { Int32($0) } }
    }
}

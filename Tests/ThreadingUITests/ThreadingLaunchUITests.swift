import XCTest

final class ThreadingLaunchUITests: XCTestCase {
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

    /// The first application-level contract: the shipping executable reaches a real window while
    /// every Cocoa store and child-process home is isolated from the developer's own state.
    /// Scenario-specific tests will build on this launch path instead of inventing a second app.
    func testApplicationLaunchesWithIsolatedState() throws {
        let app = XCUIApplication()
        try XCTUnwrap(sandbox).configure(app)
        application = app

        app.launch()

        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 20),
            "Threading did not reach the foreground"
        )
        XCTAssertTrue(
            app.windows.firstMatch.waitForExistence(timeout: 10),
            "Threading reached the foreground without presenting its main window"
        )
    }
}

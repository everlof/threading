import XCTest

@MainActor
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
        let sandbox = try XCTUnwrap(sandbox)
        let app = XCUIApplication()
        let targetSize = sandbox.configure(app)
        application = app

        app.launch()

        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 20),
            "Threading did not reach the foreground"
        )
        let window = app.windows.firstMatch
        XCTAssertTrue(
            window.waitForExistence(timeout: 10),
            "Threading reached the foreground without presenting its main window"
        )
        UIWindowContract.assertApplied(to: window, expected: targetSize)
        try recordScenarioScreenshot(
            checkpoint: "default-threading-window",
            order: 1,
            title: "Default Threading window",
            description: "A fresh isolated profile launches in the adaptive Threading theme inside the native macOS window frame.",
            journey: "Default appearance",
            in: sandbox,
            of: window
        )
    }
}

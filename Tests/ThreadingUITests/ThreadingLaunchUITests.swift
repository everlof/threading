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

        sandbox.launch(app)

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

    /// The same typed setting that an installed Release app reads must reach the real window.
    /// The scenario bootstrap writes it inside the isolated app process before that window opens.
    func testMainThreadStallHUDRespectsTheLaunchPreference() throws {
        let sandbox = try XCTUnwrap(sandbox)
        let hiddenApp = XCUIApplication()
        _ = sandbox.configure(hiddenApp)
        hiddenApp.launchEnvironment["THREADING_UI_SCENARIO_STALL_HUD"] = "0"
        application = hiddenApp
        sandbox.launch(hiddenApp)
        XCTAssertTrue(hiddenApp.windows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(hiddenApp.buttons["debug.main-thread-hud"].exists)
        hiddenApp.terminate()

        let visibleApp = XCUIApplication()
        _ = sandbox.configure(visibleApp)
        visibleApp.launchEnvironment["THREADING_UI_SCENARIO_STALL_HUD"] = "1"
        application = visibleApp
        sandbox.launch(visibleApp)
        let window = visibleApp.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        XCTAssertTrue(
            visibleApp.buttons["debug.main-thread-hud"].waitForExistence(timeout: 10),
            "the opt-in must install the readout in the app window"
        )
        try recordScenarioScreenshot(
            checkpoint: "main-thread-stall-readout",
            order: 1,
            title: "Main-thread stall readout",
            description: "An explicit local preference shows the diagnostic pill in the real app window.",
            journey: "Main-thread stall diagnostics",
            in: sandbox,
            of: window
        )
    }
}

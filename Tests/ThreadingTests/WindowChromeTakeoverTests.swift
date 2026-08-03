import AppKit
import XCTest
@testable import Threading

/// The frame exchange: a theme that states chrome takes the main window frameless, and a theme
/// that states none hands the frame back — live, with the window's size, key status, toolbar
/// and fullscreen capability all accounted for. Every window here is built and never shown,
/// which is exactly the state the exchange must also survive (a hosted test's theme change
/// must not order anything on screen).
@MainActor
final class WindowChromeTakeoverTests: XCTestCase {

    private var previousTheme: AppTheme!
    private var controller: MainWindowController?

    override func setUp() {
        super.setUp()
        previousTheme = AppThemeLibrary.current
    }

    override func tearDown() {
        controller = nil
        AppThemeLibrary.apply(previousTheme)
        // `apply` early-returns when the library already held this theme, so a palette a test
        // set directly would survive it. Resync explicitly.
        AppThemePalette.set(previousTheme)
        super.tearDown()
    }

    // MARK: - Fixtures

    private static let themeID = AppThemeID("custom-window-chrome-takeover-tests")

    private func makeTakeoverTheme() throws -> AppTheme {
        let base = AppThemeStyles.cyberpunk
        let kind = base.availableVariants[0]
        let chrome = WindowChromeStyle(
            titleBar: .init(
                activeGradient: .init(stops: [
                    .init(color: NSColor(hex: "#000080")!, position: 0),
                    .init(color: NSColor(hex: "#1084D0")!, position: 1)
                ], angleDegrees: 90),
                ink: .white,
                buttonGlyphStyle: .squares
            ),
            frame: .init(width: 4)
        )
        return try AppThemeEditing.assemble(
            id: Self.themeID,
            name: "Takeover Fixture",
            mode: kind == .dark ? .dark : .light,
            summary: nil,
            variants: [kind: AppThemeEditing.makeVariant(
                named: "Takeover Fixture", from: base, kind: kind, chrome: .set(chrome)
            )]
        )
    }

    private func window(of controller: MainWindowController) throws -> TitlebarActionWindow {
        try XCTUnwrap(controller.window as? TitlebarActionWindow)
    }

    /// One turn of the run loop, for the floors and widths the controller claims a turn after
    /// setup. Nothing here is on screen, so nothing can trip the last-window-closed trap.
    private func pumpRunLoop() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    // MARK: - Creation

    /// A theme active at launch is honoured at creation — the window is born frameless, never
    /// flipped after the fact (`AppThemeLibrary.restore()` runs before the controller exists).
    func testAWindowCreatedUnderATakeoverThemeIsFramelessFromBirth() throws {
        AppThemePalette.set(try makeTakeoverTheme())
        let controller = MainWindowController()
        self.controller = controller
        let window = try window(of: controller)

        XCTAssertEqual(window.styleMask, WindowChromeCoordinator.takeoverMask)
        XCTAssertNil(window.toolbar)
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenPrimary),
                      "the fullscreen menu item must keep working without a titled frame")
        XCTAssertEqual(controller.chromeCoordinator?.isTakeoverActive, true,
                       "the coordinator initialises its record from the mask it finds")
    }

    // MARK: - The Exchange

    func testAThemeChangeExchangesTheFrameBothWaysPreservingTheWindow() throws {
        AppThemePalette.set(.system)
        let controller = MainWindowController()
        self.controller = controller
        let window = try window(of: controller)
        let coordinator = try XCTUnwrap(controller.chromeCoordinator)

        XCTAssertEqual(window.styleMask, WindowChromeCoordinator.nativeMask)
        XCTAssertNotNil(window.toolbar)
        let nativeBehavior = window.collectionBehavior
        let frame = window.frame

        AppThemePalette.set(try makeTakeoverTheme())
        coordinator.applyCurrentTheme()

        XCTAssertEqual(window.styleMask, WindowChromeCoordinator.takeoverMask)
        XCTAssertNil(window.toolbar, "a toolbar may only exist on a titled window")
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenPrimary))
        XCTAssertEqual(window.frame.origin.x, frame.origin.x, accuracy: 1)
        XCTAssertEqual(window.frame.origin.y, frame.origin.y, accuracy: 1)
        XCTAssertEqual(window.frame.width, frame.width, accuracy: 1)
        XCTAssertEqual(window.frame.height, frame.height, accuracy: 1)

        AppThemePalette.set(.system)
        coordinator.applyCurrentTheme()

        XCTAssertEqual(window.styleMask, WindowChromeCoordinator.nativeMask)
        XCTAssertNotNil(window.toolbar, "the native frame returns with its toolbar")
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertEqual(window.collectionBehavior, nativeBehavior)
        XCTAssertEqual(window.frame.origin.x, frame.origin.x, accuracy: 1)
        XCTAssertEqual(window.frame.width, frame.width, accuracy: 1)
    }

    /// The exchange rides the theme notification itself — the coordinator observes, nobody
    /// has to remember to call it.
    func testTheLibraryNotificationDrivesTheExchange() throws {
        let controller = MainWindowController()
        self.controller = controller
        let coordinator = try XCTUnwrap(controller.chromeCoordinator)
        XCTAssertFalse(coordinator.isTakeoverActive)

        AppThemeLibrary.apply(try makeTakeoverTheme())
        XCTAssertTrue(coordinator.isTakeoverActive)

        AppThemeLibrary.apply(.system)
        XCTAssertFalse(coordinator.isTakeoverActive)
    }

    /// A mask flip inside fullscreen detaches the window from its space, so a change arriving
    /// there is parked and completed on the way out. Fullscreen is simulated through the
    /// coordinator's own seam — AppKit refuses `.fullScreen` set on a real mask outside a
    /// genuine transition, loudly enough to fail a test that tries.
    func testAFullscreenWindowParksTheExchangeUntilExit() throws {
        let controller = MainWindowController()
        self.controller = controller
        let window = try window(of: controller)
        let coordinator = try XCTUnwrap(controller.chromeCoordinator)

        var fullscreen = true
        coordinator.isInFullscreen = { _ in fullscreen }

        AppThemePalette.set(try makeTakeoverTheme())
        coordinator.applyCurrentTheme()

        XCTAssertTrue(window.styleMask.contains(.titled),
                      "the mask must not change hands mid-fullscreen")
        XCTAssertEqual(coordinator.pendingChange, true)

        fullscreen = false
        coordinator.windowDidExitFullScreen()

        XCTAssertEqual(window.styleMask, WindowChromeCoordinator.takeoverMask)
        XCTAssertNil(coordinator.pendingChange)

        // A parked change the theme walks back before exit dissolves without a flip.
        fullscreen = true
        AppThemePalette.set(.system)
        coordinator.applyCurrentTheme()
        XCTAssertEqual(coordinator.pendingChange, false)
        AppThemePalette.set(try makeTakeoverTheme())
        coordinator.applyCurrentTheme()
        XCTAssertNil(coordinator.pendingChange, "wanting what you already wear parks nothing")
    }

    // MARK: - Measurements

    /// In takeover nothing floats over the panes — no traffic lights, no toolbar — so the
    /// sidebar's floor falls back to its own minimum instead of the window-controls clearance.
    func testTakeoverMeasurementsFallBackToTheSidebarsOwnMinimum() throws {
        let controller = MainWindowController()
        self.controller = controller
        let coordinator = try XCTUnwrap(controller.chromeCoordinator)
        let sidebarItem = try XCTUnwrap(controller.splitViewController.splitViewItems.first)

        pumpRunLoop()
        let nativeFloor = sidebarItem.minimumThickness
        XCTAssertGreaterThan(nativeFloor, SidebarDefaults.minWidth,
                             "the native floor clears the window's own controls")

        AppThemePalette.set(try makeTakeoverTheme())
        coordinator.applyCurrentTheme()
        pumpRunLoop()
        XCTAssertEqual(sidebarItem.minimumThickness, SidebarDefaults.minWidth,
                       "with nothing floating over the column its own minimum is the floor")

        AppThemePalette.set(.system)
        coordinator.applyCurrentTheme()
        pumpRunLoop()
        XCTAssertGreaterThan(sidebarItem.minimumThickness, SidebarDefaults.minWidth,
                             "the native clearance returns with the native frame")
    }

    /// The stock Windows 98 theme is the first real user of the mechanism; the fixture
    /// themes above prove the mechanics, this proves the shipped theme actually engages them.
    func testTheStockWin98ThemeTakesTheWindowOverAndHandsItBack() throws {
        let controller = MainWindowController()
        self.controller = controller
        let window = try window(of: controller)
        let coordinator = try XCTUnwrap(controller.chromeCoordinator)

        XCTAssertTrue(AppThemeStyles.win98.takesOverWindowChrome)
        AppThemePalette.set(AppThemeStyles.win98)
        coordinator.applyCurrentTheme()

        XCTAssertEqual(window.styleMask, WindowChromeCoordinator.takeoverMask)
        XCTAssertNil(window.toolbar)

        AppThemePalette.set(.system)
        coordinator.applyCurrentTheme()

        XCTAssertEqual(window.styleMask, WindowChromeCoordinator.nativeMask)
        XCTAssertNotNil(window.toolbar)
    }

    // MARK: - The Window Itself

    /// Frameless windows refuse key and main by default, which would leave the app's only
    /// window deaf to the keyboard; and the titled-window double-click strip must never
    /// answer for a window that has no titlebar to double-click.
    func testAFramelessWindowStillTakesKeyAndNeverClaimsATitlebarStrip() throws {
        AppThemePalette.set(try makeTakeoverTheme())
        let controller = MainWindowController()
        self.controller = controller
        let window = try window(of: controller)

        XCTAssertTrue(window.canBecomeKey)
        XCTAssertTrue(window.canBecomeMain)

        let nearTop = NSPoint(x: window.frame.width / 2, y: window.frame.height - 1)
        XCTAssertFalse(window.isInTitlebarStrip(nearTop),
                       "a frameless window has no strip; the band owns the double-click")
    }
}

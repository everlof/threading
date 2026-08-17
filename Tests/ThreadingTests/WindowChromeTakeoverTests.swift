import AppKit
import XCTest
@testable import Threading

/// The frame exchange: a theme that states chrome takes the main window frameless, and a theme
/// that states none hands the frame back — live, with the window's size, key status, toolbar
/// and fullscreen capability all accounted for. Every window here is built and never shown,
/// which is exactly the state the exchange must also survive (a hosted test's theme change
/// must not order anything on screen).
@MainActor
final class WindowChromeTakeoverTests: HostedStoreTestCase {

    private var previousTheme: AppTheme!
    private var controller: MainWindowController?

    private var previousBackdrop: WindowBackdrop.Ground = .chrome

    override func setUp() {
        super.setUp()
        previousTheme = AppThemeLibrary.current
        previousBackdrop = WindowBackdrop.ground
    }

    override func tearDown() {
        controller = nil
        AppThemeLibrary.apply(previousTheme)
        // `apply` early-returns when the library already held this theme, so a palette a test
        // set directly would survive it. Resync explicitly.
        AppThemePalette.set(previousTheme)
        WindowBackdrop.set(previousBackdrop)
        super.tearDown()
    }

    // MARK: - Fixtures

    private static let themeID = AppThemeID("custom-window-chrome-takeover-tests")

    private func makeTakeoverTheme(
        frameWidth: CGFloat = 4,
        frameCornerRadius: CGFloat = 0,
        commands: WindowChromeStyle.TitleBar.CommandPlacement = .ownRow
    ) throws -> AppTheme {
        let base = AppThemeStyles.cyberpunk
        let kind = base.availableVariants[0]
        let chrome = WindowChromeStyle(
            titleBar: .init(
                activeGradient: .init(stops: [
                    .init(color: NSColor(hex: "#000080")!, position: 0),
                    .init(color: NSColor(hex: "#1084D0")!, position: 1)
                ], angleDegrees: 90),
                ink: .white,
                height: commands == .inTitleBar ? 36 : nil,
                buttonGlyphStyle: .squares,
                commands: commands
            ),
            frame: .init(width: frameWidth, cornerRadius: frameCornerRadius)
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

    /// A colour as the window would paint it: `WindowBackdrop.color` for the chrome ground is a
    /// dynamic role — a fresh `NSColor(name:)` on every read — so two reads compare unequal as
    /// objects while resolving to the same pixels. The pixels are the claim.
    private func resolved(_ color: NSColor, in window: NSWindow) throws -> [CGFloat] {
        var components: [CGFloat] = []
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            if let srgb = color.usingColorSpace(.sRGB) {
                components = [
                    srgb.redComponent, srgb.greenComponent, srgb.blueComponent, srgb.alphaComponent
                ]
            }
        }
        XCTAssertEqual(components.count, 4, "\(color) did not resolve to sRGB")
        return components
    }

    private func assertBacking(
        of window: NSWindow,
        resolvesTo expected: NSColor,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let actual = try resolved(window.backgroundColor, in: window)
        let wanted = try resolved(expected, in: window)
        for (a, w) in zip(actual, wanted) {
            XCTAssertEqual(a, w, accuracy: 0.002, message, file: file, line: line)
        }
    }

    // MARK: - Creation

    /// A theme active at launch is honoured at creation — the window is born frameless, never
    /// flipped after the fact (`AppThemeLibrary.restore()` runs before the controller exists).
    func testAWindowCreatedUnderATakeoverThemeIsFramelessFromBirth() throws {
        AppThemePalette.set(try makeTakeoverTheme())
        let controller = makeMainWindowController()
        self.controller = controller
        let window = try window(of: controller)

        XCTAssertEqual(window.styleMask, WindowChromeCoordinator.takeoverMask)
        XCTAssertNil(window.toolbar)
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenPrimary),
                      "the fullscreen menu item must keep working without a titled frame")
        XCTAssertEqual(controller.chromeCoordinator?.isTakeoverActive, true,
                       "the coordinator initialises its record from the mask it finds")
    }

    /// The same launch, for the window's *backing*. A theme whose silhouette is smaller than
    /// the window's rectangle — Tiger's rounded frame, BeOS's leading tab — clears the part it
    /// gives up, so an opaque backing simply paints it again: launched under Tiger the drawn
    /// corner wore a white wedge inside a square outline, and under BeOS the shoulders beside
    /// the tab were filled. Birth has to state the surface the flip states.
    func testAWindowBornUnderAShapedThemeIsTransparentBehindIt() throws {
        for theme in [AppThemeStyles.aquaTiger, AppThemeStyles.beOS] {
            AppThemePalette.set(theme)
            let controller = makeMainWindowController()
            self.controller = controller
            let window = try window(of: controller)

            XCTAssertFalse(window.isOpaque, "\(theme.id) gives up part of its rectangle")
            XCTAssertEqual(window.backgroundColor.alphaComponent, 0, accuracy: 0.001,
                           "\(theme.id) must have nothing painted behind the shape it drew")
        }
    }

    /// And the square takeover keeps an opaque backing — the transparency is for the shapes
    /// that need it, not for every app-drawn frame — painted with the pane's backdrop, which is
    /// also what a theme change out of takeover hands the native frame.
    func testAWindowBornUnderASquareTakeoverKeepsItsBackingAndRestoresIt() throws {
        AppThemePalette.set(try makeTakeoverTheme())
        let controller = makeMainWindowController()
        self.controller = controller
        let window = try window(of: controller)
        let coordinator = try XCTUnwrap(controller.chromeCoordinator)

        XCTAssertTrue(window.isOpaque)
        try assertBacking(of: window, resolvesTo: WindowBackdrop.color,
                          "a square takeover's backing is the pane's backdrop")

        AppThemePalette.set(.system)
        coordinator.applyCurrentTheme()
        XCTAssertEqual(window.styleMask, WindowChromeCoordinator.nativeMask)
        XCTAssertTrue(window.isOpaque)
        try assertBacking(of: window, resolvesTo: WindowBackdrop.color,
                          "the native frame is handed the pane's backdrop")
    }

    /// The backing has one owner. `TerminalContainerViewController` records its colour through
    /// `WindowBackdrop` on every session swap, and for as long as it painted the window itself
    /// that write landed on top of the coordinator's: launched under a rounded authored frame,
    /// every swap made the four cleared corners opaque again — captured, each
    /// wore a square of the terminal palette's black past the frame's curve. Now a backdrop
    /// change reaches the window only through the coordinator, which knows the dress: painted
    /// under a native frame, ignored behind a shape, and the pane's *current* colour is what a
    /// flip back to native paints, not a snapshot from before the takeover.
    func testAPaneBackdropChangeNeverPaintsBehindAShapedFrame() throws {
        let shapedTheme = try makeTakeoverTheme(
            frameWidth: 1,
            frameCornerRadius: 12,
            commands: .inTitleBar
        )
        AppThemePalette.set(shapedTheme)
        let controller = makeMainWindowController()
        self.controller = controller
        let window = try window(of: controller)
        let coordinator = try XCTUnwrap(controller.chromeCoordinator)
        XCTAssertFalse(window.isOpaque)
        XCTAssertEqual(window.backgroundColor.alphaComponent, 0, accuracy: 0.001)

        // The path that shipped the defect: a pane inside this window swapping its surface.
        // `showComposer` applies the chrome ground the way every swap does, and used to write
        // the window with it — from inside the shaped frame, on every selection change.
        let pane = TerminalContainerViewController()
        let root = try XCTUnwrap(window.contentView)
        pane.view.frame = root.bounds
        root.addSubview(pane.view)
        pane.showComposer(projectID: nil)
        XCTAssertFalse(window.isOpaque, "a surface swap must not paint behind the frame")
        XCTAssertEqual(window.backgroundColor.alphaComponent, 0, accuracy: 0.001,
                       "the pane painted the corners the frame cleared")
        pane.view.removeFromSuperview()

        // And the recorded backdrop moving on its own — a session with another palette.
        WindowBackdrop.set(.terminal(.red))
        XCTAssertFalse(window.isOpaque, "a session swap must not paint behind the frame")
        XCTAssertEqual(window.backgroundColor.alphaComponent, 0, accuracy: 0.001,
                       "the terminal palette was painted into the corners the frame cleared")

        AppThemePalette.set(.system)
        coordinator.applyCurrentTheme()
        XCTAssertTrue(window.isOpaque)
        try assertBacking(of: window, resolvesTo: .red,
                          "native dress paints the backdrop the pane recorded during takeover")

        WindowBackdrop.set(.terminal(.blue))
        try assertBacking(of: window, resolvesTo: .blue,
                          "a session swap under a native frame repaints the window")

        AppThemePalette.set(shapedTheme)
        coordinator.applyCurrentTheme()
        XCTAssertFalse(window.isOpaque)
        XCTAssertEqual(window.backgroundColor.alphaComponent, 0, accuracy: 0.001)
    }

    // MARK: - The Exchange

    func testAThemeChangeExchangesTheFrameBothWaysPreservingTheWindow() throws {
        AppThemePalette.set(.system)
        let controller = makeMainWindowController()
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
        let controller = makeMainWindowController()
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
        let controller = makeMainWindowController()
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
        let controller = makeMainWindowController()
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

    private func themedIconButtons(in root: NSView) -> [ThemedIconButton] {
        root.subviews.flatMap { view -> [ThemedIconButton] in
            if let button = view as? ThemedIconButton { return [button] }
            return themedIconButtons(in: view)
        }
    }

    /// The product theme owns application surfaces but leaves the actual window to macOS.
    func testTheStockThreadingThemeKeepsTheNativeMacOSWindow() throws {
        let controller = makeMainWindowController()
        self.controller = controller
        let window = try window(of: controller)
        let coordinator = try XCTUnwrap(controller.chromeCoordinator)

        XCTAssertFalse(AppThemeStyles.threading.takesOverWindowChrome)
        AppThemePalette.set(AppThemeStyles.threading)
        coordinator.applyCurrentTheme()

        XCTAssertEqual(window.styleMask, WindowChromeCoordinator.nativeMask)
        XCTAssertNotNil(window.toolbar)

        let host = try XCTUnwrap(
            window.contentViewController as? WindowChromeHostViewController
        )
        host.view.layoutSubtreeIfNeeded()
        XCTAssertFalse(host.isTakeoverActive)
        XCTAssertFalse(
            host.takeoverChromeIsMaterialized,
            "native dress eagerly constructed the app-drawn frame it does not use"
        )
    }

    /// The stock Windows 98 theme is the first real user of the mechanism; the fixture
    /// themes above prove the mechanics, this proves the shipped theme actually engages them.
    func testTheStockWin98ThemeTakesTheWindowOverAndHandsItBack() throws {
        let controller = makeMainWindowController()
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

    /// BeOS's body is rectangular but its top is only a title tab. The shoulders must really
    /// be transparent so AppKit's shadow follows that outline, including a takeover-to-
    /// takeover switch where the style mask itself does not change.
    func testAShapedTabOwnsAndRestoresTheWindowsBackingSurface() throws {
        AppThemePalette.set(.system)
        let controller = makeMainWindowController()
        self.controller = controller
        let window = try window(of: controller)
        let coordinator = try XCTUnwrap(controller.chromeCoordinator)
        XCTAssertTrue(window.isOpaque)
        try assertBacking(of: window, resolvesTo: WindowBackdrop.color,
                          "a native window is painted with the pane's backdrop")

        AppThemePalette.set(AppThemeStyles.beOS)
        coordinator.applyCurrentTheme()
        XCTAssertFalse(window.isOpaque)
        XCTAssertEqual(window.backgroundColor.alphaComponent, 0, accuracy: 0.001)

        AppThemePalette.set(AppThemeStyles.win98)
        coordinator.applyCurrentTheme()
        XCTAssertEqual(window.styleMask, WindowChromeCoordinator.takeoverMask)
        XCTAssertTrue(window.isOpaque)
        try assertBacking(of: window, resolvesTo: WindowBackdrop.color,
                          "a square takeover is opaque again, over the pane's backdrop")

        AppThemePalette.set(AppThemeStyles.beOS)
        coordinator.applyCurrentTheme()
        XCTAssertFalse(window.isOpaque)

        AppThemePalette.set(.system)
        coordinator.applyCurrentTheme()
        XCTAssertTrue(window.isOpaque)
        try assertBacking(of: window, resolvesTo: WindowBackdrop.color,
                          "the native frame is handed the pane's backdrop")
    }

    // MARK: - The Corner

    /// A rounded frame's seat runs the whole way round, corner included.
    ///
    /// The frame draws its one-point seat along a rounded outline and the host clips the content
    /// to the same radius — but the band and the workspace were inset from the four edges only,
    /// so their square corners reached into the curve and covered the seat there. Under the
    /// former twelve-point product frame the border ran along the top and down the left edge,
    /// stopped where the arc began, and the band's own clipped corner filled in between: two
    /// straight lines that never met, which is what was reported as the window having no proper
    /// edge. The content is now held `frameWidth` inside the outline through the corner too, so
    /// every pixel centred on the seat's curve is seat ink, everything beyond it is transparent,
    /// and everything inside it is content — with nothing of the band on the curve.
    func testTheFrameSeatRunsThroughARoundedCorner() throws {
        AppThemePalette.set(try makeTakeoverTheme(
            frameWidth: 1,
            frameCornerRadius: 12,
            commands: .inTitleBar
        ))
        let controller = makeMainWindowController()
        self.controller = controller
        let window = try window(of: controller)
        window.setContentSize(NSSize(width: 800, height: 600))
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()

        let appearance = try XCTUnwrap(WindowChromeAppearance.resolve())
        let radius = appearance.frameSilhouetteCornerRadius
        XCTAssertGreaterThan(radius, 0, "the fixture theme states a rounded frame")

        let rep = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / content.bounds.width

        // This theme seats the window's own commands in its caption, so the first thing inside
        // the corner is the sidebar toggle rather than the band's ground — and the toggle's
        // active plate is outlined in the same border role the seat is drawn in, which no
        // nearest-ink classification can tell apart. Its pixels are therefore excluded from the
        // "inside is content" claim only. The curve itself is scanned with the control in
        // place, which is the claim that matters: a control near the corner may not cover the
        // seat, and this is what says so.
        let host = try XCTUnwrap(window.contentViewController as? WindowChromeHostViewController)
        let commandBoxes = themedIconButtons(in: host.bandView).map { button -> CGRect in
            let rect = content.convert(button.bounds, from: button)
            return CGRect(
                x: rect.minX * scale,
                y: (content.bounds.height - rect.maxY) * scale,
                width: rect.width * scale,
                height: rect.height * scale
            ).insetBy(dx: -scale, dy: -scale)
        }
        XCTAssertFalse(commandBoxes.isEmpty, "the caption lost the commands it seats")

        // The three inks a corner pixel can be nearest to, resolved as the frame drew them. The
        // band is pictured inactive (an unshown window is never key), but both gradients' top
        // stops are candidates so the claim does not rest on which one a fixture happens to draw.
        let seat = try resolved(Design.Surface.border, in: window)
        let ground = try resolved(Design.Surface.ground, in: window)
        var bands: [[CGFloat]] = []
        for color in [appearance.activeGradient.colors, appearance.inactiveGradient.colors]
            .compactMap(\.first) {
            bands.append(try resolved(color, in: window))
        }
        func distance(_ a: [CGFloat], _ b: [CGFloat]) -> CGFloat {
            zip(a.prefix(3), b.prefix(3)).map { ($0 - $1) * ($0 - $1) }.reduce(0, +)
        }
        func classify(_ pixel: [CGFloat]) -> String {
            guard pixel[3] >= 0.05 else { return "outside" }
            let candidates: [(String, CGFloat)] = [("seat", distance(pixel, seat)),
                                                   ("ground", distance(pixel, ground))]
                + bands.map { ("band", distance(pixel, $0)) }
            return candidates.min { $0.1 < $1.1 }!.0
        }

        // Every pixel of the corner square, sorted by where its centre falls against the seat's
        // centreline (half a point inside the silhouette). Not a walk down the diagonal: at 1x
        // the pixel on the exact 45° line straddles the one-point seat with its centre a full
        // point away, and reads as a dim blend — the seat is unmistakable one pixel to either
        // side. Which scale an unshown window renders at depends on the process, so the claim
        // is made per pixel centre and holds at 1x and 2x alike.
        let centre = radius * scale
        let seatRadius = (radius - 0.5) * scale
        let tolerance = 0.2 * scale
        var onSeat: [String] = []
        var beyond: [String] = []
        var within: [String] = []
        for y in 0..<Int(centre) {
            for x in 0..<Int(centre) {
                let dx = centre - (CGFloat(x) + 0.5)
                let dy = centre - (CGFloat(y) + 0.5)
                let distance = (dx * dx + dy * dy).squareRoot()
                let angle = atan2(dy, dx) * 180 / .pi
                // The curve only: the straight runs are asserted separately below.
                guard angle > 10, angle < 80 else { continue }
                let color = try XCTUnwrap(rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                let kind = classify([
                    color.redComponent, color.greenComponent, color.blueComponent,
                    color.alphaComponent
                ])
                if abs(distance - seatRadius) <= tolerance {
                    onSeat.append(kind)
                } else if distance > radius * scale + 0.7 * scale {
                    beyond.append(kind)
                } else if distance < seatRadius - 0.5 * scale - 0.7 * scale {
                    let centre = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
                    guard !commandBoxes.contains(where: { $0.contains(centre) }) else { continue }
                    within.append(kind)
                }
            }
        }

        XCTAssertGreaterThanOrEqual(onSeat.count, 2, "no pixel centres landed on the seat's curve")
        XCTAssertEqual(onSeat.filter { $0 == "seat" }.count, onSeat.count,
                       "the seat does not run through the corner — the content covers it: \(onSeat)")
        XCTAssertFalse(beyond.isEmpty)
        XCTAssertEqual(beyond.filter { $0 == "outside" }.count, beyond.count,
                       "the frame's outer corner was not cleared: \(beyond)")
        XCTAssertFalse(within.isEmpty)
        XCTAssertFalse(within.contains("seat") || within.contains("outside"),
                       "the seat bleeds into the content, or the content is missing: \(within)")

        // And on a straight run the picture is unchanged: seat at the very edge, content one
        // frame-width in.
        let midY = Int((content.bounds.height / 2 * scale).rounded())
        let edge = try XCTUnwrap(rep.colorAt(x: 0, y: midY)?.usingColorSpace(.sRGB))
        XCTAssertEqual(classify([edge.redComponent, edge.greenComponent, edge.blueComponent,
                                 edge.alphaComponent]), "seat",
                       "the straight run lost its seat")
    }

    // MARK: - The Window Itself

    /// Frameless windows refuse key and main by default, which would leave the app's only
    /// window deaf to the keyboard; and the titled-window double-click strip must never
    /// answer for a window that has no titlebar to double-click.
    func testAFramelessWindowStillTakesKeyAndNeverClaimsATitlebarStrip() throws {
        AppThemePalette.set(try makeTakeoverTheme())
        let controller = makeMainWindowController()
        self.controller = controller
        let window = try window(of: controller)

        XCTAssertTrue(window.canBecomeKey)
        XCTAssertTrue(window.canBecomeMain)

        let nearTop = NSPoint(x: window.frame.width / 2, y: window.frame.height - 1)
        XCTAssertFalse(window.isInTitlebarStrip(nearTop),
                       "a frameless window has no strip; the band owns the double-click")
    }

    // MARK: - Covering Surfaces

    /// A surface that covers the window — the media inspector, an expanded comparison — must not
    /// cover the way out of it.
    ///
    /// In native dress the content is drawn full-size and the traffic lights float over its top,
    /// so a surface pinned to `contentView.topAnchor` opens beneath them: that shipped, and the
    /// inspector's title sat under the three buttons. In a takeover the chrome is the app's own
    /// title and command bands, so the surface starts under both and stays inside the drawn
    /// frame. One installed surface is asserted across the
    /// exchange, because the area is stated as constraints and has to follow a live theme flip.
    func testACoveringSurfaceClearsTheWindowsChromeInBothDresses() throws {
        AppThemePalette.set(.system)
        let controller = makeMainWindowController()
        self.controller = controller
        let window = try window(of: controller)
        let coordinator = try XCTUnwrap(controller.chromeCoordinator)
        let root = try XCTUnwrap(window.contentView)
        let host = try XCTUnwrap(window.contentViewController as? WindowChromeHostViewController)

        let probe = NSView()
        let presentation = try XCTUnwrap(
            InWindowOverlay.install(probe, in: window, onDismiss: {})
        )
        root.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(root.safeAreaInsets.top, 0,
                             "a full-size content view has a titlebar strip to clear")
        XCTAssertEqual(probe.frame.maxY, root.bounds.maxY - root.safeAreaInsets.top, accuracy: 1,
                       "the surface opened under the traffic lights")
        XCTAssertEqual(probe.frame.minX, 0, accuracy: 1, "native dress draws no frame to inset")

        // The wash reaches further than the surface, on purpose: in native dress the window's own
        // buttons are AppKit's, above the content view entirely, so the strip the surface has to
        // clear is app-drawn chrome that must dim with everything else.
        XCTAssertEqual(presentation.scrim.frame, root.bounds,
                       "the strip above the surface stayed lit")

        AppThemePalette.set(try makeTakeoverTheme())
        coordinator.applyCurrentTheme()
        root.layoutSubtreeIfNeeded()

        let bandFrame = host.view.convert(host.bandView.bounds, from: host.bandView)
        let commandBandFrame = host.view.convert(
            host.commandBandView.bounds,
            from: host.commandBandView
        )
        XCTAssertGreaterThan(bandFrame.height, 0, "the takeover band has no height")
        XCTAssertGreaterThan(commandBandFrame.height, 0,
                             "the takeover command band has no height")
        XCTAssertEqual(probe.frame.maxY, commandBandFrame.minY, accuracy: 1,
                       "the surface covered the app-drawn window chrome")
        XCTAssertGreaterThan(probe.frame.minX, 0, "the surface covered the theme's own frame")

        // In a takeover the band *is* this window's titlebar, so the wash stops under it: dimming
        // the way out of the window is allowed, swallowing the click that takes it is not.
        XCTAssertEqual(presentation.scrim.frame.maxY, bandFrame.minY, accuracy: 1,
                       "the wash covered the takeover window's own close, minimize and zoom")
        XCTAssertEqual(presentation.scrim.frame.minY, probe.frame.minY, accuracy: 1,
                       "the wash and the surface disagree about the bottom of the window")
    }
}

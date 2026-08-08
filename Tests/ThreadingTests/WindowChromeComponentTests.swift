import AppKit
import XCTest
@testable import Threading

/// The app-drawn window chrome as components: the band that carries a takeover window's title
/// and gestures, the three buttons that are its working parts, and the host that collapses all
/// of it to nothing in native dress.
@MainActor
final class WindowChromeComponentTests: XCTestCase {
    /// Render fixtures run hosted in the shipping app's defaults domain. A developer's chosen
    /// chrome font must not silently change historical conformance pixels, but running the
    /// suite must not erase that preference either.
    private var preservedChromeFontFamily: String?

    private enum Render {
        static var directory: URL {
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"] {
                return URL(fileURLWithPath: override)
            }
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
        }
    }

    /// Period-shaped content for the menu fixture. The menu itself must display caller-owned
    /// colour artwork without template tinting, just as Win32 displayed each shell item's
    /// 16px bitmap. This is a pixel reconstruction, not an extraction from the source image.
    private func win98FolderIcon(hasUpdateBadge: Bool = false) -> NSImage {
        // A drawing-handler image is resolution independent. That normally helps, but here it
        // let AppKit resample one-device-pixel rectangles through the test host's 2x backing
        // scale before the archive captured at 1x, creating half-colour edge pixels that never
        // existed in the source bitmap. Own the 16x16 sample grid explicitly instead.
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 16,
            pixelsHigh: 16,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: .alphaNonpremultiplied,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        bitmap.size = NSSize(width: 16, height: 16)
        func pixel(_ color: NSColor, _ x: Int, _ y: Int, _ w: Int, _ h: Int) {
            let resolved = color.usingColorSpace(.deviceRGB) ?? color
            let rgba = [
                resolved.redComponent,
                resolved.greenComponent,
                resolved.blueComponent,
                resolved.alphaComponent,
            ].map { UInt8(($0 * 255).rounded()) }
            for row in y..<(y + h) {
                for column in x..<(x + w) {
                    // `NSImage.draw` seats this bitmap in the row's unflipped drawing context;
                    // its first bitmap row therefore becomes the visual top of the captured
                    // image. Keep the reconstruction in the source crop's top-down order.
                    let address = bitmap.bitmapData!
                        + row * bitmap.bytesPerRow
                        + column * 4
                    for channel in 0..<4 { address[channel] = rgba[channel] }
                }
            }
        }

        let outline = NSColor.black
        let dark = NSColor(srgbRed: 159 / 255, green: 159 / 255, blue: 0, alpha: 1)
        let gold = NSColor(srgbRed: 207 / 255, green: 207 / 255, blue: 96 / 255, alpha: 1)
        let light = NSColor(srgbRed: 1, green: 1, blue: 207 / 255, alpha: 1)
        let face = NSColor(srgbRed: 1, green: 1, blue: 159 / 255, alpha: 1)
        let warm = NSColor(srgbRed: 1, green: 207 / 255, blue: 159 / 255, alpha: 1)

        // Tab, back wall, open lip, and the one-pixel black containment/shadow.
        pixel(dark, 3, 3, 5, 1)
        pixel(outline, 8, 3, 1, 1)
        pixel(dark, 2, 4, 1, 1)
        pixel(NSColor(white: 240 / 255, alpha: 1), 3, 4, 1, 1)
        pixel(light, 4, 4, 2, 1)
        pixel(face, 6, 4, 2, 1)
        pixel(dark, 8, 4, 1, 1)
        pixel(outline, 9, 4, 1, 1)
        pixel(dark, 1, 5, 14, 1)
        pixel(gold, 2, 5, 7, 1)
        pixel(dark, 1, 6, 1, 8)
        pixel(outline, 15, 6, 1, 9)
        pixel(dark, 1, 14, 14, 1)
        pixel(outline, 2, 15, 14, 1)
        pixel(face, 1, 6, 14, 8)
        pixel(light, 2, 6, 12, 1)
        pixel(warm, 11, 7, 3, 6)
        // The native bitmap's alternating warm pixels keep the face from reading as a modern
        // flat yellow tile at 1x.
        for y in stride(from: 8, through: 12, by: 2) {
            for x in stride(from: 3 + (y % 4), through: 11, by: 4) {
                pixel(warm, x, y, 1, 1)
            }
        }

        if hasUpdateBadge {
            // The Software Updates item carries a tiny document/network mark inside the same
            // shell-folder bitmap rather than switching to a monochrome app symbol.
            pixel(.white, 6, 7, 4, 5)
            pixel(NSColor(srgbRed: 0, green: 0, blue: 128 / 255, alpha: 1), 5, 8, 2, 2)
            pixel(.black, 9, 7, 1, 2)
            pixel(.black, 8, 11, 3, 1)
            pixel(NSColor(srgbRed: 0, green: 128 / 255, blue: 128 / 255, alpha: 1), 7, 9, 2, 2)
        }
        let image = NSImage(size: NSSize(width: 16, height: 16))
        image.addRepresentation(bitmap)
        image.isTemplate = false
        return image
    }

    override func setUp() {
        super.setUp()
        preservedChromeFontFamily = UserDefaults.standard.string(forKey: "chromeFontFamily")
        UserDefaults.standard.removeObject(forKey: "chromeFontFamily")
    }

    override func tearDown() {
        AppThemePalette.set(.system)
        if let preservedChromeFontFamily {
            UserDefaults.standard.set(preservedChromeFontFamily, forKey: "chromeFontFamily")
        } else {
            UserDefaults.standard.removeObject(forKey: "chromeFontFamily")
        }
        super.tearDown()
    }

    // MARK: - Fixtures

    private func fixtureStyle(
        glyphs: WindowChromeStyle.TitleBar.ButtonGlyphStyle = .squares
    ) -> WindowChromeAppearance.Resolved {
        WindowChromeAppearance.resolved(from: fixtureChrome(glyphs: glyphs))
    }

    private func fixtureChrome(
        glyphs: WindowChromeStyle.TitleBar.ButtonGlyphStyle = .squares
    ) -> WindowChromeStyle {
        WindowChromeStyle(
            titleBar: .init(
                activeGradient: .init(stops: [
                    .init(color: NSColor(hex: "#000080")!, position: 0),
                    .init(color: NSColor(hex: "#1084D0")!, position: 1)
                ], angleDegrees: 90),
                ink: .white,
                buttonGlyphStyle: glyphs
            ),
            frame: .init(width: 4)
        )
    }

    /// Records the operations instead of running them. A real `zoom()` on a frameless,
    /// unshown fixture window spawns AppKit's `_NSWindowTransformAnimation`, which outlives
    /// the window a test drops moments later and segfaults in whichever later test pumps the
    /// run loop — found as a crash in `ToastTests`, two suites away. The contract under test
    /// is "the control asks its window", and this window answers exactly that question.
    private final class OperationRecordingWindow: NSWindow {
        var zoomCount = 0
        var miniaturizeCount = 0
        var orderBackCount = 0

        override var canBecomeKey: Bool { true }
        override func zoom(_ sender: Any?) { zoomCount += 1 }
        override func miniaturize(_ sender: Any?) { miniaturizeCount += 1 }
        override func orderBack(_ sender: Any?) { orderBackCount += 1 }
    }

    private func makeWindow() -> OperationRecordingWindow {
        let window = OperationRecordingWindow(
            contentRect: NSRect(x: 80, y: 80, width: 480, height: 320),
            styleMask: WindowChromeCoordinator.takeoverMask,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSView()
        return window
    }

    private func press(_ button: WindowChromeButton) {
        _ = button.performPrimaryAction()
    }

    /// The chrome a takeover theme wears, whichever variant states it — validation holds a
    /// theme to chrome-in-both-or-neither, so any variant answers for all of them.
    private func takeoverChrome(of theme: AppTheme) -> WindowChromeStyle? {
        theme.variant(.light)?.chrome ?? theme.variants.values.compactMap(\.chrome).first
    }

    /// Renders a view against an explicit appearance — an offscreen `cacheDisplay` under no
    /// appearance at all draws blank. A component that opted out of autoresizing must be
    /// pinned with constraints: assigning `frame` to such a view survives only until the
    /// layout pass, which solved an unconstrained band to zero size — so the first version
    /// of this helper rendered a band's buttons floating on transparency and compared two
    /// backgrounds that were never drawn.
    private func renderedPixels(of view: NSView, size: NSSize) throws -> Data {
        let host = NSView(frame: NSRect(origin: .zero, size: size))
        host.appearance = NSAppearance(named: .aqua)
        host.addSubview(view)
        if view.translatesAutoresizingMaskIntoConstraints {
            view.frame = host.bounds
        } else {
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                view.topAnchor.constraint(equalTo: host.topAnchor),
                view.bottomAnchor.constraint(equalTo: host.bottomAnchor)
            ])
        }
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        view.removeFromSuperview()
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    /// `bitmapImageRepForCachingDisplay` inherits the host screen's Retina scale. Historical
    /// evidence is recorded in source pixels, so a conformance fixture needs an explicit 1×
    /// backing store or a nominal 20pt scroller silently becomes a 40px image.
    private func pngAtOneX(of view: NSView) throws -> Data {
        let bounds = view.bounds.integral
        let width = max(1, Int(bounds.width))
        let height = max(1, Int(bounds.height))
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        rep.size = bounds.size
        view.cacheDisplay(in: bounds, to: rep)
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    /// NSScroller's offscreen cache may retain only its last invalidated legacy part. That is
    /// normally an efficient AppKit implementation detail, but it made a 637px horizontal
    /// evidence fixture contain only its final arrow even after the entire view was marked
    /// dirty. Draw the production component's complete pass into the same explicit 1× store.
    private func pngAtOneX(of scroller: ThemedScroller) throws -> Data {
        let bounds = scroller.bounds.integral
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: max(1, Int(bounds.width)),
            pixelsHigh: max(1, Int(bounds.height)),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        rep.size = bounds.size
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        scroller.draw(bounds)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    // MARK: - Button State

    func testTheZoomButtonAsksItsWindowToZoom() {
        let window = makeWindow()
        let button = WindowChromeButton(role: .zoom)
        window.contentView?.addSubview(button)

        press(button)

        XCTAssertEqual(window.zoomCount, 1, "the zoom button performs the window's own zoom")
    }

    func testTheZoomButtonBecomesRestoreForAZoomedWindow() {
        let button = WindowChromeButton(role: .zoom)
        button.fixtureIsZoomed = true

        XCTAssertTrue(button.displaysRestore)
        XCTAssertEqual(button.accessibilityLabel(), L10n.string("Restore"))

        button.fixtureIsZoomed = false
        XCTAssertFalse(button.displaysRestore)
        XCTAssertEqual(button.accessibilityLabel(), L10n.string("Zoom"))
    }

    func testWindows98UsesTheClassicCaptionMetrics() throws {
        let style = WindowChromeAppearance.resolved(
            from: try XCTUnwrap(AppThemeStyles.win98.variant(.light)?.chrome)
        )
        let button = WindowChromeButton(role: .close)
        button.fixtureStyle = style

        XCTAssertEqual(style.bandHeight, 18)
        XCTAssertEqual(button.intrinsicContentSize, NSSize(width: 16, height: 14))
    }

    func testWindows98CaptionArtworkKeepsTheMarlettWeightAndScale() {
        typealias Artwork = WindowChromeCaptionArtwork

        // Marlett's `0` is a six-pixel sill left-biased inside an eight-pixel cell. Carrying the
        // cell rather than trimming to the ink is what keeps the sill under the same left edge as
        // the odd-width Maximize figure beside it; trimmed, the painter had to re-centre it by
        // hand and the two marks drifted apart.
        let minimize = Artwork.windows98(.minimize, restored: false)
        XCTAssertEqual(
            minimize.rowsTopToBottom,
            ["######..", "######.."],
            "the Minimize sill is no longer a 6×2 mark in an 8-wide cell"
        )
        XCTAssertEqual(
            minimize.canvasHeight,
            9,
            "Minimize must stay on the floor of the shared Marlett caption cell"
        )
        XCTAssertEqual(
            Artwork.windows98(.zoom, restored: false).rowsTopToBottom,
            [
                "#########",
                "#########",
                "#.......#",
                "#.......#",
                "#.......#",
                "#.......#",
                "#.......#",
                "#.......#",
                "#########"
            ],
            "Maximize lost its nine-pixel window or two-pixel title rail"
        )
        // Two-pixel stair steps meeting in a four-pixel waist — Marlett's `r`, which crosses on
        // an odd row rather than between two even ones. The eight-row figure the earlier
        // reconstruction used had a two-row waist and read a weight lighter than the source.
        XCTAssertEqual(
            Artwork.windows98(.close, restored: false).rowsTopToBottom,
            [
                "##....##",
                ".##..##.",
                "..####..",
                "...##...",
                "..####..",
                ".##..##.",
                "##....##"
            ],
            "Close returned to the thin one-pixel diagonal the reference disproves"
        )

        // Marlett is strictly one-bit; the multi-ink legend cells belong to Intuition alone.
        for role in [
            WindowChromeButton.Role.windowMenu, .close, .minimize, .zoom, .depth
        ] {
            for restored in [false, true] {
                let bitmap = Artwork.windows98(role, restored: restored)
                XCTAssertTrue(
                    bitmap.rowsTopToBottom.allSatisfy { row in
                        row.allSatisfy { $0 == "#" || $0 == "." }
                    },
                    "\(role) contains a non-binary source pixel"
                )
            }
        }
    }

    /// Every family's alphabet, held to the shared legend — the assertion the four
    /// `dot()`/`frame()` painters could never carry, because their figures existed only as
    /// arithmetic. A family is swept by having artwork, so a new one cannot land ragged.
    func testEveryCaptionAlphabetIsWellFormedOneBitArtwork() {
        typealias Artwork = WindowChromeCaptionArtwork
        let families: [(String, (WindowChromeButton.Role, Bool) -> Artwork.Bitmap)] = [
            ("windows98", Artwork.windows98),
            ("platinum", Artwork.platinum),
            ("beos", Artwork.beOS),
            ("openstep", Artwork.openStep),
            ("irix", Artwork.irix),
            ("amiga", Artwork.amiga),
            ("tui", Artwork.tui)
        ]
        let legend = Set("#o+.")
        for (family, artwork) in families {
            for role in [
                WindowChromeButton.Role.windowMenu, .close, .minimize, .zoom, .depth
            ] {
                for restored in [false, true] {
                    let bitmap = artwork(role, restored)
                    XCTAssertGreaterThan(bitmap.width, 0, "\(family) \(role) is empty")
                    XCTAssertTrue(
                        bitmap.rowsTopToBottom.allSatisfy { $0.count == bitmap.width },
                        "\(family) \(role) has a ragged source bitmap"
                    )
                    XCTAssertGreaterThanOrEqual(
                        bitmap.canvasHeight, bitmap.rowsTopToBottom.count,
                        "\(family) \(role) overflows the canvas it centres in"
                    )
                    XCTAssertTrue(
                        bitmap.rowsTopToBottom.allSatisfy { row in
                            row.allSatisfy(legend.contains)
                        },
                        "\(family) \(role) uses a pixel outside the shared legend"
                    )
                    XCTAssertTrue(
                        bitmap.rowsTopToBottom.contains { row in
                            row.contains(where: { $0 != "." })
                        },
                        "\(family) \(role) draws nothing at all"
                    )
                }
            }
        }
    }

    func testTheMinimizeButtonAsksItsWindowToMiniaturize() {
        let window = makeWindow()
        let button = WindowChromeButton(role: .minimize)
        window.contentView?.addSubview(button)

        press(button)

        XCTAssertEqual(window.miniaturizeCount, 1)
    }

    func testTheDepthButtonSendsItsWindowBehindItsPeers() {
        let window = makeWindow()
        let button = WindowChromeButton(role: .depth)
        window.contentView?.addSubview(button)

        press(button)

        XCTAssertEqual(window.orderBackCount, 1)
        XCTAssertEqual(button.accessibilityLabel(), L10n.string("Send to Back"))
    }

    /// Asserted through a refusing delegate rather than a real close: closing a key-capable
    /// window queues AppKit's terminate-after-last-window-closed decision against the test
    /// host, which then exits inside whichever later test pumps the run loop (the CLAUDE.md
    /// trap). The button's contract is exactly "ask `windowShouldClose`, honour the answer" —
    /// so the refusal *is* the assertion.
    func testTheCloseButtonAsksTheDelegateAndHonoursARefusal() {
        final class Doorman: NSObject, NSWindowDelegate {
            var asked = false
            func windowShouldClose(_ sender: NSWindow) -> Bool {
                asked = true
                return false
            }
        }

        let window = makeWindow()
        let doorman = Doorman()
        window.delegate = doorman
        defer { window.delegate = nil }
        let button = WindowChromeButton(role: .close)
        window.contentView?.addSubview(button)

        var closed = false
        let token = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: nil
        ) { _ in closed = true }
        defer { NotificationCenter.default.removeObserver(token) }

        press(button)

        XCTAssertTrue(doorman.asked, "the close button asks the window's own delegate")
        XCTAssertFalse(closed, "a refused close must not close")
    }

    func testADisabledButtonRefusesActivation() {
        let window = makeWindow()
        let button = WindowChromeButton(role: .zoom)
        window.contentView?.addSubview(button)
        button.isEnabled = false

        XCTAssertFalse(button.performPrimaryAction())
        XCTAssertEqual(window.zoomCount, 0)
    }

    // MARK: - Accessibility

    func testAccessibilityContract() {
        let window = makeWindow()
        let button = WindowChromeButton(role: .zoom)
        window.contentView?.addSubview(button)

        XCTAssertEqual(button.accessibilityRole(), .button)
        XCTAssertEqual(button.accessibilityLabel(), L10n.string("Zoom"))
        XCTAssertTrue(button.isAccessibilityElement())

        XCTAssertTrue(button.accessibilityPerformPress())
        XCTAssertEqual(window.zoomCount, 1, "the accessibility press is the real press")
    }

    // MARK: - Band Behaviour

    /// Pushed, not observed: the window controller's `updateWindowTitle` calls the host's
    /// `setTitle` beside setting `window.title`, so the two never disagree — and the band
    /// holds no observation that would unregister against a deallocating window.
    func testTheBandShowsThePushedTitle() {
        let band = WindowTitleBandView()

        band.setTitle("Threading — retro")

        XCTAssertEqual(band.displayedTitle, "Threading — retro")
    }

    func testPlatinumSplitsItsWindowBoxesAndDropsTheApplicationIcon() throws {
        let band = WindowTitleBandView()
        let style = WindowChromeAppearance.resolved(
            from: try XCTUnwrap(AppThemeStyles.platinum.variant(.light)?.chrome)
        )
        band.fixtureStyle = style

        XCTAssertEqual(band.leadingWindowButtonRoles, [.close])
        XCTAssertEqual(band.trailingWindowButtonRoles, [.zoom])
        XCTAssertFalse(band.showsApplicationIcon)
        XCTAssertEqual(style.bandHeight, 17, "the measured Platinum caption band")
        XCTAssertEqual(band.closeButton.intrinsicContentSize, NSSize(width: 14, height: 14))
    }

    func testPlatinumOpenBitmapFallbackKeepsClassicMenuAdvances() {
        XCTAssertEqual(PlatinumBitmapFont.advance(of: "About Help"), 70)
        XCTAssertEqual(PlatinumBitmapFont.advance(of: "Show Balloons"), 94)
        XCTAssertEqual(PlatinumBitmapFont.advance(of: "Help        ⌘?"), 96)
        XCTAssertNil(
            PlatinumBitmapFont.advance(of: "日本語"),
            "unsupported Unicode must retain the ordinary AppKit/user-font path"
        )
    }

    func testBeOSUsesARealLeadingTitleTabAndOnlyItsTwoWindowBoxes() throws {
        let band = WindowTitleBandView()
        band.frame = NSRect(x: 0, y: 0, width: 480, height: 22)
        let style = WindowChromeAppearance.resolved(
            from: try XCTUnwrap(AppThemeStyles.beOS.variant(.light)?.chrome)
        )
        band.fixtureStyle = style
        band.layoutSubtreeIfNeeded()

        XCTAssertEqual(band.leadingWindowButtonRoles, [.close])
        XCTAssertEqual(band.trailingWindowButtonRoles, [.zoom])
        XCTAssertFalse(band.showsApplicationIcon)
        XCTAssertEqual(style.bandHeight, 19, "the measured BeOS R5 tab height")
        XCTAssertEqual(band.closeButton.intrinsicContentSize, NSSize(width: 16, height: 14))
        XCTAssertEqual(band.occupiedTitleWidth, 120, accuracy: 0.5)
        XCTAssertLessThan(band.occupiedTitleWidth, band.bounds.width,
                          "BeOS needs a title tab, not a yellow full-width title bar")
    }

    func testOpenStepUsesTheSingleTrailingClosePlateFromNativePanels() throws {
        let band = WindowTitleBandView()
        let style = WindowChromeAppearance.resolved(
            from: try XCTUnwrap(AppThemeStyles.openStep.variant(.light)?.chrome)
        )
        band.fixtureStyle = style

        XCTAssertEqual(band.leadingWindowButtonRoles, [])
        XCTAssertEqual(band.trailingWindowButtonRoles, [.close])
        XCTAssertFalse(band.showsApplicationIcon)
        XCTAssertEqual(style.bandHeight, 23)
    }

    func testIRIXBookendsTheWindowMenuAndItsTwoRightCaptionBoxes() throws {
        let band = WindowTitleBandView()
        let style = WindowChromeAppearance.resolved(
            from: try XCTUnwrap(AppThemeStyles.irix.variant(.light)?.chrome)
        )
        band.fixtureStyle = style

        XCTAssertEqual(band.leadingWindowButtonRoles, [.windowMenu])
        XCTAssertEqual(band.trailingWindowButtonRoles, [.minimize, .zoom])
        XCTAssertFalse(band.showsApplicationIcon)
        XCTAssertEqual(style.frameWidth, 4)
        XCTAssertEqual(style.bandHeight, 32)
        XCTAssertEqual(band.menuButton.intrinsicContentSize, NSSize(width: 24, height: 22))
    }

    func testTUIBookendsTheWindowMenuAndItsThreeOperations() throws {
        XCTAssertNoThrow(
            try AppThemeEditing.validate(AppThemeStyles.tui),
            "TUI must satisfy the same public contract as an agent-authored theme"
        )
        let band = WindowTitleBandView()
        let style = WindowChromeAppearance.resolved(
            from: try XCTUnwrap(AppThemeStyles.tui.variant(.dark)?.chrome)
        )
        band.fixtureStyle = style

        XCTAssertEqual(band.leadingWindowButtonRoles, [.windowMenu])
        XCTAssertEqual(band.trailingWindowButtonRoles, [.minimize, .zoom, .close])
        XCTAssertFalse(band.showsApplicationIcon)
        XCTAssertEqual(style.bandHeight, 26)
        XCTAssertEqual(style.ink.hexString, "#5FBFA8")
        XCTAssertEqual(band.menuButton.intrinsicContentSize, NSSize(width: 15, height: 15))
    }

    func testAmigaSplitsCloseFromZoomAndTheRealDepthGadget() throws {
        let band = WindowTitleBandView()
        let style = WindowChromeAppearance.resolved(
            from: try XCTUnwrap(AppThemeStyles.amiga.variant(.light)?.chrome)
        )
        band.fixtureStyle = style

        XCTAssertEqual(band.leadingWindowButtonRoles, [.close])
        XCTAssertEqual(band.trailingWindowButtonRoles, [.zoom, .depth])
        XCTAssertFalse(band.showsApplicationIcon)
        XCTAssertEqual(style.bandHeight, 18)
        XCTAssertEqual(band.closeButton.intrinsicContentSize, NSSize(width: 18, height: 16))
    }

    func testAmigaCaptionRasterStaysOneBitAgainstTheBlueBand() throws {
        AppThemePalette.set(AppThemeStyles.amiga)
        defer { AppThemePalette.set(.system) }

        let style = WindowChromeAppearance.resolved(
            from: try XCTUnwrap(AppThemeStyles.amiga.variant(.light)?.chrome)
        )
        let band = WindowTitleBandView()
        band.translatesAutoresizingMaskIntoConstraints = true
        band.frame = NSRect(x: 0, y: 0, width: 420, height: style.bandHeight)
        band.fixtureStyle = style
        band.fixtureIsKey = true
        band.setTitle("hd02  50% full, 2,047M free, 2,048M in use")
        band.layoutSubtreeIfNeeded()

        let data = try pngAtOneX(of: band)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: data))
        var colours = Set<String>()
        var offenders: [(x: Int, y: Int, colour: String)] = []
        // Exclude the leading and trailing gadget plates; the title field itself may contain
        // only the band blue and the one-bit Topaz ink after hard-raster caption drawing.
        // Keep the title field itself in the sample; the cache's first/last rows are the
        // window edge and may carry the host's compositing colour rather than caption ink.
        for y in 2..<max(2, rep.pixelsHigh - 2) {
            for x in 26..<min(rep.pixelsWide - 40, 376) {
                guard let colour = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
                    continue
                }
                colours.insert(colour.hexString)
                if colour.hexString != "#000000", offenders.count < 12 {
                    offenders.append((x: x, y: y, colour: colour.hexString))
                }
            }
        }

        let bandColours = colours.subtracting(["#000000"])
        XCTAssertEqual(
            bandColours.count,
            1,
            "Topaz caption introduced antialiased colours: \(colours.sorted()); samples: \(offenders)"
        )
    }

    func testWindowMenuRoleBuildsTheWindowOperationsMenu() throws {
        let window = makeWindow()
        let button = WindowChromeButton(role: .windowMenu)
        window.contentView?.addSubview(button)
        var presented: ThemedMenuPresentation?
        button.fixtureMenuPresentation = { presented = $0 }

        XCTAssertTrue(button.performPrimaryAction())
        let menu = try XCTUnwrap(presented)

        XCTAssertEqual(
            menu.entries.compactMap { entry in
                guard case .item(let item) = entry else { return nil }
                return item.title
            },
            ["Restore", "Minimize", "Maximize", "Close"]
        )
        XCTAssertEqual(button.accessibilityLabel(), L10n.string("Window menu"))
    }

    func testABandDoubleClickPerformsTheChosenAction() throws {
        let window = makeWindow()
        let band = WindowTitleBandView()
        band.frame = NSRect(x: 0, y: 292, width: 480, height: 28)
        window.contentView?.addSubview(band)
        band.doubleClickAction = { .zoom }

        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 240, y: 306),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 2,
            pressure: 1
        ))
        band.mouseDown(with: event)

        XCTAssertEqual(window.zoomCount, 1, "a band double-click performs the zoom")
    }

    // MARK: - Catalogue Sweeps

    /// Win98 was the only family whose caption metrics were asserted; the other seven were
    /// review-by-eye. These sweeps run over the model's own takeover list and the anatomy
    /// table, so a new family or theme is held to every rule by existing.

    func testEveryTakeoverFamilySeatsItsCaptionSlotInsideItsAuthoredBand() throws {
        for theme in AppThemeStyles.takeovers {
            let chrome = try XCTUnwrap(takeoverChrome(of: theme), theme.name)
            let style = WindowChromeAppearance.resolved(from: chrome)
            let button = WindowChromeButton(role: .close)
            button.fixtureStyle = style
            XCTAssertLessThanOrEqual(
                button.intrinsicContentSize.height,
                style.bandHeight,
                "\(theme.name)'s caption slot is taller than its own title band"
            )
        }
    }

    func testCheetahHoverGlyphFollowsTheMeasuredGlassCentre() {
        let anatomy = WindowChromeCaptionAnatomy.of(.aqua)

        XCTAssertTrue(anatomy.glyphsRequireHover)
        XCTAssertEqual(anatomy.glyphOpticalOffset, NSPoint(x: 0.5, y: 0))
        XCTAssertEqual(
            WindowChromeCaptionAnatomy.of(.aquaTiger).glyphOpticalOffset,
            .zero,
            "Tiger owns a separate, centred gel recipe"
        )
    }

    /// A band says "not me" by dimming — how a window has said it since windows could
    /// overlap. Every takeover theme's band must actually change pixels on resign, not
    /// merely intend to.
    func testEveryTakeoverBandChangesItsPixelsWhenItsWindowResignsKey() throws {
        for theme in AppThemeStyles.takeovers {
            AppThemePalette.set(theme)
            let chrome = try XCTUnwrap(takeoverChrome(of: theme), theme.name)
            let style = WindowChromeAppearance.resolved(from: chrome)
            let band = WindowTitleBandView()
            band.fixtureStyle = style
            band.setTitle("Threading")
            let size = NSSize(width: 320, height: style.bandHeight)

            band.fixtureIsKey = true
            let active = try renderedPixels(of: band, size: size)
            band.fixtureIsKey = false
            let inactive = try renderedPixels(of: band, size: size)

            XCTAssertNotEqual(
                active, inactive,
                "\(theme.name)'s band draws identically whether or not its window is key"
            )
        }
    }

    /// A family whose plates are cut from the band must dim them with it — BeOS's tab boxes
    /// and Intuition's gadgets go Workbench-gray with their title strips. The anatomy table
    /// states which families claim this; the sweep holds every claimant to it.
    func testEveryBandCutPlateDimsWithItsWindow() throws {
        for theme in AppThemeStyles.takeovers {
            AppThemePalette.set(theme)
            let chrome = try XCTUnwrap(takeoverChrome(of: theme), theme.name)
            let style = WindowChromeAppearance.resolved(from: chrome)
            guard WindowChromeCaptionAnatomy.of(style.glyphStyle).plateFollowsKeyState else {
                continue
            }
            let button = WindowChromeButton(role: .close)
            button.fixtureStyle = style
            let size = button.intrinsicContentSize

            button.fixtureIsKey = true
            let active = try renderedPixels(of: button, size: size)
            button.fixtureIsKey = false
            let inactive = try renderedPixels(of: button, size: size)

            XCTAssertNotEqual(
                active, inactive,
                "\(theme.name)'s band-cut caption plate does not dim with its window"
            )
        }
    }

    /// A pixel family's pressed face carries its figure with it — one physical-button rule
    /// for every family that states a pressed offset, previously asserted for none of them.
    func testEveryPixelFamilyMovesItsFigureWithThePressedFace() throws {
        for theme in AppThemeStyles.takeovers {
            AppThemePalette.set(theme)
            let chrome = try XCTUnwrap(takeoverChrome(of: theme), theme.name)
            let style = WindowChromeAppearance.resolved(from: chrome)
            guard WindowChromeCaptionAnatomy.of(style.glyphStyle).pressedGlyphOffset != .zero
            else { continue }
            let button = WindowChromeButton(role: .close)
            button.fixtureStyle = style
            button.fixtureIsKey = true
            let size = button.intrinsicContentSize

            let resting = try renderedPixels(of: button, size: size)
            button.mouseDown(with: NSEvent())
            let pressed = try renderedPixels(of: button, size: size)

            XCTAssertNotEqual(
                resting, pressed,
                "\(theme.name)'s pressed caption face leaves its figure behind"
            )
        }
    }

    // MARK: - Text Mode

    /// The `rule` texture is the whole silhouette of a text-mode header: without it the band
    /// is an unbounded field of the same colour as the panes under it, and the theme has no
    /// frame at all. Asserted on pixels rather than on the resolved style, because "the theme
    /// states a rule" and "the band draws one, on the bottom edge" are different claims and
    /// only the second one is the feature.
    func testTheTextModeBandClosesItselfWithASeamOnItsBottomEdge() throws {
        AppThemePalette.set(AppThemeStyles.tui)
        defer { AppThemePalette.set(.system) }
        let chrome = try XCTUnwrap(takeoverChrome(of: AppThemeStyles.tui))
        let style = WindowChromeAppearance.resolved(from: chrome)
        let seam = try XCTUnwrap(style.activeTexture?.color.usingColorSpace(.sRGB))
        let ground = try XCTUnwrap(style.activeGradient.colors.first?.usingColorSpace(.sRGB))

        let band = WindowTitleBandView()
        band.fixtureStyle = style
        band.fixtureIsKey = true
        band.setTitle("Threading")
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try renderedPixels(
            of: band,
            size: NSSize(width: 240, height: style.bandHeight)
        )))

        // Sampled at half width, the one column clear of both the leading title and the
        // trailing operation cells: the seam is the only thing drawn across the whole band,
        // and a quarter width put the middle sample inside the word "Threading".
        let x = rep.pixelsWide / 2
        let bottom = try XCTUnwrap(rep.colorAt(x: x, y: rep.pixelsHigh - 1))
        let middle = try XCTUnwrap(rep.colorAt(x: x, y: rep.pixelsHigh / 2))

        assertSameInk(bottom, seam, "the text-mode band's bottom row is not its stated seam")
        assertSameInk(
            middle, ground,
            "the seam bled into the band instead of closing its edge"
        )
    }

    /// An inverted cell is how a terminal has said "you are here" since it was the only thing
    /// it could do, and it is the one plate whose *figure* colour the plate decides rather
    /// than `glyphInk` — so the pointer has to actually swap the two, not merely tint them.
    func testTheTextModeCaptionCellInvertsUnderThePointer() throws {
        AppThemePalette.set(AppThemeStyles.tui)
        defer { AppThemePalette.set(.system) }
        let chrome = try XCTUnwrap(takeoverChrome(of: AppThemeStyles.tui))
        let style = WindowChromeAppearance.resolved(from: chrome)

        let button = WindowChromeButton(role: .close)
        button.fixtureStyle = style
        button.fixtureIsKey = true
        let size = button.intrinsicContentSize

        let resting = try renderedPixels(of: button, size: size)
        button.mouseEntered(with: NSEvent())
        let hovered = try renderedPixels(of: button, size: size)

        XCTAssertTrue(button.isHovered, "the fixture lost its hover before it was drawn")
        XCTAssertNotEqual(resting, hovered, "the caption cell ignores the pointer")

        // The corner is clear of the seven-column figure in the middle of the slot, so it
        // carries the plate alone: the band's ink once the cell is inverted.
        let rep = try XCTUnwrap(NSBitmapImageRep(data: hovered))
        let corner = try XCTUnwrap(rep.colorAt(x: 0, y: 0))
        assertSameInk(corner, style.ink, "the inverted cell is not filled with the band's ink")
    }

    func testTheTextModePressedCellSeatsFullInkInsideItsHoverFace() throws {
        AppThemePalette.set(AppThemeStyles.tui)
        defer { AppThemePalette.set(.system) }
        let chrome = try XCTUnwrap(takeoverChrome(of: AppThemeStyles.tui))
        let style = WindowChromeAppearance.resolved(from: chrome)

        let button = WindowChromeButton(role: .close)
        button.fixtureStyle = style
        button.fixtureIsKey = true
        button.mouseDown(with: NSEvent())
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try renderedPixels(
            of: button,
            size: button.intrinsicContentSize
        )))

        let backingScale = max(
            1,
            Int(round(CGFloat(rep.pixelsWide) / button.intrinsicContentSize.width))
        )
        let mechanicalEdge = try XCTUnwrap(rep.colorAt(x: 0, y: 0))
        let keyedFace = try XCTUnwrap(rep.colorAt(x: backingScale, y: backingScale))
        XCTAssertEqual(
            mechanicalEdge.alphaComponent, 0, accuracy: 1 / 255,
            "the pressed cell did not leave its one-point edge clear for the band ground"
        )
        assertSameInk(
            keyedFace, style.ink,
            "the pressed face faded instead of keeping the band's full ink"
        )
    }

    /// A rendered pixel comes back in the backing store's own colour space, which is the
    /// display's rather than the theme's — so a sampled colour and an authored one agree in
    /// what they *are* while disagreeing in the last component value. Compare after
    /// converting both, and leave a channel of room for the round trip.
    private func assertSameInk(
        _ sampled: NSColor,
        _ expected: NSColor,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let sampled = sampled.usingColorSpace(.sRGB),
              let expected = expected.usingColorSpace(.sRGB) else {
            return XCTFail("\(message): a colour would not convert to sRGB", file: file, line: line)
        }
        for (name, pair) in [
            ("red", (sampled.redComponent, expected.redComponent)),
            ("green", (sampled.greenComponent, expected.greenComponent)),
            ("blue", (sampled.blueComponent, expected.blueComponent))
        ] {
            XCTAssertEqual(
                pair.0, pair.1, accuracy: 2 / 255,
                "\(message) (\(name))",
                file: file,
                line: line
            )
        }
    }

    // MARK: - Gallery

    func testGalleryTellsTheirStories() {
        for name in [
            "WindowTitleBandView", "WindowChromeButton", "WindowCommandBandView",
            "WindowChromeFrameView"
        ] {
            XCTAssertTrue(
                ComponentGalleryViewController.componentNames.contains(name),
                "A design-system component without a gallery story is invisible to review"
            )
        }
    }

    // MARK: - Host

    /// In native dress the chrome host must be geometrically invisible: the band hidden at
    /// zero height, the command band hidden too, no frame inset, the workspace filling the root exactly.
    func testTheHostCollapsesToNothingInNativeDress() {
        let workspace = NSViewController()
        workspace.view = NSView()
        let host = WindowChromeHostViewController(workspace: workspace)
        host.view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        host.view.layoutSubtreeIfNeeded()

        XCTAssertTrue(host.bandView.isHidden)
        XCTAssertEqual(host.bandView.frame.height, 0)
        XCTAssertTrue(host.commandBandView.isHidden)
        XCTAssertEqual(host.commandBandView.frame.height, 0)
        XCTAssertEqual(workspace.view.frame, host.view.bounds)
    }

    func testTheHostDressesForTakeoverAndUndressesAgain() throws {
        let takeover = try AppThemeEditing.assemble(
            id: AppThemeID("custom-window-chrome-component-tests"),
            name: "Component Fixture",
            mode: AppThemeStyles.cyberpunk.availableVariants[0] == .dark ? .dark : .light,
            summary: nil,
            variants: [
                AppThemeStyles.cyberpunk.availableVariants[0]: AppThemeEditing.makeVariant(
                    named: "Component Fixture",
                    from: AppThemeStyles.cyberpunk,
                    kind: AppThemeStyles.cyberpunk.availableVariants[0],
                    chrome: .set(fixtureChrome())
                )
            ]
        )
        AppThemePalette.set(takeover)

        let workspace = NSViewController()
        workspace.view = NSView()
        let host = WindowChromeHostViewController(workspace: workspace)
        host.view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        host.setTakeoverActive(true)
        host.view.layoutSubtreeIfNeeded()

        XCTAssertFalse(host.bandView.isHidden)
        XCTAssertFalse(host.commandBandView.isHidden)
        XCTAssertEqual(
            host.bandView.frame.height,
            WindowChromeStyleLimits.defaultBandHeight
        )
        XCTAssertEqual(host.commandBandView.frame.height, WindowCommandBandView.bandHeight)
        XCTAssertEqual(workspace.view.frame.maxY, host.commandBandView.frame.minY)
        XCTAssertEqual(workspace.view.frame.minX, 4, "the frame's width insets the workspace")
        XCTAssertEqual(
            host.view.bounds.maxY - host.bandView.frame.maxY,
            4,
            "the frame's width seats the band below the top edge"
        )

        host.setTakeoverActive(false)
        host.view.layoutSubtreeIfNeeded()
        XCTAssertTrue(host.bandView.isHidden)
        XCTAssertTrue(host.commandBandView.isHidden)
        XCTAssertEqual(workspace.view.frame, host.view.bounds)
    }

    // MARK: - Renders

    /// System plus two deliberately different themes, light and dark: the band with its
    /// square-plate buttons over its own gradient, active and inactive, plus the bare-glyph
    /// style. Balance and legibility are judged by looking, the render-suite rule.
    func testRendersUnderSystemAndTwoStyledThemes() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Every takeover theme joins the usual pair because their material reaches these
        // components: Windows has square plates, Platinum split inset boxes, and BeOS a tab.
        // The list is the model's own (`AppThemeStyles.takeovers`), so a new takeover theme
        // is rendered here by existing — this sweep once named six of the eight by hand.
        let themes = [AppTheme.system, AppThemeStyles.cyberpunk, AppThemeStyles.swissMinimalist]
            + AppThemeStyles.takeovers

        var written = 0
        for theme in themes {
            AppThemePalette.set(theme)
            for (suffix, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
                var data: Data?
                appearance.performAsCurrentDrawingAppearance {
                    data = strip(appearance: appearance, theme: theme)
                }
                let url = directory.appendingPathComponent(
                    "window-chrome-\(theme.id.rawValue)-\(suffix).png"
                )
                try XCTUnwrap(data, "Failed to render \(theme.name) \(suffix)").write(to: url)
                written += 1
            }
        }
        print("Rendered \(written) window-chrome strips to \(directory.path)")
        XCTAssertEqual(written, themes.count * 2)
    }

    /// Native-sized, source-shaped caption comparisons where the archive has measured pixels.
    /// These render the production title band and its real button cluster in the same state,
    /// bounds, and scale as the linked excerpt. A second broad state-catalogue is still useful
    /// for development, but it is not allowed to masquerade as the historical reconstruction.
    ///
    /// Workbench remains a broad component fixture: its current evidence is a halftoned manual
    /// figure rather than native pixels, so stretching a 1× production band to that print crop
    /// would create a false exactness.
    func testRendersEveryRetroCaptionGlyphFamily() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { AppThemePalette.set(.system) }

        let exactFixtures: [(theme: AppTheme, size: NSSize, title: String)] = [
            (AppThemeStyles.win98, NSSize(width: 50, height: 14), ""),
            (AppThemeStyles.platinum, NSSize(width: 470, height: 17), "Appearance"),
            (AppThemeStyles.beOS, NSSize(width: 111, height: 19), "Charts"),
            (AppThemeStyles.openStep, NSSize(width: 380, height: 23), "Info"),
            (
                AppThemeStyles.irix,
                NSSize(width: 690, height: 32),
                "IRIS Showcase 3.3 : No file name (Page 1 of 1)"
            ),
            (AppThemeStyles.aqua, NSSize(width: 64, height: 20), ""),
            (AppThemeStyles.aquaTiger, NSSize(width: 61, height: 23), "")
        ]

        var written = 0
        for fixture in exactFixtures {
            AppThemePalette.set(fixture.theme)
            let chrome = try XCTUnwrap(takeoverChrome(of: fixture.theme))
            let style = WindowChromeAppearance.resolved(from: chrome)
            let band = WindowTitleBandView()
            band.translatesAutoresizingMaskIntoConstraints = true
            let rendersButtonsOnly = fixture.theme.id == AppThemeStyles.win98.id
            let bandSize = rendersButtonsOnly
                ? NSSize(width: 481, height: 18)
                : fixture.size
            band.frame = NSRect(origin: .zero, size: bandSize)
            band.fixtureStyle = style
            // The archived Windows crop comes from the gray Scheduled Tasks caption, while
            // the other linked excerpts show their active form.
            band.fixtureIsKey = fixture.theme.id == AppThemeStyles.win98.id ? false : true
            band.setTitle(fixture.title)
            band.layoutSubtreeIfNeeded()
            band.needsDisplay = true
            let renderView: NSView
            if rendersButtonsOnly {
                // The tight historical Win98 excerpt is the 50×14 operation cluster. Give
                // the production band the source window's measured 481×18 caption geometry,
                // then clip the trailing hardware; this preserves both the native gradient
                // sample in the two-pixel group gap and the real trailing inset.
                let clip = NSView(frame: NSRect(origin: .zero, size: fixture.size))
                band.frame.origin.x = fixture.size.width - bandSize.width
                    + Design.Spacing.tight
                clip.addSubview(band)
                clip.layoutSubtreeIfNeeded()
                renderView = clip
            } else {
                renderView = band
            }
            let png = try pngAtOneX(of: renderView)
            let url = directory.appendingPathComponent(
                "caption-glyphs-\(fixture.theme.id.rawValue).png"
            )
            try png.write(to: url)
            print("Rendered source-shaped \(fixture.theme.name) caption band to \(url.path)")
            written += 1
        }

        AppThemePalette.set(AppThemeStyles.amiga)
        XCTAssertEqual(
            Design.Typography.controlRegular().familyName,
            "Topaz a600a1200a400",
            "the app bundle did not register its GPL-FE Workbench 2.x/3.1 face"
        )
        let amigaChrome = try XCTUnwrap(takeoverChrome(of: AppThemeStyles.amiga))
        let amigaStyle = WindowChromeAppearance.resolved(from: amigaChrome)
        let amigaPNG = try XCTUnwrap(captionGlyphStrip(style: amigaStyle))
        let amigaURL = directory.appendingPathComponent(
            "caption-glyphs-\(AppThemeStyles.amiga.id.rawValue).png"
        )
        try amigaPNG.write(to: amigaURL)
        print("Rendered Workbench caption state catalogue to \(amigaURL.path)")
        written += 1

        // The component catalogue above isolates gadget states; this companion keeps the
        // production title label in frame so the bundled Topaz face, regular weight, split
        // placement, and active strip are reviewable together against Commodore's Figure 3-3.
        let amigaBand = WindowTitleBandView()
        amigaBand.translatesAutoresizingMaskIntoConstraints = true
        amigaBand.frame = NSRect(x: 0, y: 0, width: 420, height: amigaStyle.bandHeight)
        amigaBand.fixtureStyle = amigaStyle
        amigaBand.fixtureIsKey = true
        amigaBand.setTitle("hd02  50% full, 2,047M free, 2,048M in use")
        amigaBand.layoutSubtreeIfNeeded()
        amigaBand.needsDisplay = true
        let amigaBandPNG = try pngAtOneX(of: amigaBand)
        let amigaBandURL = directory.appendingPathComponent(
            "title-band-\(AppThemeStyles.amiga.id.rawValue).png"
        )
        try amigaBandPNG.write(to: amigaBandURL)
        print("Rendered source-shaped Workbench title band to \(amigaBandURL.path)")

        // TUI is authored rather than reconstructed, so there is no source crop to shape its
        // render and it would be dishonest to give it one: its archive entry records every
        // component as `not_applicable`. What it still owes the sweep is a picture, so it
        // gets the state catalogue — resting, hovered, pressed — which is where an inverted
        // caption cell is actually reviewable, plus its band at the theme's own measures.
        AppThemePalette.set(AppThemeStyles.tui)
        let tuiChrome = try XCTUnwrap(takeoverChrome(of: AppThemeStyles.tui))
        let tuiStyle = WindowChromeAppearance.resolved(from: tuiChrome)
        let tuiPNG = try XCTUnwrap(captionGlyphStrip(style: tuiStyle))
        let tuiURL = directory.appendingPathComponent(
            "caption-glyphs-\(AppThemeStyles.tui.id.rawValue).png"
        )
        try tuiPNG.write(to: tuiURL)
        print("Rendered text-mode caption state catalogue to \(tuiURL.path)")
        written += 1

        let tuiBand = WindowTitleBandView()
        tuiBand.translatesAutoresizingMaskIntoConstraints = true
        tuiBand.frame = NSRect(x: 0, y: 0, width: 420, height: tuiStyle.bandHeight)
        tuiBand.fixtureStyle = tuiStyle
        tuiBand.fixtureIsKey = true
        tuiBand.setTitle("Threading")
        tuiBand.layoutSubtreeIfNeeded()
        tuiBand.needsDisplay = true
        let tuiBandURL = directory.appendingPathComponent(
            "title-band-\(AppThemeStyles.tui.id.rawValue).png"
        )
        try pngAtOneX(of: tuiBand).write(to: tuiBandURL)
        print("Rendered the text-mode title band to \(tuiBandURL.path)")

        // Classic Player is also a clean-room design rather than a reconstruction. Imported
        // Winamp skin sprites have their own importer/resolution tests; this fixture keeps the
        // stock fallback's pixel controls and stretched title groove visually reviewable.
        AppThemePalette.set(AppThemeStyles.classicPlayer)
        let classicChrome = try XCTUnwrap(takeoverChrome(of: AppThemeStyles.classicPlayer))
        let classicStyle = WindowChromeAppearance.resolved(from: classicChrome)
        let classicPNG = try XCTUnwrap(captionGlyphStrip(style: classicStyle))
        let classicURL = directory.appendingPathComponent(
            "caption-glyphs-\(AppThemeStyles.classicPlayer.id.rawValue).png"
        )
        try classicPNG.write(to: classicURL)
        print("Rendered Classic Player caption state catalogue to \(classicURL.path)")
        written += 1

        let classicBand = WindowTitleBandView()
        classicBand.translatesAutoresizingMaskIntoConstraints = true
        classicBand.frame = NSRect(x: 0, y: 0, width: 420, height: classicStyle.bandHeight)
        classicBand.fixtureStyle = classicStyle
        classicBand.fixtureIsKey = true
        classicBand.setTitle("Threading")
        classicBand.layoutSubtreeIfNeeded()
        classicBand.needsDisplay = true
        let classicBandURL = directory.appendingPathComponent(
            "title-band-\(AppThemeStyles.classicPlayer.id.rawValue).png"
        )
        try pngAtOneX(of: classicBand).write(to: classicBandURL)
        print("Rendered the Classic Player title band to \(classicBandURL.path)")

        XCTAssertEqual(written, AppThemeStyles.takeovers.count)
    }

    /// The whole takeover window as one picture: the real `MainWindowController` dressed by
    /// the stock takeover themes, drawn unshown. In takeover the app draws every pixel of
    /// the frame, so the content render *is* the window — the one picture that shows band,
    /// buttons, frame, bevels and panes as one thing, which no per-component strip can.
    func testRendersTheWholeTakeoverWindow() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { AppThemePalette.set(.system) }

        // The native half first, as the comparison's "before". Its traffic lights and
        // toolbar are AppKit's own chrome outside the content, so this is the workspace
        // alone — the takeover half is the one where the content *is* the whole window.
        for (theme, name) in [(AppTheme.system, "window-chrome-native-window")]
            + AppThemeStyles.takeovers.map({ ($0, "window-chrome-\($0.id.rawValue)-window") }) {
            AppThemePalette.set(theme)
            let controller = MainWindowController()
            let window = try XCTUnwrap(controller.window)
            window.setContentSize(NSSize(width: 1_100, height: 700))
            let content = try XCTUnwrap(window.contentView)
            content.layoutSubtreeIfNeeded()

            // The hero form: an unshown window is never key. Make every key-sensitive
            // surface tell the same truth, so the active band is not pictured above an
            // inexplicably inactive selection.
            applyKeyFixtureState(in: content)

            let rep = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: rep)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            let url = directory.appendingPathComponent("\(name).png")
            try png.write(to: url)
            print("Rendered \(name) to \(url.path)")
        }
    }

    func testRendersOpenStepLeadingStippledScroller() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        AppThemePalette.set(AppThemeStyles.openStep)

        let scroll = ThemedScrollView(frame: NSRect(x: 0, y: 0, width: 180, height: 280))
        scroll.surfaceRole = .sidebarNavigator
        scroll.scrollerStyle = .legacy
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = false

        let document = NSView(frame: NSRect(x: 0, y: 0, width: 160, height: 760))
        document.wantsLayer = true
        document.layer?.backgroundColor = Design.Surface.elevated.cgColor
        for index in 0..<18 {
            let label = NSTextField(labelWithString: index.isMultiple(of: 3)
                ? "Workspace \(index / 3 + 1)"
                : "  Session \(index + 1)")
            label.font = Design.Typography.body()
            label.textColor = Design.Text.label
            label.frame = NSRect(x: 12, y: 720 - CGFloat(index * 36), width: 132, height: 20)
            document.addSubview(label)
        }
        scroll.documentView = document
        scroll.layoutSubtreeIfNeeded()
        let scroller = try XCTUnwrap(scroll.verticalScroller)
        scroller.isEnabled = true
        scroller.doubleValue = 0.28
        scroller.knobProportion = 0.30

        let rep = try XCTUnwrap(scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds))
        scroll.cacheDisplay(in: scroll.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let url = directory.appendingPathComponent("openstep-leading-scroller.png")
        try png.write(to: url)
        print("Rendered OPENSTEP scroller to \(url.path)")
    }

    /// Reference-shaped 1× fixtures for every native-scale crop. These deliberately reproduce
    /// the source axis, pixel dimensions, thumb proportion, and approximate scroll position;
    /// what remains different in the archive is therefore the component drawing itself.
    ///
    /// OPENSTEP and Amiga currently have broader adjacency/scaled-window evidence rather than
    /// a tight native scroller crop. Their existing two-axis family fixtures remain explicit
    /// review aids until the archive records tighter source pixels.
    func testRendersEveryRetroScrollbarFamily() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { AppThemePalette.set(.system) }

        let exactFixtures: [(
            theme: AppTheme,
            output: String,
            canvasSize: NSSize,
            scrollerFrame: NSRect,
            value: Double,
            proportion: CGFloat
        )] = [
            (AppThemeStyles.win98, "reference-scrollbar-vertical-retro-98.png",
             NSSize(width: 16, height: 150), NSRect(x: 0, y: 0, width: 16, height: 150),
             0.00, 0.01),
            (AppThemeStyles.win98, "reference-scrollbar-horizontal-retro-98.png",
             NSSize(width: 453, height: 16), NSRect(x: 0, y: 0, width: 453, height: 16),
             0.00, 0.76),
            (AppThemeStyles.platinum, "reference-scrollbar-platinum-9.png",
             NSSize(width: 14, height: 184), NSRect(x: 0, y: 0, width: 14, height: 184),
             0.00, 37.0 / 154.0),
            (AppThemeStyles.aqua, "reference-scrollbar-aqua-cheetah.png",
             NSSize(width: 633, height: 16), NSRect(x: 0, y: 0, width: 633, height: 16),
             1.00, 0.665),
            (AppThemeStyles.aquaTiger, "reference-scrollbar-aqua-tiger.png",
             NSSize(width: 15, height: 479), NSRect(x: 0, y: 0, width: 15, height: 479),
             0.435, 0.862),
            (AppThemeStyles.beOS, "reference-scrollbar-beos-r5.png",
             NSSize(width: 12, height: 200), NSRect(x: 0, y: 0, width: 12, height: 200),
             0.00, 0.08),
            (AppThemeStyles.irix, "reference-scrollbar-irix-indigo-magic.png",
             NSSize(width: 16, height: 172), NSRect(x: 0, y: 0, width: 16, height: 172),
             0.95, 0.31),
            (AppThemeStyles.openStep, "retro-scrollbars-openstep-42.png",
             NSSize(width: 18, height: 244), NSRect(x: 0, y: 0, width: 18, height: 244),
             0.00, 163.0 / 210.0)
        ]

        for fixture in exactFixtures {
            AppThemePalette.set(fixture.theme)
            let canvas = NSView(frame: NSRect(origin: .zero, size: fixture.canvasSize))
            canvas.wantsLayer = true
            canvas.layer?.backgroundColor = Design.Surface.ground.cgColor
            let scroller = ThemedScroller(frame: .zero)
            scroller.scrollerStyle = .legacy
            // Setting legacy presentation asks AppKit to snap an NSScroller back to its
            // preferred system thickness. The evidence dimensions are authoritative here, so
            // apply the measured frame *after* that policy change rather than silently losing
            // several pixels of the control before it is captured.
            scroller.frame = fixture.scrollerFrame
            canvas.addSubview(scroller)
            canvas.layoutSubtreeIfNeeded()
            // NSScroller recalculates its usable-parts policy when it joins a hierarchy. Set
            // source state afterwards: doing this before `addSubview` silently cleared the
            // very long horizontal Cheetah thumb while the vertical fixtures happened to
            // survive, producing an apparently empty reconstruction.
            scroller.isEnabled = true
            scroller.doubleValue = fixture.value
            scroller.knobProportion = fixture.proportion
            // NSScroller invalidates individual legacy parts as these properties change.
            // Offscreen caching honours that dirty region; without a final whole-control
            // invalidation the long Cheetah fixture captured only its trailing arrow and made
            // a correct drawing routine look blank in the archive.
            scroller.needsDisplay = true
            XCTAssertEqual(
                scroller.knobProportion,
                fixture.proportion,
                accuracy: 0.001,
                "fixture state must survive AppKit hierarchy attachment"
            )
            if fixture.proportion > 0 {
                XCTAssertFalse(scroller.rect(for: .knob).isEmpty)
            }
            let png = try pngAtOneX(of: scroller)
            let url = directory.appendingPathComponent(fixture.output)
            try png.write(to: url)
            print("Rendered reference-shaped \(fixture.theme.name) scroller to \(url.path)")
        }

        for theme in [AppThemeStyles.amiga] {
            AppThemePalette.set(theme)
            let scroll = ThemedScrollView(frame: NSRect(x: 0, y: 0, width: 210, height: 280))
            scroll.hasVerticalScroller = true
            scroll.hasHorizontalScroller = true
            scroll.autohidesScrollers = false

            let document = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 840))
            document.wantsLayer = true
            document.layer?.backgroundColor = Design.Surface.elevated.cgColor
            for index in 0..<20 {
                let label = NSTextField(labelWithString: "Reference row \(index + 1)")
                label.font = Design.Typography.body()
                label.textColor = Design.Text.label
                label.frame = NSRect(x: 16, y: 800 - CGFloat(index * 38), width: 168, height: 20)
                document.addSubview(label)
            }
            scroll.documentView = document
            scroll.layoutSubtreeIfNeeded()
            scroll.verticalScroller?.isEnabled = true
            scroll.verticalScroller?.doubleValue = 0.34
            scroll.verticalScroller?.knobProportion = 0.24
            scroll.horizontalScroller?.isEnabled = true
            scroll.horizontalScroller?.doubleValue = 0.42
            scroll.horizontalScroller?.knobProportion = 0.31

            let rep = try XCTUnwrap(scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds))
            scroll.cacheDisplay(in: scroll.bounds, to: rep)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            let url = directory.appendingPathComponent(
                "retro-scrollbars-\(theme.id.rawValue).png"
            )
            try png.write(to: url)
            print("Rendered \(theme.name) scrollbars to \(url.path)")
        }
    }

    /// Source-shaped menu panels rendered by the production in-window menu implementation.
    /// Each historical family joins here only after the archive owns a tight comparison crop;
    /// a broad desktop or manual figure remains supporting context rather than being stretched
    /// into a false side-by-side comparison.
    func testRendersEveryRetroMenuFamily() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { AppThemePalette.set(.system) }

        AppThemePalette.set(AppThemeStyles.platinum)
        let entries: [ThemedMenuEntry] = [
            .item(ThemedMenuItem(title: "About Help")),
            .separator,
            .item(ThemedMenuItem(title: "Show Balloons")),
            .separator,
            .item(ThemedMenuItem(title: "Help", keyEquivalent: "?")),
        ]
        let menu = ThemedMenuReferenceFixture.make(
            entries: entries,
            size: NSSize(width: 123, height: 63)
        )
        let png = try pngAtOneX(of: menu)
        let url = directory.appendingPathComponent("reference-menu-platinum-9.png")
        try png.write(to: url)
        print("Rendered source-shaped Platinum menu to \(url.path)")

        AppThemePalette.set(AppThemeStyles.win98)
        XCTAssertTrue(
            ["MS Sans Serif", "Microsoft Sans Serif", "W95FA"].contains(
                Design.Typography.controlRegular().familyName
            ),
            "the app bundle did not register its OFL Windows UI fallback"
        )
        let child = [ThemedMenuEntry.item(ThemedMenuItem(title: "Child"))]
        let win98Entries: [ThemedMenuEntry] = [
            .item(ThemedMenuItem(
                title: "Channels",
                image: win98FolderIcon(),
                submenu: child
            )),
            .item(ThemedMenuItem(
                title: "Links",
                image: win98FolderIcon(),
                submenu: child
            )),
            .item(ThemedMenuItem(
                title: "Software Updates",
                image: win98FolderIcon(hasUpdateBadge: true),
                submenu: child
            )),
        ]
        let win98Menu = ThemedMenuReferenceFixture.makeCascade(
            entries: win98Entries,
            size: NSSize(width: 130, height: 67),
            highlightedEntryIndex: 0,
            childEntries: [
                .item(ThemedMenuItem(title: "Microsoft Channel Guide")),
            ],
            childSize: NSSize(width: 147, height: 27),
            childOriginFromTopLeft: NSPoint(
                x: 130 - ThemedMenuLayout.submenuOverlap,
                y: 0
            ),
            childHighlightedEntryIndex: 0
        )
        let win98PNG = try pngAtOneX(of: win98Menu)
        let win98URL = directory.appendingPathComponent("reference-menu-retro-98.png")
        try win98PNG.write(to: win98URL)
        print("Rendered source-shaped Windows 98 submenu to \(win98URL.path)")

        AppThemePalette.set(AppThemeStyles.amiga)
        let workbenchEntries: [ThemedMenuEntry] = [
            .item(ThemedMenuItem(title: "Backdrop", keyEquivalent: "B")),
            .item(ThemedMenuItem(title: "Execute Command...", keyEquivalent: "E")),
            .item(ThemedMenuItem(title: "Redraw All")),
            .item(ThemedMenuItem(title: "Update All")),
            .item(ThemedMenuItem(title: "Last Message")),
            .item(ThemedMenuItem(title: "About...", keyEquivalent: "?")),
            .item(ThemedMenuItem(title: "Quit...", keyEquivalent: "Q")),
        ]
        let workbenchMenu = ThemedMenuReferenceFixture.make(
            entries: workbenchEntries,
            size: NSSize(width: 176, height: 130)
        )
        let workbenchPNG = try pngAtOneX(of: workbenchMenu)
        let workbenchURL = directory.appendingPathComponent("reference-menu-amiga-workbench-31.png")
        try workbenchPNG.write(to: workbenchURL)
        print("Rendered source-shaped Workbench menu to \(workbenchURL.path)")
    }

    /// Source-shaped action rows rendered through the production button. The first member is
    /// disabled, the second is the dialog default, and the third is ordinary: all three states
    /// present in the preserved Windows 98 wizard crop, at its exact 239×28 pixel composition.
    func testRendersEveryRetroButtonFamily() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { AppThemePalette.set(.system) }

        AppThemePalette.set(AppThemeStyles.win98)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 239, height: 28))
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor(hex: "#C0C0C0")?.cgColor

        let back = ThemedButton(title: "< Back", target: nil, action: nil)
        back.mnemonicCharacter = "B"
        back.isEnabled = false
        back.frame = NSRect(x: 3, y: 3, width: 75, height: 23)

        let next = ThemedButton(title: "Next >", target: nil, action: nil)
        next.mnemonicCharacter = "N"
        next.isProminent = true
        next.frame = NSRect(x: 78, y: 3, width: 75, height: 23)

        let cancel = ThemedButton(title: "Cancel", target: nil, action: nil)
        cancel.frame = NSRect(x: 163, y: 3, width: 75, height: 23)

        host.addSubview(back)
        host.addSubview(next)
        host.addSubview(cancel)
        let png = try pngAtOneX(of: host)
        let url = directory.appendingPathComponent("reference-buttons-retro-98.png")
        try png.write(to: url)
        print("Rendered source-shaped Windows 98 action row to \(url.path)")

        AppThemePalette.set(AppThemeStyles.amiga)
        let workbenchHost = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        workbenchHost.wantsLayer = true
        workbenchHost.layer?.backgroundColor = Design.Surface.ground.cgColor
        let workbenchButtons = [
            ("OK", NSRect(x: 0, y: 1, width: 68, height: 22)),
            ("Volumes", NSRect(x: 72, y: 1, width: 88, height: 22)),
            ("Parent", NSRect(x: 164, y: 1, width: 88, height: 22)),
            ("Cancel", NSRect(x: 256, y: 1, width: 104, height: 22)),
        ]
        for (title, frame) in workbenchButtons {
            let button = ThemedButton(title: title, target: nil, action: nil)
            button.frame = frame
            workbenchHost.addSubview(button)
        }
        let workbenchButtonsPNG = try pngAtOneX(of: workbenchHost)
        let workbenchButtonsURL = directory.appendingPathComponent(
            "reference-buttons-amiga-workbench-31.png"
        )
        try workbenchButtonsPNG.write(to: workbenchButtonsURL)
        print("Rendered source-shaped Workbench buttons to \(workbenchButtonsURL.path)")
    }

    func testRendersEveryRetroRequesterControlFamily() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { AppThemePalette.set(.system) }

        AppThemePalette.set(AppThemeStyles.amiga)
        let checkboxHost = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 88))
        checkboxHost.wantsLayer = true
        checkboxHost.layer?.backgroundColor = Design.Surface.ground.cgColor
        let checkboxStates: [(String, NSControl.StateValue, Bool)] = [
            ("Put Trashcan:", .on, true),
            ("Fast File System:", .off, true),
            ("International Mode:", .off, true),
            ("Directory Cache:", .off, false),
        ]
        for (index, fixture) in checkboxStates.enumerated() {
            let y = 66 - CGFloat(index * 21)
            let label = NSTextField(labelWithString: fixture.0)
            label.alignment = .right
            label.font = Design.Typography.controlRegular()
            label.textColor = fixture.2 ? Design.Text.label : Design.Text.tertiary
            label.frame = NSRect(x: 6, y: y, width: 190, height: 20)
            checkboxHost.addSubview(label)
            let checkbox = ThemedCheckbox(
                title: "",
                state: fixture.1,
                accessibility: fixture.0,
                changed: { _ in }
            )
            checkbox.isEnabled = fixture.2
            checkbox.frame = NSRect(
                x: 202,
                y: y,
                width: 20,
                height: 20
            )
            checkboxHost.addSubview(checkbox)
        }
        let checkboxPNG = try pngAtOneX(of: checkboxHost)
        let checkboxURL = directory.appendingPathComponent(
            "reference-checkboxes-amiga-workbench-31.png"
        )
        try checkboxPNG.write(to: checkboxURL)
        print("Rendered source-shaped Workbench checkboxes to \(checkboxURL.path)")

        let fieldHost = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 54))
        fieldHost.wantsLayer = true
        fieldHost.layer?.backgroundColor = Design.Surface.ground.cgColor
        let prompt = NSTextField(labelWithString: "Enter a new name for 'EMPTY':")
        prompt.font = Design.Typography.body()
        prompt.textColor = Design.Text.label
        prompt.frame = NSRect(x: 6, y: 31, width: 308, height: 18)
        fieldHost.addSubview(prompt)
        let field = ThemedTextField(string: "EMPTY")
        field.frame = NSRect(x: 72, y: 4, width: 242, height: 24)
        fieldHost.addSubview(field)
        let fieldPNG = try pngAtOneX(of: fieldHost)
        let fieldURL = directory.appendingPathComponent(
            "reference-field-amiga-workbench-31.png"
        )
        try fieldPNG.write(to: fieldURL)
        print("Rendered source-shaped Workbench field to \(fieldURL.path)")

        AppThemePalette.set(AppThemeStyles.win98)
        let win98FieldHost = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 70))
        win98FieldHost.wantsLayer = true
        win98FieldHost.layer?.backgroundColor = Design.Surface.ground.cgColor
        let win98FieldStates: [(String, String, Bool)] = [
            ("Enabled", "C:\\WINDOWS", true),
            ("Disabled", "C:\\WINDOWS", false),
        ]
        for (index, fixture) in win98FieldStates.enumerated() {
            let label = NSTextField(labelWithString: fixture.0)
            label.font = Design.Typography.controlRegular()
            label.textColor = fixture.2 ? Design.Text.label : Design.Text.tertiary
            label.frame = NSRect(x: 6, y: 38 - CGFloat(index * 30), width: 56, height: 18)
            win98FieldHost.addSubview(label)

            let field = ThemedTextField(string: fixture.1)
            field.isEnabled = fixture.2
            field.frame = NSRect(x: 68, y: 34 - CGFloat(index * 30), width: 174, height: 26)
            win98FieldHost.addSubview(field)
        }
        let win98FieldPNG = try pngAtOneX(of: win98FieldHost)
        let win98FieldURL = directory.appendingPathComponent("reference-fields-retro-98.png")
        try win98FieldPNG.write(to: win98FieldURL)
        print("Rendered source-backed Win98 fields to \(win98FieldURL.path)")

        let win98RadioHost = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 70))
        win98RadioHost.wantsLayer = true
        win98RadioHost.layer?.backgroundColor = Design.Surface.ground.cgColor
        let win98RadioStates: [(String, NSControl.StateValue, Bool)] = [
            ("Standard", .on, true),
            ("Large fonts", .off, true),
            ("Unavailable", .on, false),
        ]
        for (index, fixture) in win98RadioStates.enumerated() {
            let radio = ThemedRadioButton(
                title: fixture.0,
                state: fixture.1,
                changed: { _ in }
            )
            radio.isEnabled = fixture.2
            radio.frame = NSRect(x: 4, y: 42 - CGFloat(index * 21), width: 200, height: 20)
            win98RadioHost.addSubview(radio)
        }
        let win98RadioPNG = try pngAtOneX(of: win98RadioHost)
        let win98RadioURL = directory.appendingPathComponent("reference-radios-retro-98.png")
        try win98RadioPNG.write(to: win98RadioURL)
        print("Rendered source-backed Win98 radios to \(win98RadioURL.path)")

        AppThemePalette.set(AppThemeStyles.beOS)
        let beOSHost = NSView(frame: NSRect(x: 0, y: 0, width: 150, height: 66))
        beOSHost.wantsLayer = true
        beOSHost.layer?.backgroundColor = Design.Surface.ground.cgColor
        let beOSStates: [(String, NSControl.StateValue, Bool)] = [
            ("Enabled", .on, true),
            ("Empty", .off, true),
            ("Icon labels", .on, false),
        ]
        for (index, fixture) in beOSStates.enumerated() {
            let checkbox = ThemedCheckbox(
                title: fixture.0,
                state: fixture.1,
                changed: { _ in }
            )
            checkbox.isEnabled = fixture.2
            checkbox.frame = NSRect(x: 2, y: 44 - CGFloat(index * 21), width: 146, height: 20)
            beOSHost.addSubview(checkbox)
        }
        let beOSPNG = try pngAtOneX(of: beOSHost)
        let beOSURL = directory.appendingPathComponent("reference-checkboxes-beos-r5.png")
        try beOSPNG.write(to: beOSURL)
        print("Rendered source-backed BeOS checkboxes to \(beOSURL.path)")

        AppThemePalette.set(AppThemeStyles.win98)
        let win98Host = NSView(frame: NSRect(x: 0, y: 0, width: 170, height: 66))
        win98Host.wantsLayer = true
        win98Host.layer?.backgroundColor = Design.Surface.ground.cgColor
        let win98States: [(String, NSControl.StateValue, Bool)] = [
            ("Enabled", .on, true),
            ("Disabled empty", .off, false),
            ("Disabled checked", .on, false),
        ]
        for (index, fixture) in win98States.enumerated() {
            let checkbox = ThemedCheckbox(
                title: fixture.0,
                state: fixture.1,
                changed: { _ in }
            )
            checkbox.isEnabled = fixture.2
            checkbox.frame = NSRect(x: 2, y: 44 - CGFloat(index * 21), width: 166, height: 20)
            win98Host.addSubview(checkbox)
        }
        let win98PNG = try pngAtOneX(of: win98Host)
        let win98URL = directory.appendingPathComponent("reference-checkboxes-retro-98.png")
        try win98PNG.write(to: win98URL)
        print("Rendered source-backed Win98 checkboxes to \(win98URL.path)")
    }

    private func applyKeyFixtureState(in view: NSView) {
        (view as? WindowTitleBandView)?.fixtureIsKey = true
        (view as? ThemedTableView)?.fixtureIsKey = true
        (view as? ThemedOutlineView)?.fixtureIsKey = true
        view.subviews.forEach(applyKeyFixtureState)
    }

    private func strip(appearance: NSAppearance, theme: AppTheme) -> Data? {
        let squares = fixtureStyle(glyphs: .squares)
        let band = WindowTitleBandView()
        band.fixtureStyle = squares

        let plain = fixtureStyle(glyphs: .plain)
        let plainButtons = NSStackView(
            views: [WindowChromeButton.Role.minimize, .zoom, .close].map { role in
                let button = WindowChromeButton(role: role)
                button.fixtureStyle = plain
                return button
            }
        )
        plainButtons.orientation = .horizontal
        plainButtons.spacing = Design.Spacing.hairline

        let host = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 76))
        host.appearance = appearance
        band.translatesAutoresizingMaskIntoConstraints = false
        plainButtons.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(band)
        host.addSubview(plainButtons)
        NSLayoutConstraint.activate([
            band.topAnchor.constraint(equalTo: host.topAnchor, constant: Design.Spacing.small),
            band.leadingAnchor.constraint(
                equalTo: host.leadingAnchor, constant: Design.Spacing.small
            ),
            band.widthAnchor.constraint(equalToConstant: 420),
            band.heightAnchor.constraint(equalToConstant: squares.bandHeight),
            plainButtons.topAnchor.constraint(
                equalTo: band.bottomAnchor, constant: Design.Spacing.small
            ),
            plainButtons.leadingAnchor.constraint(equalTo: band.leadingAnchor)
        ])
        host.layoutSubtreeIfNeeded()

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.wantsLayer = true
        host.layer?.backgroundColor = theme.resolved(.ground, appearance: appearance).cgColor
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    private func captionGlyphStrip(style: WindowChromeAppearance.Resolved) -> Data? {
        func button(_ role: WindowChromeButton.Role, restored: Bool = false) -> WindowChromeButton {
            let button = WindowChromeButton(role: role)
            button.fixtureStyle = style
            button.fixtureIsKey = true
            if role == .zoom { button.fixtureIsZoomed = restored }
            return button
        }

        func role(_ stated: WindowChromeStyle.TitleBar.ButtonRole) -> WindowChromeButton.Role {
            switch stated {
            case .windowMenu: return .windowMenu
            case .close: return .close
            case .minimize: return .minimize
            case .zoom: return .zoom
            case .depth: return .depth
            }
        }

        let normal = style.visibleButtons.map { button(role($0)) }
        let restored = style.visibleButtons.contains(.zoom) ? [button(.zoom, restored: true)] : []
        let pressed = style.visibleButtons.map { stated -> WindowChromeButton in
            let result = button(role(stated))
            result.mouseDown(with: NSEvent())
            return result
        }

        func row(_ buttons: [WindowChromeButton]) -> NSStackView {
            let row = NSStackView(views: buttons)
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = Design.Spacing.hairline
            row.translatesAutoresizingMaskIntoConstraints = false
            return row
        }

        let normalRow = row(normal + restored)
        let pressedRow = row(pressed)
        let host = NSView(frame: NSRect(
            x: 0,
            y: 0,
            width: 180,
            height: max(44, style.bandHeight * 2 + 6)
        ))
        host.wantsLayer = true
        host.layer?.backgroundColor = style.activeGradient.colors.first?.cgColor
        host.addSubview(normalRow)
        host.addSubview(pressedRow)
        NSLayoutConstraint.activate([
            normalRow.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 4),
            normalRow.topAnchor.constraint(equalTo: host.topAnchor, constant: 3),
            pressedRow.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 4),
            pressedRow.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -3)
        ])
        host.layoutSubtreeIfNeeded()

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}

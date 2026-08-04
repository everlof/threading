import XCTest
@testable import Threading

/// The compare surface's pure geometry: one shared scale, honest wipe partitions, and the
/// scrub round-trip. The rendered states are covered by `ImageCompareRenderTests`.
final class ImageCompareTests: XCTestCase {

    // MARK: - Shared scale

    func testBothSidesShareOneScaleSoAResizedImageStaysVisiblyResized() {
        let layout = ImageCompareLayout.layout(
            oldSize: CGSize(width: 100, height: 100),
            newSize: CGSize(width: 200, height: 200),
            in: CGRect(x: 0, y: 0, width: 400, height: 200),
            mode: .wipeHorizontal,
            gap: 10
        )

        XCTAssertEqual(layout.scale, 1)
        // The canvas fits the union (200×200), centred in the 400-wide bounds.
        XCTAssertEqual(layout.placement.canvasRect, CGRect(x: 100, y: 0, width: 200, height: 200))
        // The old side is half the linear size of the new, not normalised up to match it.
        XCTAssertEqual(layout.placement.oldRect.size, CGSize(width: 100, height: 100))
        XCTAssertEqual(layout.placement.newRect.size, CGSize(width: 200, height: 200))
        // Both centre on the same point, so a wipe sweeps one aligned composition.
        XCTAssertEqual(layout.placement.oldRect.midX, layout.placement.newRect.midX)
        XCTAssertEqual(layout.placement.oldRect.midY, layout.placement.newRect.midY)
    }

    func testSideBySideGivesEachSideItsOwnCanvasAtOneScale() {
        let layout = ImageCompareLayout.layout(
            oldSize: CGSize(width: 100, height: 100),
            newSize: CGSize(width: 100, height: 100),
            in: CGRect(x: 0, y: 0, width: 410, height: 300),
            mode: .sideBySide,
            gap: 10
        )

        let left = layout.placement.canvasRect
        guard let right = layout.placement.secondaryCanvasRect else {
            return XCTFail("Side by side lays out a second canvas")
        }
        // Halves are 200 wide; the square union fits at 200×200, centred in each half.
        XCTAssertEqual(left.size, CGSize(width: 200, height: 200))
        XCTAssertEqual(right.size, CGSize(width: 200, height: 200))
        XCTAssertEqual(left.midY, right.midY)
        XCTAssertGreaterThanOrEqual(right.minX - left.maxX, 10)
        XCTAssertEqual(layout.placement.oldRect, left)
        XCTAssertEqual(layout.placement.newRect, right)
    }

    func testAMissingSideCollapsesToAZeroRectAtTheSharedCentre() {
        let layout = ImageCompareLayout.layout(
            oldSize: .zero,
            newSize: CGSize(width: 100, height: 50),
            in: CGRect(x: 0, y: 0, width: 200, height: 100),
            mode: .fade,
            gap: 10
        )

        XCTAssertEqual(layout.placement.oldRect.size, .zero)
        XCTAssertEqual(layout.placement.newRect.size, CGSize(width: 200, height: 100))
    }

    func testAZeroBoundsProducesNoNaNs() {
        let layout = ImageCompareLayout.layout(
            oldSize: CGSize(width: 100, height: 100),
            newSize: CGSize(width: 100, height: 100),
            in: .zero,
            mode: .wipeHorizontal,
            gap: 10
        )

        XCTAssertFalse(layout.placement.canvasRect.origin.x.isNaN)
        XCTAssertEqual(layout.placement.canvasRect.size, .zero)
    }

    // MARK: - Captions

    func testTheCaptionBandsAreTakenOffBeforeTheImagesAreFitted() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 200)
        let layout = ImageCompareLayout.layout(
            oldSize: CGSize(width: 200, height: 100),
            newSize: CGSize(width: 200, height: 100),
            in: bounds,
            mode: .wipeHorizontal,
            gap: 10,
            captions: ImageCompareLayout.CaptionBands(top: 20, bottom: 12)
        )

        // The images are fitted into what is left, not into the whole surface.
        let canvas = layout.placement.canvasRect
        XCTAssertGreaterThanOrEqual(canvas.minY, bounds.minY + 20)
        XCTAssertLessThanOrEqual(canvas.maxY, bounds.maxY - 12)
        // And the strips sit flush against the picture rather than at the container's edges,
        // so a letterboxed image is still named by something touching it.
        XCTAssertEqual(layout.captions.top.maxY, canvas.minY)
        XCTAssertEqual(layout.captions.bottom.minY, canvas.maxY)
        XCTAssertEqual(layout.captions.top.width, canvas.width)
    }

    func testTheSideBySideBandSpansBothCanvases() {
        let layout = ImageCompareLayout.layout(
            oldSize: CGSize(width: 100, height: 100),
            newSize: CGSize(width: 100, height: 100),
            in: CGRect(x: 0, y: 0, width: 410, height: 300),
            mode: .sideBySide,
            gap: 10,
            captions: ImageCompareLayout.CaptionBands(top: 20, bottom: 0)
        )

        let left = layout.placement.canvasRect
        guard let right = layout.placement.secondaryCanvasRect else {
            return XCTFail("Side by side lays out a second canvas")
        }
        XCTAssertEqual(layout.captions.top.minX, left.minX)
        XCTAssertEqual(layout.captions.top.maxX, right.maxX)
    }

    @MainActor
    func testNoModeEverPrintsItsCaptionsOverThePixelsBeingCompared() {
        // Sizes that disagree, so the dimension note is in play beside the titles.
        let canvas = ImageCompareCanvas(frame: NSRect(x: 0, y: 0, width: 400, height: 220))
        canvas.old = .init(image: Self.solidImage(.systemRed), title: "baseline.png")
        canvas.new = .init(
            image: Self.solidImage(.systemBlue, size: NSSize(width: 60, height: 30)),
            title: "current.png"
        )

        for mode in ImageCompareMode.allCases {
            canvas.mode = mode
            let layout = canvas.currentLayout
            let pictures = [layout.placement.canvasRect, layout.placement.secondaryCanvasRect]
                .compactMap { $0 }

            XCTAssertGreaterThan(layout.captions.top.height, 0, "\(mode) names neither side")
            XCTAssertGreaterThan(layout.captions.bottom.height, 0, "\(mode) drops the sizes")
            for picture in pictures {
                XCTAssertFalse(layout.captions.top.intersects(picture), "\(mode) caption over image")
                XCTAssertFalse(layout.captions.bottom.intersects(picture), "\(mode) note over image")
            }
        }
    }

    // MARK: - Wipe partition

    func testTheWipePartitionsTheCanvasExactlyAtTheSeam() {
        let canvas = CGRect(x: 50, y: 0, width: 200, height: 100)
        let regions = ImageCompareLayout.wipeRegions(
            in: canvas, mode: .wipeHorizontal, fraction: 0.25
        )

        let seam = ImageCompareLayout.seam(in: canvas, mode: .wipeHorizontal, fraction: 0.25)
        XCTAssertEqual(seam, 100)
        // Old keeps what the seam has not crossed; new takes what it has. Together they are
        // the whole canvas — no sliver drawn twice, none dropped.
        XCTAssertEqual(regions.old.maxX, seam)
        XCTAssertEqual(regions.new.minX, seam)
        XCTAssertEqual(regions.old.union(regions.new), canvas)
    }

    func testTheVerticalWipeSweepsTopToBottom() {
        let canvas = CGRect(x: 0, y: 20, width: 100, height: 200)
        let regions = ImageCompareLayout.wipeRegions(
            in: canvas, mode: .wipeVertical, fraction: 0.5
        )

        // Flipped space: old is the region above the seam.
        XCTAssertEqual(regions.old, CGRect(x: 0, y: 20, width: 100, height: 100))
        XCTAssertEqual(regions.new, CGRect(x: 0, y: 120, width: 100, height: 100))
    }

    func testTheFractionRoundTripsThroughTheSeam() {
        let canvas = CGRect(x: 10, y: 10, width: 300, height: 150)
        for expected in stride(from: CGFloat(0), through: 1, by: 0.1) {
            let seam = ImageCompareLayout.seam(in: canvas, mode: .wipeHorizontal, fraction: expected)
            let recovered = ImageCompareLayout.fraction(
                at: CGPoint(x: seam, y: canvas.midY), in: canvas, mode: .wipeHorizontal
            )
            XCTAssertEqual(recovered, expected, accuracy: 0.0001)
        }
    }

    func testThePointerClampsToTheCanvas() {
        let canvas = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertEqual(
            ImageCompareLayout.fraction(at: CGPoint(x: -50, y: 0), in: canvas, mode: .wipeHorizontal), 0
        )
        XCTAssertEqual(
            ImageCompareLayout.fraction(at: CGPoint(x: 500, y: 0), in: canvas, mode: .wipeHorizontal), 1
        )
    }

    // MARK: - Canvas behaviour

    @MainActor
    func testTheFractionClampsAndAnnouncesItsValue() {
        let canvas = ImageCompareCanvas(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        canvas.fraction = 2
        XCTAssertEqual(canvas.fraction, 1)
        canvas.fraction = -1
        XCTAssertEqual(canvas.fraction, 0)
        canvas.fraction = 0.45
        XCTAssertEqual(canvas.accessibilityValue() as? String, "45%")
    }

    @MainActor
    func testSwitchingModeKeepsTheScrubWhereTheUserLeftIt() {
        let view = ImageCompareView(frame: NSRect(x: 0, y: 0, width: 200, height: 150))
        view.configure(
            old: .init(image: Self.solidImage(.systemRed), title: "old"),
            new: .init(image: Self.solidImage(.systemBlue), title: "new")
        )
        view.fraction = 0.3
        view.mode = .fade
        XCTAssertEqual(view.fraction, 0.3)
        view.mode = .wipeVertical
        XCTAssertEqual(view.fraction, 0.3)
    }

    @MainActor
    func testTheStaticModesRefuseTheScrubberAndFocus() {
        let canvas = ImageCompareCanvas(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        canvas.old = .init(image: Self.solidImage(.systemRed), title: "old")
        canvas.new = .init(image: Self.solidImage(.systemBlue), title: "new")

        canvas.mode = .wipeHorizontal
        XCTAssertTrue(canvas.acceptsFirstResponder)
        XCTAssertTrue(canvas.accessibilityPerformIncrement())

        canvas.mode = .difference
        XCTAssertFalse(canvas.acceptsFirstResponder)
        XCTAssertFalse(canvas.accessibilityPerformIncrement())
        XCTAssertFalse(canvas.accessibilityPerformPress())
    }

    @MainActor
    func testASingleSideIsNotScrubbableAndHidesTheModeChoice() {
        let view = ImageCompareView(frame: NSRect(x: 0, y: 0, width: 200, height: 150))
        view.configure(old: nil, new: .init(image: Self.solidImage(.systemBlue), title: "added"))

        let canvas = view.subviews.compactMap { $0 as? ImageCompareCanvas }.first
        XCTAssertNotNil(canvas)
        XCTAssertFalse(canvas?.acceptsFirstResponder ?? true)
        let chip = view.subviews.compactMap { $0 as? ChipView }.first
        XCTAssertEqual(chip?.isHidden, true)
    }

    @MainActor
    func testAccessibilityAdjustsTheScrubBySteps() {
        let canvas = ImageCompareCanvas(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        canvas.old = .init(image: Self.solidImage(.systemRed), title: "old")
        canvas.new = .init(image: Self.solidImage(.systemBlue), title: "new")
        canvas.fraction = 0.5

        XCTAssertTrue(canvas.accessibilityPerformIncrement())
        XCTAssertEqual(canvas.fraction, 0.55, accuracy: 0.0001)
        XCTAssertTrue(canvas.accessibilityPerformDecrement())
        XCTAssertTrue(canvas.accessibilityPerformDecrement())
        XCTAssertEqual(canvas.fraction, 0.45, accuracy: 0.0001)
        // Press recentres — the one position every scrubbed mode has a use for.
        XCTAssertTrue(canvas.accessibilityPerformPress())
        XCTAssertEqual(canvas.fraction, 0.5)
    }

    @MainActor
    func testThePixelGridWinsOverThePointSize() {
        // A 2× image: 50 points, 100 pixels. The comparison speaks pixels.
        let image = NSImage(size: NSSize(width: 50, height: 50))
        let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 100, pixelsHigh: 100, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )
        if let representation {
            representation.size = NSSize(width: 50, height: 50)
            image.addRepresentation(representation)
        }

        XCTAssertEqual(
            ImageCompareCanvas.pixelSize(of: image), CGSize(width: 100, height: 100)
        )
    }

    @MainActor
    func testThePreferredHeightIsCappedSoATallScreenshotStaysARow() {
        let canvas = ImageCompareCanvas(frame: .zero)
        let tall = NSImage(size: NSSize(width: 100, height: 4000))
        canvas.old = .init(image: tall, title: "old")
        canvas.new = .init(image: tall, title: "new")

        // The cap is on the picture. The caption band is height the surface needs *besides* it,
        // so asking for the picture's height alone would take the captions back out of it.
        let captions = canvas.currentLayout.captions
        XCTAssertGreaterThan(captions.top.height, 0)
        XCTAssertEqual(
            canvas.preferredCanvasHeight(forWidth: 300) - captions.top.height - captions.bottom.height,
            ImageCompareDefaults.maximumPreferredCanvasHeight
        )
    }

    // MARK: - Expanding into the inspector

    @MainActor
    func testExpandingOpensTheInspectorAndClosingHandsBackWhereItWasLeft() throws {
        let view = Self.pair()
        let window = Self.window(hosting: view)
        defer { CompareInspectorPresenter.dismiss(in: window) }

        var persisted: [ImageCompareMode] = []
        view.onModeChange = { persisted.append($0) }

        let expand = try XCTUnwrap(
            Self.descendants(of: view).first { $0.accessibilityTitle() == "Open comparison" },
            "the surface offers no way to open itself"
        )
        XCTAssertTrue(expand.accessibilityPerformPress())
        XCTAssertTrue(CompareInspectorPresenter.isPresenting(in: window))

        let inspector = try XCTUnwrap(Self.inspector(in: window))
        XCTAssertEqual(
            inspector.accessibilityLabel(), "Comparison, baseline.png → current.png"
        )

        // The expanded surface is the same component, opened where the inline one stood — and
        // it does not offer to open what is already open.
        let expanded = try XCTUnwrap(
            Self.descendants(of: inspector).compactMap { $0 as? ImageCompareView }.first
        )
        XCTAssertFalse(expanded.allowsExpansion)
        XCTAssertEqual(expanded.mode, .wipeVertical)
        XCTAssertEqual(expanded.fraction, 0.25)
        let expandedButton = Self.descendants(of: inspector).first {
            $0.accessibilityTitle() == "Open comparison"
        }
        XCTAssertEqual(
            expandedButton?.isHidden, true, "the expanded surface offers to expand again"
        )

        expanded.mode = .difference
        expanded.fraction = 0.8
        CompareInspectorPresenter.dismiss(in: window)

        XCTAssertFalse(CompareInspectorPresenter.isPresenting(in: window))
        XCTAssertEqual(view.mode, .difference, "the mode the user settled on was thrown away")
        XCTAssertEqual(view.fraction, 0.8, "the scrub was thrown away")
        XCTAssertEqual(persisted, [.difference], "the host was never told to persist the mode")
    }

    @MainActor
    func testEscapeClosesTheExpandedComparisonFromInsideIt() throws {
        let view = Self.pair()
        let window = Self.window(hosting: view)
        defer { CompareInspectorPresenter.dismiss(in: window) }
        XCTAssertTrue(view.expand())

        // Offered the way AppKit offers one: from the window's content view down, so this is
        // also the route from the canvas, the chip and the close button inside it.
        let root = try XCTUnwrap(window.contentView)
        XCTAssertTrue(root.performKeyEquivalent(with: try Self.escapeEvent()))
        XCTAssertFalse(CompareInspectorPresenter.isPresenting(in: window))
    }

    @MainActor
    func testTheCloseButtonDismissesAndFocusReturnsToTheSurfaceBehind() throws {
        let view = Self.pair()
        let window = Self.window(hosting: view)
        defer { CompareInspectorPresenter.dismiss(in: window) }
        XCTAssertTrue(view.expand())

        let inspector = try XCTUnwrap(Self.inspector(in: window))
        let close = try XCTUnwrap(
            Self.descendants(of: inspector).first {
                $0.accessibilityTitle() == "Close comparison"
            }
        )
        XCTAssertTrue(close.accessibilityPerformPress())
        XCTAssertFalse(CompareInspectorPresenter.isPresenting(in: window))
        XCTAssertTrue(
            window.firstResponder === view.preferredFirstResponder,
            "focus did not come back to the comparison that opened it"
        )
    }

    /// The expanded comparison takes the same wash the media inspector does, for the same reason:
    /// the app's own header band is the one part of the window it does not cover, and left lit it
    /// stacked on the comparison's header as though the two were one strip of chrome. The ground
    /// around it closes it, exactly as the button does.
    @MainActor
    func testTheExpandedComparisonDimsTheWindowAndTheGroundClosesIt() throws {
        let view = Self.pair()
        let window = Self.window(hosting: view)
        defer { CompareInspectorPresenter.dismiss(in: window) }
        XCTAssertTrue(view.expand())

        let root = try XCTUnwrap(window.contentView)
        root.layoutSubtreeIfNeeded()
        let inspector = try XCTUnwrap(Self.inspector(in: window))
        let scrim = try XCTUnwrap(
            Self.scrims(in: root).first, "the comparison opened with nothing behind it"
        )

        XCTAssertEqual(scrim.frame, root.bounds, "the wash left part of the window lit")
        XCTAssertLessThan(
            try XCTUnwrap(root.subviews.firstIndex(of: scrim)),
            try XCTUnwrap(root.subviews.firstIndex(of: inspector)),
            "the wash was ordered over the surface it is meant to be under"
        )

        // The scrub takes focus as the surface opens, so its ring is suppressed until a key
        // press asks for it — the ring follows the canvas's bounds, which here is the window.
        let canvas = try XCTUnwrap(
            Self.descendants(of: inspector).compactMap { $0 as? ImageCompareCanvas }.first
        )
        XCTAssertTrue(window.firstResponder === canvas)
        XCTAssertFalse(
            canvas.showsKeyboardFocusRing, "opening the comparison outlined the whole surface"
        )

        scrim.mouseDown(with: try Self.clickEvent())

        XCTAssertFalse(CompareInspectorPresenter.isPresenting(in: window))
        XCTAssertNil(Self.inspector(in: window), "closing left the surface in the window")
        XCTAssertTrue(
            Self.scrims(in: root).isEmpty, "the wash outlived the surface it dimmed for"
        )
        XCTAssertTrue(
            window.firstResponder === view.preferredFirstResponder,
            "closing from the ground did not hand focus back"
        )
    }

    @MainActor
    func testTheExpandedComparisonOpensBelowTheWindowsTitlebarStrip() throws {
        let view = Self.pair()
        let window = Self.window(hosting: view)
        defer { CompareInspectorPresenter.dismiss(in: window) }
        XCTAssertTrue(view.expand())

        let root = try XCTUnwrap(window.contentView)
        root.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(
            root.safeAreaInsets.top, 0, "the fixture window has no titlebar strip to clear"
        )

        // The window draws its content full-size, so pinning to the content view's own top
        // opens the header under the traffic lights.
        let inspector = try XCTUnwrap(Self.inspector(in: window))
        XCTAssertEqual(
            inspector.frame.maxY,
            root.bounds.maxY - root.safeAreaInsets.top,
            accuracy: 1,
            "the expanded comparison opened under the window's own buttons"
        )
    }

    @MainActor
    func testASingleSideOffersNoExpansionAndOpensNothing() throws {
        let view = ImageCompareView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view.configure(old: nil, new: .init(image: Self.solidImage(.systemBlue), title: "added"))
        let window = Self.window(hosting: view)
        defer { CompareInspectorPresenter.dismiss(in: window) }

        // An added or deleted file is one picture. There is no comparison to open, so the
        // controls row stays out of the way entirely rather than offering a dead button.
        let expand = Self.descendants(of: view).first {
            $0.accessibilityTitle() == "Open comparison"
        }
        XCTAssertEqual(expand?.isHidden, true)
        XCTAssertFalse(CompareInspectorPresenter.isPresenting(in: window))
    }

    @MainActor
    func testTheInspectorRepaintsWhenTheThemeChangesUnderIt() throws {
        defer { AppThemePalette.set(.system) }
        let inspector = CompareInspectorView(
            content: CompareInspectorContent(
                old: .init(image: Self.solidImage(.systemRed), title: "baseline.png"),
                new: .init(image: Self.solidImage(.systemBlue), title: "current.png")
            )
        )
        inspector.frame = NSRect(x: 0, y: 0, width: 640, height: 420)
        inspector.appearance = NSAppearance(named: .aqua)

        AppThemePalette.set(AppThemeStyles.cyberpunk)
        let cyber = try XCTUnwrap(Self.corner(of: inspector))
        AppThemePalette.set(AppThemeStyles.swissMinimalist)
        let swiss = try XCTUnwrap(Self.corner(of: inspector))

        // The same instance redrawn: a ground frozen into a layer colour would survive this.
        XCTAssertNotEqual(cyber, swiss, "the inspector's ground did not follow the theme")
    }

    // MARK: - Fixtures

    /// A two-sided comparison, scrubbed somewhere nobody would land on by accident.
    @MainActor
    private static func pair() -> ImageCompareView {
        let view = ImageCompareView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view.configure(
            old: .init(image: solidImage(.systemRed), title: "baseline.png"),
            new: .init(image: solidImage(.systemBlue), title: "current.png")
        )
        view.mode = .wipeVertical
        view.fraction = 0.25
        return view
    }

    /// An unshown window dressed like the app's: content drawn full-size under a transparent
    /// titlebar, so the strip the traffic lights float over is real and the surface has
    /// something to clear. Unshown is everything else these assertions need — the inspector is
    /// presented into the content view, and first responder does not require a key window.
    @MainActor
    private static func window(hosting content: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        let host = NSView(frame: window.contentLayoutRect)
        window.contentView = host
        content.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            content.topAnchor.constraint(equalTo: host.topAnchor),
            content.heightAnchor.constraint(equalToConstant: 300)
        ])
        host.layoutSubtreeIfNeeded()
        return window
    }

    @MainActor
    private static func inspector(in window: NSWindow) -> CompareInspectorView? {
        guard let root = window.contentView else { return nil }
        return descendants(of: root).compactMap { $0 as? CompareInspectorView }.first
    }

    @MainActor
    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants(of:))
    }

    /// The wash `InWindowOverlay` puts under a covering surface, found by the name the installer
    /// gives it: the view itself stays private to that file, so nothing else can build or drop one.
    @MainActor
    private static func scrims(in root: NSView) -> [NSView] {
        root.subviews.filter { $0.identifier == InWindowOverlay.scrimIdentifier }
    }

    @MainActor
    private static func clickEvent() throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
    }

    @MainActor
    private static func escapeEvent() throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\u{1B}",
            charactersIgnoringModifiers: "\u{1B}",
            isARepeat: false,
            keyCode: CompareInspectorDefaults.escapeKeyCode
        ))
    }

    /// The inspector's own ground, sampled where nothing else draws.
    @MainActor
    private static func corner(of view: NSView) -> NSColor? {
        AppThemeRefresh.repaint(view)
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.colorAt(x: 4, y: 4)
    }

    @MainActor
    private static func solidImage(
        _ color: NSColor, size: NSSize = NSSize(width: 40, height: 40)
    ) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        return image
    }
}

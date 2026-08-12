import XCTest
@testable import Threading

/// The compare surface's drawn states, checked two ways: pixel samples pin the semantics a
/// wipe/fade/difference must have (which side shows where), and PNG fixtures make the look
/// reviewable by eye, light and dark — the same idea as `GitReviewRenderTests`.
@MainActor
final class ImageCompareRenderTests: XCTestCase {

    private enum Render {
        static var directory: URL {
            if let out = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"] {
                return URL(fileURLWithPath: out, isDirectory: true)
            }
            return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
        }
    }

    override func setUp() {
        super.setUp()
        AppThemePalette.set(.system)
    }

    override func tearDown() {
        AppThemePalette.set(.system)
        super.tearDown()
    }

    // MARK: - Wipe semantics

    func testTheWipeShowsOldBeforeTheSeamAndNewAfterIt() {
        let canvas = makeCanvas()
        canvas.mode = .wipeHorizontal
        canvas.fraction = 0.25

        let rep = bitmap(of: canvas)
        // Seam at x=100: red (old) to its left, blue (new) to its right.
        let left = sample(rep, x: 50, y: 100)
        let right = sample(rep, x: 300, y: 100)
        XCTAssertGreaterThan(left.redComponent, left.blueComponent, "old is not before the seam")
        XCTAssertGreaterThan(right.blueComponent, right.redComponent, "new is not after the seam")
    }

    func testTheFadeShowsTheNewSideAtFullFractionAndTheOldAtZero() {
        let canvas = makeCanvas()
        canvas.mode = .fade

        canvas.fraction = 1
        let full = sample(bitmap(of: canvas), x: 200, y: 100)
        XCTAssertGreaterThan(full.blueComponent, full.redComponent, "fraction 1 is not the new side")

        canvas.fraction = 0
        let none = sample(bitmap(of: canvas), x: 200, y: 100)
        XCTAssertGreaterThan(none.redComponent, none.blueComponent, "fraction 0 is not the old side")
    }

    func testTheDifferenceOfIdenticalImagesReadsAsBlack() {
        let image = Self.solidImage(.systemRed, size: NSSize(width: 200, height: 100))
        let canvas = ImageCompareCanvas(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        canvas.old = .init(image: image, title: "old")
        canvas.new = .init(image: image, title: "new")
        canvas.mode = .difference

        let sampled = sample(bitmap(of: canvas), x: 200, y: 100)
        XCTAssertLessThan(sampled.redComponent, 0.1, "identical pixels did not cancel")
        XCTAssertLessThan(sampled.greenComponent, 0.1)
        XCTAssertLessThan(sampled.blueComponent, 0.1)
    }

    func testSideBySideDrawsBothSidesWhole() {
        let canvas = ImageCompareCanvas(frame: NSRect(x: 0, y: 0, width: 410, height: 100))
        canvas.old = .init(
            image: Self.solidImage(.systemRed, size: NSSize(width: 100, height: 50)), title: "old"
        )
        canvas.new = .init(
            image: Self.solidImage(.systemBlue, size: NSSize(width: 100, height: 50)), title: "new"
        )
        canvas.mode = .sideBySide

        let rep = bitmap(of: canvas)
        let left = sample(rep, x: 100, y: 50)
        let right = sample(rep, x: 310, y: 50)
        XCTAssertGreaterThan(left.redComponent, left.blueComponent, "old is not on the left")
        XCTAssertGreaterThan(right.blueComponent, right.redComponent, "new is not on the right")
    }

    // MARK: - Captions

    /// The two names come off one ramp read by how much of its picture each side is showing:
    /// even at the middle, and the side being revealed coming forward as the seam travels. It is
    /// what says a caption belongs to the image beside it rather than to the comparison as a
    /// whole — inked by rank instead, a fully covered picture kept a title as solid as the one
    /// filling the canvas.
    ///
    /// Measured as ink, since the band is plain ground with words on it: how far each half of it
    /// departs from that ground is how present its caption is.
    func testTheCaptionsAreInkedByHowMuchOfEachPictureIsShowing() {
        let (canvas, host) = makeCaptionFixture()

        canvas.fraction = 0.5
        let even = captionInk(of: canvas, in: host)
        XCTAssertEqual(
            even.leading, even.trailing, accuracy: max(even.leading, even.trailing) * 0.2,
            "the pair is not even with the seam held at the middle"
        )

        canvas.fraction = 0.85
        let oldShowing = captionInk(of: canvas, in: host)
        canvas.fraction = 0.15
        let newShowing = captionInk(of: canvas, in: host)

        XCTAssertGreaterThan(
            oldShowing.leading, newShowing.leading,
            "the old side's name did not come forward as its picture was revealed"
        )
        XCTAssertGreaterThan(
            newShowing.trailing, oldShowing.trailing,
            "the new side's name did not come forward as its picture was revealed"
        )
    }

    /// A name leaves with the picture it belongs to. The band divides where the seam does, so a
    /// side scrubbed off the canvas takes its title with it instead of leaving a label hanging
    /// over pixels that are entirely the other image's.
    func testACaptionLeavesWithThePictureItNames() {
        let (canvas, host) = makeCaptionFixture()

        canvas.fraction = 0.5
        let even = captionInk(of: canvas, in: host)

        canvas.fraction = 0
        let covered = captionInk(of: canvas, in: host)

        XCTAssertLessThan(
            covered.leading, even.leading * 0.05,
            "the old side is not on the canvas at all, but its name is still in the band"
        )
        XCTAssertGreaterThan(covered.trailing, 0, "the side filling the canvas lost its name")
    }

    /// The fade divides opacity rather than area, so its fraction is the *new* side's presence —
    /// the one mode where the ramp reads the other way round from the seam's own travel.
    func testTheFadeInksTheNamesByTheBlendRatherThanBySeamPosition() {
        let (canvas, host) = makeCaptionFixture()
        canvas.mode = .fade

        canvas.fraction = 0.85
        let newShowing = captionInk(of: canvas, in: host)
        canvas.fraction = 0.15
        let oldShowing = captionInk(of: canvas, in: host)

        XCTAssertGreaterThan(
            newShowing.trailing, oldShowing.trailing,
            "the new side's name did not follow the blend it is drawn at"
        )
        XCTAssertGreaterThan(
            oldShowing.leading, newShowing.leading,
            "the old side's name did not recede as it was faded out"
        )
    }

    // MARK: - Theming

    /// The seam is the control, so it wears the theme's accent — sampled by hue the way the
    /// toggle's track is, since exact bytes drift with anti-aliasing. The sample point comes
    /// from the canvas's own layout: at fraction ½ the seam is the picture's vertical midline,
    /// and a few points below the picture's top is on the seam but clear of both the caption
    /// band above it and the handle at its centre.
    func testTheSeamTakesTheThemeAccentAndFollowsALiveSwitch() {
        let canvas = makeCanvas()
        canvas.mode = .wipeHorizontal
        canvas.fraction = 0.5

        let picture = canvas.currentLayout.placement.canvasRect
        let seam = (x: Int(picture.midX), y: Int(picture.minY) + 10)

        AppThemePalette.set(AppThemeStyles.cyberpunk)
        let cyber = sample(bitmap(of: canvas), x: seam.x, y: seam.y)

        // The same instance redrawn — a frozen layer colour would survive this switch.
        AppThemePalette.set(AppThemeStyles.swissMinimalist)
        let swiss = sample(bitmap(of: canvas), x: seam.x, y: seam.y)

        XCTAssertGreaterThan(cyber.greenComponent, cyber.redComponent, "Cyberpunk's seam is not green")
        XCTAssertGreaterThan(swiss.redComponent, swiss.greenComponent, "Swiss's seam is not red")
    }

    // MARK: - Fixtures to look at

    func testRendersEveryModeLightAndDark() throws {
        try FileManager.default.createDirectory(
            at: Render.directory, withIntermediateDirectories: true
        )

        for mode in ImageCompareMode.allCases {
            for (appearanceName, suffix) in [
                (NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")
            ] {
                guard let appearance = NSAppearance(named: appearanceName) else { continue }
                var data: Data?
                appearance.performAsCurrentDrawingAppearance {
                    let view = ImageCompareView(frame: .zero)
                    view.appearance = appearance
                    view.configure(
                        old: .init(image: Self.patternImage(base: .systemRed), title: "baseline.png"),
                        new: .init(image: Self.patternImage(base: .systemBlue), title: "current.png")
                    )
                    view.mode = mode
                    view.fraction = 0.6

                    let width: CGFloat = 480
                    let host = FilledHost(frame: NSRect(
                        x: 0, y: 0, width: width,
                        height: view.preferredHeight(forWidth: width)
                    ))
                    host.appearance = appearance
                    view.frame = host.bounds
                    host.addSubview(view)
                    host.layoutSubtreeIfNeeded()
                    data = Self.png(of: host)
                }
                let url = Render.directory
                    .appendingPathComponent("image-compare-\(mode.rawValue)-\(suffix).png")
                try XCTUnwrap(data, "no render for \(mode) \(suffix)").write(to: url)
            }
        }
        print("Image compare renders: \(Render.directory.path)")
    }

    /// The caption ramp across the whole travel, since it is a change in ink over five positions
    /// and no single frame shows it: the seam at each fifth, stacked. What a reviewer is looking
    /// for is the pair even in the middle row, each name coming forward as its picture takes the
    /// canvas, and the last row holding one title rather than two.
    func testRendersTheCaptionRampAcrossTheTravel() throws {
        try FileManager.default.createDirectory(
            at: Render.directory, withIntermediateDirectories: true
        )

        for (appearanceName, suffix) in [
            (NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")
        ] {
            guard let appearance = NSAppearance(named: appearanceName) else { continue }
            var data: Data?
            appearance.performAsCurrentDrawingAppearance {
                let width: CGFloat = 480
                let stack = FilledHost(frame: .zero)
                stack.appearance = appearance
                var y: CGFloat = 0
                // Stacked from the bottom up, since the host is not flipped — so the travel is
                // laid out in reverse to arrive at 0 on top.
                for fraction in [1, 0.75, 0.5, 0.25, 0] as [CGFloat] {
                    let view = ImageCompareView(frame: .zero)
                    view.appearance = appearance
                    view.configure(
                        old: .init(image: Self.patternImage(base: .systemRed), title: "baseline.png"),
                        new: .init(image: Self.patternImage(base: .systemBlue), title: "current.png")
                    )
                    view.mode = .wipeHorizontal
                    view.fraction = fraction
                    let height = view.preferredHeight(forWidth: width)
                    view.frame = NSRect(x: 0, y: y, width: width, height: height)
                    stack.addSubview(view)
                    y += height
                }
                stack.frame = NSRect(x: 0, y: 0, width: width, height: y)
                stack.layoutSubtreeIfNeeded()
                data = Self.png(of: stack)
            }
            let url = Render.directory
                .appendingPathComponent("image-compare-caption-ramp-\(suffix).png")
            try XCTUnwrap(data, "no caption ramp render for \(suffix)").write(to: url)
        }
        print("Image compare renders: \(Render.directory.path)")
    }

    /// The focused canvas, ring and all. The ring strokes the surface's own bounds, so this is
    /// the one state where the captions' clearance from the edge can be judged — and no fixture
    /// drew it, which is how the titles shipped sitting on the ring.
    func testRendersTheFocusedCanvasLightAndDark() throws {
        try FileManager.default.createDirectory(
            at: Render.directory, withIntermediateDirectories: true
        )

        for (appearanceName, suffix) in [
            (NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")
        ] {
            guard let appearance = NSAppearance(named: appearanceName) else { continue }
            var data: Data?
            var focused = false
            appearance.performAsCurrentDrawingAppearance {
                let canvas = ImageCompareCanvas(frame: .zero)
                canvas.appearance = appearance
                canvas.old = .init(image: Self.patternImage(base: .systemRed), title: "baseline.png")
                canvas.new = .init(image: Self.patternImage(base: .systemBlue), title: "current.png")
                canvas.mode = .wipeHorizontal
                canvas.fraction = 0.6

                let width: CGFloat = 480
                let host = FilledHost(frame: NSRect(
                    x: 0, y: 0, width: width,
                    height: canvas.preferredCanvasHeight(forWidth: width)
                ))
                host.appearance = appearance
                canvas.frame = host.bounds
                host.addSubview(canvas)

                // Built, never shown — an unshown window still takes a first responder, which
                // is all the ring asks of it.
                let window = NSWindow(
                    contentRect: host.bounds,
                    styleMask: [.titled],
                    backing: .buffered,
                    defer: false
                )
                window.isReleasedWhenClosed = false
                window.appearance = appearance
                window.contentView = host
                defer { window.close() }
                focused = window.makeFirstResponder(canvas)
                // The ring is shown for keyboard traversal only — a canvas the size of its
                // surface is focused programmatically the moment an inspector opens, and an
                // accent rectangle around everything says nothing. State the arrival the picture
                // is about.
                canvas.focusArrived(from: Self.tabEvent())

                data = Self.png(of: host)
            }
            XCTAssertTrue(focused, "the canvas did not take focus, so no ring was drawn")
            let url = Render.directory
                .appendingPathComponent("image-compare-focused-\(suffix).png")
            try XCTUnwrap(data, "no focused render for \(suffix)").write(to: url)
        }
        print("Image compare renders: \(Render.directory.path)")
    }

    /// The expanded comparison, which is the same surface with the window's room: the pair named
    /// once at the top, and the picture given everything under it. Worth a picture of its own
    /// because the header band is the only part of it this component draws itself.
    func testRendersTheExpandedComparisonLightAndDark() throws {
        try FileManager.default.createDirectory(
            at: Render.directory, withIntermediateDirectories: true
        )

        for (appearanceName, suffix) in [
            (NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")
        ] {
            guard let appearance = NSAppearance(named: appearanceName) else { continue }
            var data: Data?
            appearance.performAsCurrentDrawingAppearance {
                let inspector = CompareInspectorView(
                    content: CompareInspectorContent(
                        old: .init(
                            image: Self.patternImage(base: .systemRed), title: "baseline.png"
                        ),
                        new: .init(
                            image: Self.patternImage(base: .systemBlue), title: "current.png"
                        ),
                        mode: .wipeHorizontal,
                        fraction: 0.6
                    )
                )
                inspector.appearance = appearance
                inspector.frame = NSRect(x: 0, y: 0, width: 900, height: 620)
                inspector.layoutSubtreeIfNeeded()
                data = Self.png(of: inspector)
            }
            let url = Render.directory
                .appendingPathComponent("compare-inspector-\(suffix).png")
            try XCTUnwrap(data, "no expanded render for \(suffix)").write(to: url)
        }
        print("Image compare renders: \(Render.directory.path)")
    }

    // MARK: - Helpers

    /// Fills the window background behind the surface, the way a pane does. The canvas paints
    /// no ground of its own, so a PNG of it alone puts dark mode's white ink on transparency —
    /// legible in the app, invisible in the fixture.
    private final class FilledHost: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NSColor.windowBackgroundColor.setFill()
            bounds.fill()
        }
    }

    /// 400×200 canvas holding a red 200×100 old and a blue 200×100 new: the union fits the
    /// bounds exactly at 2×, so the canvas is the whole view and sample points are plain.
    private func makeCanvas() -> ImageCompareCanvas {
        let canvas = ImageCompareCanvas(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        canvas.old = .init(
            image: Self.solidImage(.systemRed, size: NSSize(width: 200, height: 100)), title: "old"
        )
        canvas.new = .init(
            image: Self.solidImage(.systemBlue, size: NSSize(width: 200, height: 100)), title: "new"
        )
        return canvas
    }

    /// A canvas inside the ground a pane would give it, both sides carrying the same title so
    /// one caption's ink can be weighed against the other's without the glyphs themselves being
    /// the difference. Dark, because white ink on a dark ground is the larger departure to
    /// measure; the ramp is the same either way.
    private func makeCaptionFixture() -> (canvas: ImageCompareCanvas, host: NSView) {
        let canvas = ImageCompareCanvas(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        canvas.old = .init(
            image: Self.solidImage(.systemRed, size: NSSize(width: 200, height: 100)),
            title: "shot.png"
        )
        canvas.new = .init(
            image: Self.solidImage(.systemBlue, size: NSSize(width: 200, height: 100)),
            title: "shot.png"
        )
        canvas.mode = .wipeHorizontal

        let host = FilledHost(frame: canvas.bounds)
        let appearance = NSAppearance(named: .darkAqua)
        host.appearance = appearance
        canvas.appearance = appearance
        host.addSubview(canvas)
        return (canvas, host)
    }

    /// How much ink each half of the top caption band is carrying, as its distance from the
    /// band's own ground. The halves are the band's, not the drawing's: where the titles are
    /// divided is part of what is under test.
    private func captionInk(
        of canvas: ImageCompareCanvas,
        in host: NSView
    ) -> (leading: CGFloat, trailing: CGFloat) {
        var measured: (leading: CGFloat, trailing: CGFloat) = (0, 0)
        (host.appearance ?? NSAppearance.currentDrawing()).performAsCurrentDrawingAppearance {
            let rendered = bitmap(of: host)
            let band = canvas.currentLayout.captions.top
            let half = band.width / 2
            measured = (
                ink(rendered, in: CGRect(x: band.minX, y: band.minY, width: half, height: band.height)),
                ink(rendered, in: CGRect(x: band.midX, y: band.minY, width: half, height: band.height))
            )
        }
        return measured
    }

    /// The ink in one rect: every other pixel's departure from the rect's first, which is the
    /// empty ground above a caption that hugs the far side of its band.
    private func ink(_ bitmap: (rep: NSBitmapImageRep, scale: CGFloat), in rect: CGRect) -> CGFloat {
        let x0 = Int(rect.minX * bitmap.scale)
        let x1 = min(Int(rect.maxX * bitmap.scale), bitmap.rep.pixelsWide)
        let y0 = Int(rect.minY * bitmap.scale)
        let y1 = min(Int(rect.maxY * bitmap.scale), bitmap.rep.pixelsHigh)
        guard x1 > x0, y1 > y0 else { return 0 }
        let ground = luma(bitmap.rep.colorAt(x: x0, y: y0))
        var total: CGFloat = 0
        for y in stride(from: y0, to: y1, by: 2) {
            for x in stride(from: x0, to: x1, by: 2) {
                total += abs(luma(bitmap.rep.colorAt(x: x, y: y)) - ground)
            }
        }
        return total
    }

    private func luma(_ color: NSColor?) -> CGFloat {
        guard let converted = color?.usingColorSpace(.sRGB) else { return 0 }
        return (converted.redComponent + converted.greenComponent + converted.blueComponent) / 3
    }

    private func bitmap(of view: NSView) -> (rep: NSBitmapImageRep, scale: CGFloat) {
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        // The rep is in device pixels — 2× on Retina — while the samples below speak view
        // points; the pair keeps the conversion in one place.
        return (rep, CGFloat(rep.pixelsWide) / max(view.bounds.width, 1))
    }

    private func sample(_ bitmap: (rep: NSBitmapImageRep, scale: CGFloat), x: Int, y: Int) -> NSColor {
        bitmap.rep.colorAt(
            x: Int(CGFloat(x) * bitmap.scale),
            y: Int(CGFloat(y) * bitmap.scale)
        )!.usingColorSpace(.sRGB)!
    }

    /// A Tab press, which is what "the user traversed here" looks like to a focus origin.
    private static func tabEvent() -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\t",
            charactersIgnoringModifiers: "\t",
            isARepeat: false,
            keyCode: 48
        )
    }

    private static func solidImage(_ color: NSColor, size: NSSize) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        return image
    }

    /// A fixture with structure, so the wipe and the difference have something to show in the
    /// PNGs a reviewer looks at.
    private static func patternImage(base: NSColor) -> NSImage {
        let size = NSSize(width: 240, height: 160)
        let image = NSImage(size: size)
        image.lockFocus()
        base.withAlphaComponent(0.35).setFill()
        NSRect(origin: .zero, size: size).fill()
        base.setFill()
        NSBezierPath(ovalIn: NSRect(x: 60, y: 40, width: 120, height: 80)).fill()
        NSColor.white.setFill()
        NSRect(x: 20, y: 20, width: 40, height: 24).fill()
        image.unlockFocus()
        return image
    }

    private static func png(of view: NSView) -> Data? {
        guard view.bounds.height > 1,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}

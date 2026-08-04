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

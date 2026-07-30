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

        XCTAssertEqual(
            canvas.preferredCanvasHeight(forWidth: 300),
            ImageCompareDefaults.maximumPreferredCanvasHeight
        )
    }

    // MARK: - Fixtures

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

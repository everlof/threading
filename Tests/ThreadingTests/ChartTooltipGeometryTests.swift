import XCTest
@testable import Threading

/// The chart tooltip's size and placement.
///
/// Reported from a real reading: a four-line tooltip whose last line was cut off. The box was
/// the right size and in the wrong place — the placement flipped away from the far edge and
/// nothing pulled it back from the near one, so the view clipped what fell outside. Neither half
/// is something an assertion about drawing would have caught, which is why the arithmetic is
/// separated from `draw`.
final class ChartTooltipGeometryTests: XCTestCase {

    /// The reading from the report: series, category, value, and a detail long enough to wrap at
    /// the 180pt maximum.
    private let reported = [
        "Disk used",
        "Swap files (34 × 1 GB)",
        "34 GB",
        "Cannot shrink while the volume is full; this is the deadlock"
    ].joined(separator: "\n")

    private let bounds = NSRect(x: 0, y: 0, width: 520, height: 260)

    private var margin: CGFloat { Design.Spacing.inset }

    private func assertInside(
        _ rect: NSRect,
        _ message: String,
        line: UInt = #line
    ) {
        XCTAssertGreaterThanOrEqual(rect.minX, bounds.minX, "\(message) — off the left", line: line)
        XCTAssertGreaterThanOrEqual(rect.minY, bounds.minY, "\(message) — off the bottom", line: line)
        XCTAssertLessThanOrEqual(rect.maxX, bounds.maxX, "\(message) — off the right", line: line)
        XCTAssertLessThanOrEqual(rect.maxY, bounds.maxY, "\(message) — off the top", line: line)
    }

    // MARK: - Placement

    /// **The regression.** A pointer low in the view flips the box downward, which used to put
    /// its origin below the bottom edge; the tooltip then drew fine and was clipped by the view.
    func testAPointerLowInTheViewKeepsTheWholeTooltipOnScreen() {
        let size = ThemedTimeSeriesChartView.tooltipSize(for: reported)

        for y in stride(from: CGFloat(0), through: 40, by: 8) {
            let rect = ThemedTimeSeriesChartView.tooltipRect(
                size: size,
                near: NSPoint(x: 260, y: y),
                in: bounds
            )
            assertInside(rect, "pointer at y=\(y)")
        }
    }

    func testAPointerAtEveryCornerKeepsTheWholeTooltipOnScreen() {
        let size = ThemedTimeSeriesChartView.tooltipSize(for: reported)
        let corners = [
            NSPoint(x: bounds.minX, y: bounds.minY),
            NSPoint(x: bounds.maxX, y: bounds.minY),
            NSPoint(x: bounds.minX, y: bounds.maxY),
            NSPoint(x: bounds.maxX, y: bounds.maxY)
        ]

        for corner in corners {
            let rect = ThemedTimeSeriesChartView.tooltipRect(
                size: size,
                near: corner,
                in: bounds
            )
            assertInside(rect, "pointer at \(corner)")
        }
    }

    /// Flipping still happens, and is still what keeps the box off the pointer: near the right
    /// edge it must sit to the *left* of the pointer rather than merely being pushed back.
    func testItStillFlipsRatherThanOverlappingThePointerAtTheFarEdge() {
        let size = ThemedTimeSeriesChartView.tooltipSize(for: reported)
        let pointer = NSPoint(x: bounds.maxX - 8, y: bounds.midY)

        let rect = ThemedTimeSeriesChartView.tooltipRect(size: size, near: pointer, in: bounds)

        XCTAssertLessThanOrEqual(rect.maxX, pointer.x, "the box should have flipped left of the pointer")
        assertInside(rect, "pointer near the right edge")
    }

    /// A box that cannot fit starts at the near inset rather than at a negative origin: legible
    /// from its first line beats centred on nothing.
    func testABoxLargerThanTheViewStartsInsideItRatherThanAboveIt() {
        let tiny = NSRect(x: 0, y: 0, width: 80, height: 40)
        let size = ThemedTimeSeriesChartView.tooltipSize(for: reported)
        XCTAssertGreaterThan(size.height, tiny.height, "fixture must actually overflow")

        let rect = ThemedTimeSeriesChartView.tooltipRect(
            size: size,
            near: NSPoint(x: 40, y: 20),
            in: tiny
        )

        XCTAssertEqual(rect.minX, tiny.minX + margin, accuracy: 0.5)
        XCTAssertEqual(rect.minY, tiny.minY + margin, accuracy: 0.5)
    }

    // MARK: - Size

    /// The box must be tall enough for the text **at the width it is drawn into**, which is the
    /// half a single-pass measurement gets wrong: it wraps at the maximum width, then the box
    /// shrinks to the longest line and the text is laid out again in less room than it was
    /// measured in.
    func testTheBoxFitsItsTextAtTheWidthItIsDrawnInto() {
        let size = ThemedTimeSeriesChartView.tooltipSize(for: reported)
        let contentWidth = size.width - Design.Chart.tooltipInset * 2
        let contentHeight = size.height - Design.Chart.tooltipInset * 2

        let needed = NSAttributedString(
            string: reported,
            attributes: ThemedTimeSeriesChartView.tooltipAttributes
        ).boundingRect(
            with: NSSize(width: contentWidth, height: .greatestFiniteMagnitude),
            options: ThemedTimeSeriesChartView.tooltipDrawingOptions
        )

        XCTAssertGreaterThanOrEqual(
            contentHeight,
            needed.height.rounded(.up),
            "the tooltip is shorter than the text it will draw, so the last line clips"
        )
    }

    /// The detail genuinely wraps at this width — otherwise the test above proves nothing.
    ///
    /// Compared as *content* heights: the insets are paid once per box, so measuring a one-line
    /// tooltip and multiplying counts them four times over. That mistake is what this assertion
    /// caught on its first run, and it is the reason the size turned out never to have been the
    /// bug — the reported reading measures five visual lines, which is correct.
    func testTheReportedDetailActuallyWraps() {
        let inset = Design.Chart.tooltipInset * 2
        let oneLine = ThemedTimeSeriesChartView.tooltipSize(for: "Disk used").height - inset
        let wrapped = ThemedTimeSeriesChartView.tooltipSize(for: reported)

        XCTAssertGreaterThan(
            wrapped.height - inset,
            oneLine * 4,
            "four logical lines, one of which wraps, should exceed four unwrapped lines"
        )
        XCTAssertLessThanOrEqual(wrapped.width, Design.Chart.tooltipMaxWidth + inset)
    }

    /// **The second regression, and the one an arithmetic assertion could not see.** The box was
    /// measured with `.usesFontLeading` and drawn without it — `boundingRect` honours the option
    /// and an *unflipped* context ignores it, and an `NSView` is unflipped unless it says
    /// otherwise. At SF 11pt that is 13 points per line measured against 14 points per line
    /// drawn: a five-line reading was boxed at 65 and laid out at 70, and lost its last line to
    /// the difference. Every assertion above passed throughout, because the two passes agreed
    /// with each other and disagreed with the screen.
    ///
    /// So the box is checked against a **drawn** layout in the coordinate space the chart draws
    /// in. The comparison holds for whichever face the live theme resolves `detail()` to, though
    /// only some of them are wide enough for the old options to have been caught by it — the
    /// system face at 11pt, the default, is one.
    func testTheBoxFitsTheTextTheChartActuallyDraws() throws {
        let string = NSAttributedString(
            string: reported,
            attributes: ThemedTimeSeriesChartView.tooltipAttributes
        )
        let size = ThemedTimeSeriesChartView.tooltipSize(for: string)
        let padding = Design.Chart.tooltipInset * 2

        let drawn = try drawnBounds(of: string, width: size.width - padding)

        XCTAssertLessThanOrEqual(
            drawn.height,
            size.height - padding,
            "the text lays out taller than the box that will clip it, so the last line goes"
        )
    }

    /// What the chart's own drawing lays this text out to, unflipped, with room to spare below.
    ///
    /// The room matters: drawn into a box that is too short, the reported bounds are the *clipped*
    /// ones — a four-line reading in a three-line box measures three lines and looks correct. Give
    /// it height it cannot use and what comes back is what the text wanted.
    private func drawnBounds(of string: NSAttributedString, width: CGFloat) throws -> NSRect {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 400,
            pixelsHigh: 400,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        XCTAssertFalse(
            context.isFlipped,
            "a flipped fixture agrees with the measurement and cannot see this at all"
        )

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        let measurement = NSStringDrawingContext()
        string.draw(
            with: NSRect(x: 0, y: 0, width: width, height: 400),
            options: ThemedTimeSeriesChartView.tooltipDrawingOptions,
            context: measurement
        )
        return measurement.totalBounds
    }

    /// A one-line tooltip still shrinks to its text rather than always claiming the maximum.
    func testAShortTooltipDoesNotClaimTheFullWidth() {
        let size = ThemedTimeSeriesChartView.tooltipSize(for: "34 GB")

        XCTAssertLessThan(size.width, Design.Chart.tooltipMaxWidth)
    }
}

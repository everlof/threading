import AppKit
import XCTest
@testable import Skalman

/// Draws the inspector's overlay onto a bitmap the way `WindowSnapshot` does and writes each
/// story out as an image, both appearances — the same fixture-to-PNG idea as the conversation,
/// git-review and code-stats renders, for the same reason.
///
/// This one earns it more than most: every claim the layered overlay makes is a claim about
/// *colour and position* — that nine outlines stay told apart, that a measure lands between
/// the edges it names, that the key does not sit on top of what it is a key to. None of those
/// is checkable by reading assertions about rectangles.
@MainActor
final class InspectorHierarchyRenderTests: XCTestCase {

    // MARK: - Configuration

    private enum Render {
        static let size = NSSize(width: 720, height: 460)

        static var directory: URL {
            if let override = ProcessInfo.processInfo.environment["SKALMAN_RENDER_OUT"] {
                return URL(fileURLWithPath: override)
            }
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("SkalmanRenders", isDirectory: true)
        }
    }

    // MARK: - Fixtures

    private final class PaneView: NSView {}
    private final class RowView: NSView {}
    private final class LabelBoxView: NSView {}

    private final class IconView: NSView {}

    /// The crowded case, and the one the layers are hardest to read on: a 13pt icon inside a
    /// 30pt sidebar row. Every gap around it is smaller than the chip naming it, so this is
    /// where labels have nowhere to sit unless they are put somewhere deliberately.
    private func makeTightTree() -> NSView {
        let window = NSView(frame: NSRect(origin: .zero, size: Render.size))
        let pane = PaneView(frame: NSRect(x: 40, y: 40, width: 300, height: 320))
        let row = RowView(frame: NSRect(x: 8, y: 220, width: 284, height: 30))
        let icon = IconView(frame: NSRect(x: 10, y: 8, width: 13, height: 13))

        window.addSubview(pane)
        pane.addSubview(row)
        row.addSubview(icon)
        window.layoutSubtreeIfNeeded()

        return icon
    }

    /// A pane holding a row holding a label, insets deliberately uneven so a measure has
    /// something to say on every side.
    private func makeTree() -> NSView {
        let window = NSView(frame: NSRect(origin: .zero, size: Render.size))
        let pane = PaneView(frame: NSRect(x: 40, y: 40, width: 420, height: 320))
        let content = NSView(frame: pane.bounds)
        let row = RowView(frame: NSRect(x: 24, y: 180, width: 372, height: 64))
        let label = LabelBoxView(frame: NSRect(x: 18, y: 22, width: 210, height: 20))

        window.addSubview(pane)
        pane.addSubview(content)
        content.addSubview(row)
        row.addSubview(label)
        window.layoutSubtreeIfNeeded()

        return label
    }

    // MARK: - Stories

    func testRendersTheOverlayStorybook() throws {
        let target = makeTree()
        let levels = InspectorHierarchy.levels(for: target)

        var written = 0
        written += try write(story: "01-plain", levels: levels, layers: [])
        written += try write(story: "02-hierarchy", levels: levels, layers: .hierarchy)
        written += try write(story: "03-spacing", levels: levels, layers: .spacing)
        written += try write(story: "04-hierarchy-spacing", levels: levels, layers: [.hierarchy, .spacing])

        // The case the layers are hardest to read on, and therefore the one worth looking at.
        let tight = InspectorHierarchy.levels(for: makeTightTree())
        written += try write(story: "05-tight-spacing", levels: tight, layers: .spacing)
        written += try write(story: "06-tight-hierarchy-spacing", levels: tight, layers: [.hierarchy, .spacing])

        XCTAssertEqual(written, 12, "Every story should render in both appearances")
        print("Rendered inspector overlay storybook to \(Render.directory.path)")
    }

    // MARK: - Assertions

    /// The whole point of the layer: two nested outlines must not be the same colour, or the
    /// hierarchy is one shape with extra edges.
    func testNestedOutlinesAreDrawnInDifferentColours() throws {
        let levels = InspectorHierarchy.levels(for: makeTree())
        XCTAssertGreaterThan(levels.count, 2, "the fixture should nest at least three deep")

        let rep = try draw(levels: levels, layers: .hierarchy, appearance: .darkAqua)

        let samples = try levels.prefix(3).map { level -> NSColor in
            // The left edge, mid-height: on the outline and nothing else.
            try XCTUnwrap(
                colour(in: rep, x: level.rect.minX + 1, y: level.rect.midY),
                "no pixel on the outline of depth \(level.depth)"
            )
        }

        for (index, sample) in samples.enumerated() {
            for other in samples[(index + 1)...] {
                XCTAssertGreaterThan(
                    distance(sample, other),
                    0.2,
                    "two levels drew in indistinguishable colours"
                )
            }
        }
    }

    /// The key sits in the corner furthest from the pick, so it never covers the thing it is
    /// a key to.
    func testTheLegendTakesTheCornerAwayFromTheTarget() {
        let bounds = NSRect(origin: .zero, size: Render.size)
        let size = NSSize(width: 220, height: 90)

        let forRightHandTarget = InspectorLegendPlacement.origin(
            size: size,
            target: NSRect(x: 560, y: 300, width: 100, height: 40),
            within: bounds
        )
        let forLeftHandTarget = InspectorLegendPlacement.origin(
            size: size,
            target: NSRect(x: 60, y: 300, width: 100, height: 40),
            within: bounds
        )

        XCTAssertEqual(forRightHandTarget.x, bounds.minX + Design.Spacing.inset)
        XCTAssertEqual(forLeftHandTarget.x, bounds.maxX - Design.Spacing.inset - size.width)
        XCTAssertEqual(forRightHandTarget.y, forLeftHandTarget.y)
    }

    /// A key that ran off the bottom of a short window would take its deepest rows with it
    /// silently. It folds instead, and says how many it folded — the drawing still outlines
    /// every level, and the report still names every one.
    func testTheLegendFoldsRatherThanRunningOffAShortWindow() {
        let deep = (0..<40).map { depth in
            InspectorLevel(
                depth: depth,
                rect: NSRect(x: 0, y: 0, width: 100, height: 100),
                classNames: ["ProbeView\(depth)"],
                address: "0x0",
                identifier: nil
            )
        }
        let short = NSRect(x: 0, y: 0, width: 600, height: 200)

        let rows = InspectorLegendPlacement.rows(for: deep, layers: .hierarchy, within: short)

        XCTAssertLessThan(rows.count, deep.count)
        XCTAssertNil(rows.last?.hue, "the fold names no colour")
        XCTAssertEqual(
            rows.last?.title,
            InspectorStrings.legendFold(deep.count - (rows.count - 1))
        )
        XCTAssertTrue(rows.dropLast().allSatisfy { $0.hue != nil })

        // Nothing folds when everything fits.
        let tall = NSRect(x: 0, y: 0, width: 600, height: 1200)
        XCTAssertEqual(
            InspectorLegendPlacement.rows(for: deep, layers: .hierarchy, within: tall).count,
            deep.count
        )
    }

    /// The answer to the case the canvas cannot serve: around a 13pt icon there is nowhere
    /// legible for four numbers, so the key restates them where there is always room.
    func testTheKeyRestatesTheMeasurementsWhenSpacingIsHeld() throws {
        let levels = InspectorHierarchy.levels(for: makeTightTree())
        let bounds = NSRect(origin: .zero, size: Render.size)

        let withSpacing = InspectorLegendPlacement.rows(
            for: InspectorHierarchy.shown(levels, for: .spacing),
            layers: .spacing,
            within: bounds
        )
        let withoutSpacing = InspectorLegendPlacement.rows(
            for: InspectorHierarchy.shown(levels, for: .hierarchy),
            layers: .hierarchy,
            within: bounds
        )

        let measured = try XCTUnwrap(withSpacing.last)
        XCTAssertNil(measured.hue, "a measurement names two colours rather than being one")
        XCTAssertEqual(measured.title, "0 in 1 · leading 10 · trailing 261 · top 9 · bottom 8")
        XCTAssertFalse(
            withoutSpacing.contains { $0.title.contains("leading") },
            "⌃ alone measures nothing, so the key must claim no measurements"
        )
    }

    /// Nothing is drawn outside the window: the overlay is exactly the host's size, so a badge
    /// or a key that ran past it would be clipped away rather than merely ugly.
    func testEveryLayerStaysInsideTheWindow() throws {
        let levels = InspectorHierarchy.levels(for: makeTree())
        let rep = try draw(levels: levels, layers: [.hierarchy, .spacing], appearance: .darkAqua)

        XCTAssertEqual(rep.pixelsWide, Int(Render.size.width))
        XCTAssertEqual(rep.pixelsHigh, Int(Render.size.height))
    }

    // MARK: - Harness

    private func write(story: String, levels: [InspectorLevel], layers: InspectorLayers) throws -> Int {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var written = 0
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let rep = try draw(levels: levels, layers: layers, appearance: appearance)
            let data = try XCTUnwrap(
                rep.representation(using: .png, properties: [:]),
                "Failed to render \(story) in \(name)"
            )
            try data.write(to: directory.appendingPathComponent("inspect-\(story)-\(name).png"))
            written += 1
        }
        return written
    }

    /// The bitmap path `WindowSnapshot.annotate` takes, over a stand-in for the window under
    /// it — a flat ground, since what is being reviewed is the overlay and not the app.
    private func draw(
        levels: [InspectorLevel],
        layers: InspectorLayers,
        appearance name: NSAppearance.Name
    ) throws -> NSBitmapImageRep {
        let bounds = NSRect(origin: .zero, size: Render.size)
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(bounds.width), pixelsHigh: Int(bounds.height),
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ))
        rep.size = bounds.size

        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        let render = {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context

            NSColor.textBackgroundColor.setFill()
            bounds.fill()
            // A slab where the fixture's pane is, so an outline is read against content
            // rather than against an empty field.
            NSColor.controlBackgroundColor.setFill()
            NSRect(x: 40, y: 40, width: 420, height: 320).fill()

            InspectorIndicatorDrawing.draw(
                .element(levels: levels, layers: layers),
                within: bounds
            )

            context.flushGraphics()
            NSGraphicsContext.restoreGraphicsState()
        }

        if #available(macOS 11.0, *) {
            NSAppearance(named: name)?.performAsCurrentDrawingAppearance(render)
        } else {
            render()
        }

        return rep
    }

    /// `colorAt` counts rows from the top; the drawing speaks window space.
    private func colour(in rep: NSBitmapImageRep, x: CGFloat, y: CGFloat) -> NSColor? {
        rep.colorAt(x: Int(x.rounded()), y: rep.pixelsHigh - Int(y.rounded()))?
            .usingColorSpace(.sRGB)
    }

    private func distance(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat {
        abs(lhs.redComponent - rhs.redComponent)
            + abs(lhs.greenComponent - rhs.greenComponent)
            + abs(lhs.blueComponent - rhs.blueComponent)
    }
}

import AppKit
import XCTest
@testable import Threading

/// The drawing half of "aligned by ink" (`docs/THEME_BOUNDARY.md`, rule 9): what a component
/// draws is centred by the pixels it puts down, not by the geometry it was built from.
///
/// `OpticalInsetProviding` is the container's half and cannot reach this one. There the frame is
/// bigger than the ink and the container subtracts the difference; here the frame is honest and
/// the *path* is not, so every container above is placing it correctly and the mark is still off
/// the line. Found on `ThemedWarningMark`, whose rounded apex ate a point off the top of a
/// triangle whose three construction points were exactly centred.
@MainActor
final class OpticalCentringTests: XCTestCase {

    private let box = NSRect(x: 0, y: 0, width: 20, height: 20)

    // MARK: - The offset

    func testEvenlySpreadInkIsCentredByItsBox() {
        let ink = NSRect(x: 2, y: 3, width: 10, height: 10)

        let offset = OpticalCentring.offset(centring: ink, in: box)

        XCTAssertEqual(offset.width, 3, accuracy: 0.001)
        XCTAssertEqual(offset.height, 2, accuracy: 0.001)
    }

    /// Ink already centred asks for nothing, so a component can call this unconditionally.
    func testCentredInkAsksForNoMovement() {
        let ink = NSRect(x: 5, y: 5, width: 10, height: 10)

        XCTAssertEqual(OpticalCentring.offset(centring: ink, in: box), .zero)
    }

    /// The declared fallback, for ink that cannot be measured — an image, a glyph run. A
    /// bottom-heavy shape rises by `balance` of the distance from its box's middle to a
    /// triangle's centroid: `height / 12` at the default half.
    func testDeclaredBaseHeavyInkRises() {
        let ink = NSRect(x: 4, y: 4, width: 12, height: 12)

        let offset = OpticalCentring.offset(centring: ink, in: box, mass: .baseHeavy)

        XCTAssertEqual(offset.height, 1, accuracy: 0.001)
        XCTAssertEqual(
            offset.width, 0, accuracy: 0.001,
            "the correction is vertical only — mass says nothing about the horizontal"
        )
    }

    func testDeclaredTopHeavyInkFallsByTheSameAmount() {
        let ink = NSRect(x: 4, y: 4, width: 12, height: 12)

        XCTAssertEqual(
            OpticalCentring.offset(centring: ink, in: box, mass: .topHeavy).height,
            -1,
            accuracy: 0.001
        )
    }

    // MARK: - Measuring it instead

    /// A shape can be weighed, so it is: the declared vocabulary exists only for ink that
    /// cannot be. A triangle's centroid is a third of the way up from its base, which is where
    /// `InkMass.baseHeavy`'s number came from in the first place.
    func testATrianglesCentreOfMassIsMeasuredRatherThanDeclared() throws {
        let triangle = NSBezierPath()
        triangle.move(to: NSPoint(x: 6, y: 12))
        triangle.line(to: NSPoint(x: 12, y: 0))
        triangle.line(to: NSPoint(x: 0, y: 0))
        triangle.close()

        let mass = try XCTUnwrap(OpticalCentring.centreOfMass(of: triangle))

        XCTAssertEqual(mass.x, 6, accuracy: 0.01)
        XCTAssertEqual(mass.y, 4, accuracy: 0.01, "a third of the way up from the base")

        let offset = OpticalCentring.offset(
            centring: triangle,
            in: NSRect(x: 0, y: 0, width: 12, height: 12)
        )
        XCTAssertEqual(
            offset.height, 1, accuracy: 0.01,
            "half of the 2pt from the box's middle to the centroid — the declared number, derived"
        )
    }

    /// A disc's mass sits on its middle, so measuring one asks for no correction at all. This is
    /// what makes the measured API safe to call from every shape rather than only from the ones
    /// somebody remembered to classify.
    func testASymmetricShapeMeasuresNoCorrection() {
        let bounds = NSRect(x: 0, y: 0, width: 12, height: 12)
        let disc = NSBezierPath(ovalIn: NSRect(x: 3, y: 3, width: 6, height: 6))

        let offset = OpticalCentring.offset(centring: disc, in: bounds)

        XCTAssertEqual(offset.width, 0, accuracy: 0.05)
        XCTAssertEqual(offset.height, 0, accuracy: 0.05)
    }

    /// Signed areas, so a shape drawn as a ring answers for the ring rather than for its hole.
    func testAHoleDoesNotDragTheCentreOfMass() throws {
        let ring = NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: 12, height: 12))
        ring.append(NSBezierPath(ovalIn: NSRect(x: 4, y: 4, width: 4, height: 4)).reversed)

        let mass = try XCTUnwrap(OpticalCentring.centreOfMass(of: ring))

        XCTAssertEqual(mass.x, 6, accuracy: 0.05)
        XCTAssertEqual(mass.y, 6, accuracy: 0.05)
    }

    /// A path enclosing no area — a single line, or a shape that is only ever stroked — has
    /// nothing to weigh, and says so rather than answering with a number.
    func testAPathWithNoAreaIsNotWeighed() {
        let line = NSBezierPath()
        line.move(to: NSPoint(x: 0, y: 0))
        line.line(to: NSPoint(x: 10, y: 0))

        XCTAssertNil(OpticalCentring.centreOfMass(of: line))
        XCTAssertEqual(
            OpticalCentring.offset(centring: line, in: box).height,
            box.midY,
            accuracy: 0.001,
            "with nothing to weigh, the bounding box is still centred"
        )
    }

    func testEmptyInkIsLeftAlone() {
        XCTAssertEqual(OpticalCentring.offset(centring: .zero, in: box), .zero)
        XCTAssertEqual(NSBezierPath().centringInk(in: box).elementCount, 0)
    }

    // MARK: - The path

    /// The case that started it: rounding a triangle's corners takes a point off the *apex* and
    /// nothing off the base, so a path built around a centred set of vertices draws low.
    func testRoundingAVertexMovesTheInkAndCentringPutsItBack() throws {
        let bounds = NSRect(x: 0, y: 0, width: 12, height: 12)

        // The same construction `ThemedWarningMark` uses, without the correction.
        let raw = NSBezierPath()
        let apex = NSPoint(x: 6, y: 10.75)
        let right = NSPoint(x: 11.5, y: 1.25)
        let left = NSPoint(x: 0.5, y: 1.25)
        raw.move(to: NSPoint(x: (apex.x + right.x) / 2, y: (apex.y + right.y) / 2))
        raw.appendArc(from: right, to: left, radius: 2)
        raw.appendArc(from: left, to: apex, radius: 2)
        raw.appendArc(from: apex, to: right, radius: 2)
        raw.close()

        XCTAssertLessThan(
            raw.bounds.midY,
            bounds.midY,
            "the rounded apex should pull the drawn shape below the vertices' centre"
        )

        let centred = try XCTUnwrap(raw.copy() as? NSBezierPath)
        centred.centringInk(in: bounds, balance: 0)
        XCTAssertEqual(centred.bounds.midY, bounds.midY, accuracy: 0.001)
        XCTAssertEqual(centred.bounds.midX, bounds.midX, accuracy: 0.001)
        XCTAssertEqual(
            centred.bounds.size.width, raw.bounds.size.width, accuracy: 0.5,
            "centring moves the shape; it must not resize it"
        )
    }

    /// The mark ships with the correction applied, which is what keeps the rule from being a
    /// paragraph nobody runs.
    func testTheWarningMarkAppliesBoth() throws {
        let bounds = NSRect(x: 0, y: 0, width: 12, height: 12)
        let path = ThemedWarningMark.trianglePath(in: bounds)
        let ink = path.bounds
        let mass = try XCTUnwrap(OpticalCentring.centreOfMass(of: path))

        // Translation does not change how far the ink's box sits from its own centre of mass,
        // so the shipped shape can be checked against the rule directly: the box ends up
        // `balance` of that distance off the slot's middle.
        let lopsidedness = ink.midY - mass.y
        XCTAssertGreaterThan(lopsidedness, 0, "a triangle's mass sits below its box's middle")
        XCTAssertEqual(
            ink.midY - bounds.midY,
            OpticalCentring.balance * lopsidedness,
            accuracy: 0.05,
            "the shipped mark sits balance-of-the-way between its box and its centre of mass"
        )
        XCTAssertEqual(
            ink.midX - bounds.midX,
            OpticalCentring.balance * (ink.midX - mass.x),
            accuracy: 0.05,
            "the same rule sideways — a mark pointing right would need it, and a triangle's own "
                + "flattening leaves a fraction of a point of it"
        )
        XCTAssertTrue(bounds.contains(ink), "the lift must not push the apex out of the slot")
    }

    // MARK: - The vocabulary

    /// Every component whose whole job is to draw one mark inside its own bounds, measured off
    /// its own render. A component added to this list without obeying the rule fails here rather
    /// than being noticed in a screenshot months later.
    ///
    /// Deliberately not "every design component": a progress bar fills from one edge, a
    /// separator *is* its edge, and a tab strip is a row of things. This is the list of views
    /// that draw a single glyph in a slot, where being off centre is always a defect.
    func testEveryMarkComponentDrawsItsInkOnTheCentre() throws {
        let marks: [(String, NSView)] = [
            ("ThemedWarningMark.negative", ThemedWarningMark()),
            ("ThemedWarningMark.warning", {
                let mark = ThemedWarningMark()
                mark.severity = .warning
                return mark
            }()),
            ("GlyphView", {
                let glyph = GlyphView()
                glyph.image = Design.Symbol.image(
                    "gearshape",
                    slot: Design.Size.inlineButtonGlyph,
                    pointSize: Design.Symbol.control
                )
                glyph.tint = Design.Text.label
                return glyph
            }()),
            ("ThemedFloatingGlyphView", ThemedFloatingGlyphView(
                systemSymbolName: "folder",
                classicGlyph: .folder,
                pointSize: Design.Symbol.toolbar
            )),
            ("ThreadingMarkView", ThreadingMarkView())
        ]

        for (name, mark) in marks {
            let size = mark.intrinsicContentSize
            let side = max(24, max(size.width, size.height) + 8)
            let host = NSView(frame: NSRect(x: 0, y: 0, width: side, height: side))
            host.wantsLayer = true
            mark.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(mark)
            NSLayoutConstraint.activate([
                mark.centerXAnchor.constraint(equalTo: host.centerXAnchor),
                mark.centerYAnchor.constraint(equalTo: host.centerYAnchor)
            ])
            host.layoutSubtreeIfNeeded()

            let ink = try XCTUnwrap(inkBounds(of: host), "\(name) drew nothing at all")
            XCTAssertEqual(
                ink.midY, host.bounds.midY, accuracy: 1,
                "\(name) draws its ink off the horizontal centre line"
            )
            XCTAssertEqual(
                ink.midX, host.bounds.midX, accuracy: 1,
                "\(name) draws its ink off the vertical centre line"
            )
        }
    }

    // MARK: - Helpers

    /// The bounding box of what a view actually draws, in its own coordinates.
    ///
    /// The ground is taken from the render rather than from a `Design` role: a component that
    /// draws its own surface would otherwise make every pixel count as ink, which reads as
    /// perfect centring — one of the two ways this measurement was wrong first.
    private func inkBounds(of view: NSView) -> NSRect? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)

        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        var counts: [Int: Int] = [:]
        var pixels: [[NSColor]] = []
        for pixelY in 0..<rep.pixelsHigh {
            var row: [NSColor] = []
            for pixelX in 0..<rep.pixelsWide {
                let colour = rep.colorAt(x: pixelX, y: pixelY)?
                    .usingColorSpace(.deviceRGB) ?? .clear
                row.append(colour)
                counts[key(colour), default: 0] += 1
            }
            pixels.append(row)
        }
        guard let ground = counts.max(by: { $0.value < $1.value })?.key else { return nil }

        var minX = rep.pixelsWide
        var maxX = -1
        var minY = rep.pixelsHigh
        var maxY = -1
        for (pixelY, row) in pixels.enumerated() {
            for (pixelX, colour) in row.enumerated() where key(colour) != ground {
                minX = min(minX, pixelX)
                maxX = max(maxX, pixelX)
                minY = min(minY, pixelY)
                maxY = max(maxY, pixelY)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }

        // The bitmap runs top-down and the view does not.
        return NSRect(
            x: CGFloat(minX) / scale,
            y: view.bounds.height - CGFloat(maxY + 1) / scale,
            width: CGFloat(maxX - minX + 1) / scale,
            height: CGFloat(maxY - minY + 1) / scale
        )
    }

    /// Colour bucketed coarsely enough that antialiasing does not invent a second ground.
    private func key(_ colour: NSColor) -> Int {
        guard colour.alphaComponent > 0.05 else { return -1 }
        let red = Int(colour.redComponent * 31)
        let green = Int(colour.greenComponent * 31)
        let blue = Int(colour.blueComponent * 31)
        return red << 10 | green << 5 | blue
    }
}

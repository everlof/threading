import AppKit
import XCTest
@testable import Threading

/// The swatch that shows a reported colour pair as the reader saw it.
///
/// Everything here is about one thing being true: the specimen has to keep reporting the colours
/// it was handed, including — especially — when they are the same colour and there is visibly
/// nothing to see. A swatch that quietly separated them, or that took the app theme's ink for one
/// of them, would turn the diagnostic into a picture of a problem that does not exist.
@MainActor
final class ColorPairSpecimenTests: XCTestCase {

    // MARK: - Fixture

    private enum Fixture {
        /// The reported pair: a program's own 24-bit grey on a terminal background four steps
        /// away from it, at 1.17:1.
        static let reportedInk = NSColor(srgbRed: 0x50 / 255, green: 0x50 / 255, blue: 0x50 / 255, alpha: 1)
        static let reportedGround = NSColor(srgbRed: 0x46 / 255, green: 0x46 / 255, blue: 0x46 / 255, alpha: 1)
        /// A pair with nothing wrong with it, for the cases that need the specimen to be legible.
        static let readableInk = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        static let readableGround = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        static let label = "Text color #505050 shown on background color #464646"
    }

    override func tearDown() {
        AppThemePalette.set(.system)
        super.tearDown()
    }

    private func specimen(
        ink: NSColor = Fixture.reportedInk,
        ground: NSColor = Fixture.reportedGround,
        caption: String? = nil
    ) -> ColorPairSpecimenView {
        let view = ColorPairSpecimenView(
            ink: ink,
            ground: ground,
            caption: caption,
            accessibilityLabel: Fixture.label
        )
        // Without an appearance the offscreen draw resolves no dynamic colour and comes out
        // blank — the theme's outline included, which is half of what is measured here.
        view.appearance = NSAppearance(named: .darkAqua)
        view.frame = NSRect(origin: .zero, size: view.intrinsicContentSize)
        view.layoutSubtreeIfNeeded()
        return view
    }

    /// A drawn copy of the swatch, measured in its own pixels.
    ///
    /// The rep is backing-scaled, so every coordinate below is derived from *it* rather than from
    /// the view's points. Sampling a 2× rep at point coordinates is how a scan meant for the flat
    /// middle of an edge lands in the corner arc instead, and reports the theme's outline as a
    /// stray colour inside the swatch.
    private struct Drawn {
        let rep: NSBitmapImageRep
        let scale: CGFloat
        /// The swatch's own rows, in rep pixels and counted from the top the way `colorAt` does.
        /// The view may be taller than the swatch when it carries a caption.
        let pair: (x: Range<Int>, y: Range<Int>)

        /// The swatch's own centre line.
        var midY: Int { (pair.y.lowerBound + pair.y.upperBound) / 2 }

        /// A point measured from the swatch's leading edge rather than the view's.
        func x(_ offset: CGFloat) -> Int { pair.x.lowerBound + Int(offset * scale) }

        /// Its top and bottom rows, where the theme's outline is.
        var edgeRows: [Int] { [pair.y.lowerBound, pair.y.upperBound - 1] }

        /// The flat middle of those rows, clear of both corner arcs.
        var flatColumns: Range<Int> {
            let third = pair.x.count / 3
            return (pair.x.lowerBound + third)..<(pair.x.upperBound - third)
        }
    }

    private func pixels(of view: ColorPairSpecimenView) throws -> Drawn {
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        let pair = view.pairRect
        return Drawn(
            rep: rep,
            scale: scale,
            pair: (
                x: Int(pair.minX * scale)..<Int(pair.maxX * scale),
                // Unflipped view, top-down bitmap: the swatch sits on the view's bottom edge.
                y: Int((view.bounds.height - pair.maxY) * scale)..<Int(
                    (view.bounds.height - pair.minY) * scale
                )
            )
        )
    }

    /// Sampled in sRGB, since the pair being compared was reduced to sRGB bytes by the renderer
    /// before it ever reached the app.
    private func color(_ drawn: Drawn, x: Int, y: Int) throws -> NSColor {
        try XCTUnwrap(XCTUnwrap(drawn.rep.colorAt(x: x, y: y)).usingColorSpace(.sRGB))
    }

    /// Every pixel the two fills own outright: inside the corner arcs, and clear of the stroke
    /// along the flat edges.
    private func interior(of drawn: Drawn, from leadingEdge: CGFloat = 0) -> [(x: Int, y: Int)] {
        let size = NSSize(
            width: ColorPairSpecimenDefaults.inkWidth + ColorPairSpecimenDefaults.groundWidth,
            height: ColorPairSpecimenDefaults.height
        )
        let radius = Design.Radius.control(fitting: size)
        let border = Design.Radius.controlBorder
        let xInset = Int(((radius + border + 1) * drawn.scale).rounded(.up))
        let yInset = Int(((border + 1) * drawn.scale).rounded(.up))
        let start = max(
            drawn.pair.x.lowerBound + xInset,
            drawn.x(leadingEdge + border + 1)
        )

        return (start..<(drawn.pair.x.upperBound - xInset)).flatMap { x in
            ((drawn.pair.y.lowerBound + yInset)..<(drawn.pair.y.upperBound - yInset))
                .map { (x: x, y: $0) }
        }
    }

    /// The flat middle of the swatch's top and bottom edges, which is where the theme's own
    /// outline is and where none of the reported colours are.
    private func edgeColors(of drawn: Drawn) throws -> [String] {
        try drawn.flatColumns.flatMap { x in
            try drawn.edgeRows.map { try color(drawn, x: x, y: $0).hexString }
        }
    }

    private func distance(_ first: NSColor, _ second: NSColor) -> CGFloat {
        abs(first.redComponent - second.redComponent)
            + abs(first.greenComponent - second.greenComponent)
            + abs(first.blueComponent - second.blueComponent)
    }

    // MARK: - The Pair

    func testItStatesItsOwnSizeRatherThanTakingWhateverARowHasLeft() {
        let view = specimen()

        XCTAssertEqual(
            view.intrinsicContentSize,
            NSSize(
                width: ColorPairSpecimenDefaults.inkWidth + ColorPairSpecimenDefaults.groundWidth,
                height: ColorPairSpecimenDefaults.height
            )
        )
        XCTAssertEqual(view.contentHuggingPriority(for: .horizontal), .required)
        XCTAssertEqual(view.contentCompressionResistancePriority(for: .horizontal), .required)
    }

    /// A swatch is furniture of a different order from a button, and has to be sized like it.
    /// At 22pt beside a ~30pt control it read as a control that had come out slightly wrong; the
    /// swatch is a mark's height, well clear of anything that invites a click.
    func testTheSwatchIsNowhereNearTheHeightOfTheControlsBesideIt() {
        let button = ThemedButton(title: "Change Theme…", target: nil, action: nil)

        XCTAssertLessThan(
            ColorPairSpecimenDefaults.height,
            button.intrinsicContentSize.height * 0.7,
            "the swatch is close enough to the button's height to read as a failed control"
        )
    }

    /// The case the component exists for draws nothing at all, so the two words above it are what
    /// separate "a sample, and it is blank" from "an empty box in a row of controls".
    func testACaptionedSwatchNamesItselfAboveTheColoursAndKeepsItsSwatchSize() throws {
        let captioned = specimen(caption: "As drawn")

        XCTAssertGreaterThan(
            captioned.intrinsicContentSize.height,
            ColorPairSpecimenDefaults.height,
            "the caption took no room, so it is drawn over the colours it names"
        )
        XCTAssertEqual(captioned.pairRect.height, ColorPairSpecimenDefaults.height)
        XCTAssertEqual(captioned.pairRect.minY, 0, "the swatch left the bottom of its own unit")

        // The colours are still the colours, drawn in the row the caption points at.
        let drawn = try pixels(of: captioned)
        XCTAssertLessThan(distance(try inkSample(of: drawn), Fixture.reportedInk), 0.05)
    }

    /// The two halves are the colours that were reported, not colours near them: a swatch that
    /// nudged either one would be evidence for a different complaint than the one being made.
    func testEachHalfDrawsTheExactColourItWasHanded() throws {
        let view = specimen(ink: Fixture.readableInk, ground: Fixture.readableGround)
        let drawn = try pixels(of: view)

        XCTAssertLessThan(distance(try inkSample(of: drawn), Fixture.readableInk), 0.05)
        // Just inside the ground half: past the split, before the centred glyphs, and nowhere
        // near the rounded corners the outline is drawn through.
        let groundSample = try color(
            drawn,
            x: drawn.x(ColorPairSpecimenDefaults.inkWidth + Design.Spacing.hairline),
            y: drawn.midY
        )
        XCTAssertLessThan(distance(groundSample, Fixture.readableGround), 0.05)
    }

    /// The middle of the ink half, which no glyph and no corner reaches.
    private func inkSample(of drawn: Drawn) throws -> NSColor {
        try color(drawn, x: drawn.x(ColorPairSpecimenDefaults.inkWidth / 2), y: drawn.midY)
    }

    /// The reported bug's own pair: `SGR 97` over System Light, where the ANSI bright white a
    /// program asked for and the background it landed on are the same white. Nothing inside the
    /// swatch may separate them — no divider, no shaded half, no outline drawn through the
    /// middle — because a swatch that made this pair legible would be evidence against the
    /// complaint it is illustrating.
    func testAPairThatCollapsedIntoOneFieldIsDrawnAsOneField() throws {
        let white = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        let view = specimen(ink: white, ground: white)
        let drawn = try pixels(of: view)

        // Inside the outline, so this measures the two fills and the glyphs over them, and
        // nothing the theme drew around them.
        var strayInk = 0
        for point in interior(of: drawn) where try distance(
            color(drawn, x: point.x, y: point.y),
            white
        ) > 0.02 {
            strayInk += 1
        }

        XCTAssertEqual(
            strayInk, 0,
            "the specimen separated a pair the terminal did not, so it reports a legible pair "
                + "for a run the reader could not read"
        )
    }

    /// The same rule for the pair that is nearly rather than exactly collapsed. The specimen may
    /// not exaggerate: nothing it draws is allowed to be further from the ground than the ink it
    /// was handed already is, which is what stops a helpful outline or shadow from turning 1.17:1
    /// into a picture of a pair that reads.
    func testTheSpecimenNeverSeparatesANearCollapsedPairMoreThanTheTerminalDid() throws {
        let view = specimen()
        let drawn = try pixels(of: view)
        let reported = distance(Fixture.reportedInk, Fixture.reportedGround)

        var worst: CGFloat = 0
        for point in interior(of: drawn) {
            worst = max(worst, try distance(
                color(drawn, x: point.x, y: point.y),
                Fixture.reportedGround
            ))
        }

        XCTAssertLessThanOrEqual(worst, reported + 0.01, "the swatch pulled the pair apart")
        XCTAssertGreaterThan(worst, 0, "the swatch drew one colour where it was handed two")
    }

    /// The same measurement from the other side: a pair with nothing wrong with it draws glyphs
    /// that are actually there, so a blank specimen means *this pair is blank* rather than *this
    /// component draws nothing*.
    func testAReadablePairDrawsReadableGlyphsOverItsGround() throws {
        let view = specimen(ink: Fixture.readableInk, ground: Fixture.readableGround)
        let drawn = try pixels(of: view)

        var inkPixels = 0
        for point in interior(of: drawn, from: ColorPairSpecimenDefaults.inkWidth) where try
            distance(color(drawn, x: point.x, y: point.y), Fixture.readableGround) > 0.3 {
            inkPixels += 1
        }

        XCTAssertGreaterThan(inkPixels, 8, "the ground half carries no specimen glyphs at all")
    }

    /// When the pair collapses, the outline is the only thing saying the swatch is there — so it
    /// is stroked outside the clip that the fills are drawn inside.
    func testTheOutlineSurvivesAPairThatMatchesEverythingAroundIt() throws {
        let view = specimen()
        let drawn = try pixels(of: view)

        var edgePixels = 0
        for x in drawn.flatColumns {
            for y in drawn.edgeRows where try distance(
                color(drawn, x: x, y: y),
                Fixture.reportedGround
            ) > 0.05 {
                edgePixels += 1
            }
        }

        XCTAssertGreaterThan(
            edgePixels, 4,
            "the swatch has no edge, so a pair matching the band around it is invisible twice"
        )
    }

    // MARK: - Theming

    /// The one asymmetry the component exists to hold: what it *reports* is a program's colour
    /// and never moves, while what it *chooses* is the theme's and follows a live switch.
    func testTheOutlineFollowsALiveThemeSwitchAndTheReportedPairDoesNot() throws {
        AppThemePalette.set(AppThemeStyles.cyberpunk)
        let before = Design.Surface.border.hexString
        let view = specimen()
        let firstEdge = try edgeColors(of: pixels(of: view))

        AppThemePalette.set(AppThemeStyles.swissMinimalist)
        NotificationCenter.default.post(
            AppThemeDidChange(themeID: AppThemeStyles.swissMinimalist.id)
        )
        XCTAssertNotEqual(
            before, Design.Surface.border.hexString,
            "both themes outline identically, so this fixture proves nothing"
        )

        let drawn = try pixels(of: view)
        XCTAssertNotEqual(
            firstEdge, try edgeColors(of: drawn),
            "a theme switch left the swatch outlined in the theme that has gone"
        )
        XCTAssertLessThan(
            distance(try inkSample(of: drawn), Fixture.reportedInk), 0.05,
            "the app theme repainted a colour that belongs to the program"
        )
    }

    // MARK: - Read Without Looking

    /// A colour is the one thing a swatch cannot say to somebody who is not looking at it, so
    /// the caller's sentence is the whole of what it reports.
    func testItIsNamedByWhatTheColoursAre() {
        let view = specimen()

        XCTAssertTrue(view.isAccessibilityElement())
        XCTAssertEqual(view.accessibilityRole(), .image)
        XCTAssertEqual(view.accessibilityLabel(), Fixture.label)
        XCTAssertEqual(view.accessibilityIdentifier(), ColorPairSpecimenDefaults.identifier)
    }

    func testRepointingItAtANewFindingReplacesBothTheColoursAndTheirName() throws {
        let view = specimen()

        view.setPair(
            ink: Fixture.readableInk,
            ground: Fixture.readableGround,
            accessibilityLabel: "Text color #FFFFFF shown on background color #000000"
        )

        XCTAssertEqual(view.inkColor, Fixture.readableInk)
        XCTAssertEqual(view.groundColor, Fixture.readableGround)
        XCTAssertEqual(
            view.accessibilityLabel(),
            "Text color #FFFFFF shown on background color #000000"
        )

        // The next draw is the point of the call, and a stored colour that never reached one
        // would satisfy every assertion above.
        XCTAssertLessThan(
            distance(try inkSample(of: pixels(of: view)), Fixture.readableInk),
            0.05
        )
    }

    func testItIsBuiltEntirelyFromTheDesignSystem() {
        XCTAssertEqual(ThemeBoundaryAudit.violations(in: specimen()), [])
    }
}

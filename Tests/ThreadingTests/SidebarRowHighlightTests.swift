import AppKit
import XCTest
@testable import Threading

/// Hover and selection are two strengths of one affordance in the sidebar, so they have to be
/// one *shape*.
///
/// They were not. Both filled the same rectangle — the row inset by
/// `hoverHighlightInsetX`/`Y` — but hover rounded it by a fixed 5 while selection rounded it by
/// the theme's `controlRadius`. Under the themes those numbers were written against the two
/// agreed closely enough to pass for one silhouette; under Bauhaus, Swiss Minimalist,
/// Neo-Brutalism and Newsprint, whose controls are square by design, the hovered row came out
/// rounded and the selected row directly beneath it came out a hard-edged block of accent.
///
/// Asserted from pixels rather than from the property the two now share, because sharing it is
/// the fix and not the guarantee: what matters is that `drawBackground` and `drawSelection`
/// both paint through it. Read the way the bug was read off the screenshot that reported it —
/// how wide the fill is on its *first* scanline against how wide it is across the middle. A
/// square corner is the same width on both; any corner at all is narrower at the top. That
/// measures the rounding itself rather than sampling near it, which is what a fixed probe
/// point did badly: at two points in, a radius of 5 and a radius of 0 look alike.
@MainActor
final class SidebarRowHighlightTests: XCTestCase {

    // MARK: - Fixture

    private enum Fixture {
        static let width: CGFloat = 240
        static let height: CGFloat = 28

        /// Mid-grey, so the 6% hover wash is visible against it whichever way the theme's
        /// label colour leans — a light wash vanishes on white and a dark one on black.
        static let ground = NSColor(white: 0.5, alpha: 1)
    }

    private enum Highlight: CustomStringConvertible {
        case none
        case hovered
        case selected

        var description: String {
            switch self {
            case .none: return "an unhighlighted row"
            case .hovered: return "hover"
            case .selected: return "selection"
            }
        }
    }

    // MARK: - Tests

    /// A square-cornered theme squares *both* fills. This is the reported bug.
    func testASquareThemeDrawsHoverAndSelectionWithTheSameSquareCorner() throws {
        let theme = try squareTheme()

        try withTheme(theme) {
            for state in [Highlight.hovered, .selected] {
                let shape = try silhouette(of: state)
                XCTAssertEqual(
                    shape.top,
                    shape.middle,
                    "\(theme.name) has square controls, so \(state) should not taper at all"
                )
            }
        }
    }

    /// And a rounded theme rounds both, so the rule is "follow the theme", not "always square".
    func testARoundThemeDrawsHoverAndSelectionWithTheSameRoundedCorner() throws {
        let theme = try roundTheme()

        try withTheme(theme) {
            for state in [Highlight.hovered, .selected] {
                let shape = try silhouette(of: state)
                XCTAssertGreaterThan(
                    shape.top.lowerBound,
                    shape.middle.lowerBound,
                    "\(theme.name) rounds its controls, so \(state) should cut its top corner"
                )
                XCTAssertLessThan(
                    shape.top.upperBound,
                    shape.middle.upperBound,
                    "\(theme.name) rounds its controls, so \(state) should cut both top corners"
                )
            }
        }
    }

    /// The invariant the other two are instances of, swept across the whole stock library so
    /// no future style can reintroduce the split by picking a radius nobody tested against:
    /// under any theme, whatever shape the sidebar highlight takes, hover and selection take
    /// the *same* one.
    ///
    /// **System included.** It used to be excluded because the row handed selection back to
    /// AppKit there, which gave the two shapes different authors; the row draws both under
    /// every theme now, so the invariant covers the theme most people run.
    func testHoverAndSelectionShareOneSilhouetteUnderEveryStockTheme() throws {
        let themes = AppThemeLibrary.stock
        XCTAssertFalse(themes.isEmpty, "Fixture premise: there are stock themes to sweep")

        for theme in themes {
            try withTheme(theme) {
                let hovered = try silhouette(of: .hovered)
                let selected = try silhouette(of: .selected)

                XCTAssertEqual(
                    hovered.middle,
                    selected.middle,
                    "\(theme.name) should hover and select across the same width"
                )
                assertCorner(
                    hovered.top,
                    matches: selected.top,
                    "\(theme.name) should hover and select with the same corner"
                )
            }
        }
    }

    /// Both fills cover the same rectangle, which is the half of "one silhouette" the taper
    /// cannot see. Read across the row's middle, where every theme's fill is full width.
    func testHoverAndSelectionFillTheSameRectangle() throws {
        try withTheme(try squareTheme()) {
            let hovered = try silhouette(of: .hovered).middle
            let selected = try silhouette(of: .selected).middle

            XCTAssertEqual(
                hovered,
                selected,
                "Hover and selection should cover the same width"
            )
            XCTAssertEqual(
                hovered.lowerBound,
                Int(SidebarRowDefaults.hoverHighlightInsetX),
                "Both should start at the shared inset"
            )
            XCTAssertEqual(
                hovered.upperBound,
                Int(Fixture.width - SidebarRowDefaults.hoverHighlightInsetX) - 1,
                "Both should end at the shared inset"
            )
        }
    }

    /// And the rectangle closes on the column's edges as the divider narrows it.
    ///
    /// The capsule is the outermost thing the list draws, so ten points of ground between a
    /// selected row and the seam beside it is the gap a narrow sidebar can least afford. Read
    /// under **System**, which is where this could not be done at all while AppKit owned the
    /// shape: it hangs its own selection view at a fixed inset whatever the divider does.
    func testTheHighlightClosesOnTheColumnAsItNarrows() throws {
        try withTheme(.system) {
            let tight = SidebarDensity(width: SidebarDefaults.tightDensityWidth)
            XCTAssertLessThan(
                tight.selectionInsetX,
                SidebarRowDefaults.hoverHighlightInsetX,
                "Fixture premise: the tight end of the band is a closer capsule"
            )

            for state in [Highlight.hovered, .selected] {
                let relaxed = try silhouette(of: state).middle
                let narrow = try silhouette(of: state, density: tight).middle

                XCTAssertEqual(narrow.lowerBound, Int(tight.selectionInsetX))
                XCTAssertEqual(
                    narrow.upperBound,
                    Int(Fixture.width - tight.selectionInsetX) - 1,
                    "\(state) should reach further out at the narrowest column"
                )
                XCTAssertLessThan(narrow.lowerBound, relaxed.lowerBound)
                XCTAssertGreaterThan(narrow.upperBound, relaxed.upperBound)
            }
        }
    }

    // MARK: - The Selected Row's Activity Beam

    /// The ring is pinned to the very silhouette hover and selection fill — the row inset by
    /// the highlight insets — so it reads as the selection itself working rather than as a
    /// third shape with its own opinion of the row's edge.
    func testTheActivityBeamRingsTheSelectionSilhouette() throws {
        AppThemePalette.set(.system)
        defer { AppThemePalette.set(.system) }

        let row = SidebarHoverRowView(
            frame: NSRect(x: 0, y: 0, width: Fixture.width, height: Fixture.height)
        )
        row.setActivityBeam(workload: AgentWorkload(workingCount: 1, anyAtTopEffort: false))

        let beam = try XCTUnwrap(
            row.activityBeamForTesting,
            "a working workload should mount the row's ring"
        )
        row.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            beam.frame,
            row.bounds.insetBy(
                dx: SidebarRowDefaults.hoverHighlightInsetX,
                dy: SidebarRowDefaults.hoverHighlightInsetY
            ),
            "the ring should take the selection capsule's own silhouette"
        )
        XCTAssertEqual(beam.appliedActiveForTesting, true)
    }

    /// And it follows the capsule when the column narrows it, rather than staying at the edge
    /// the row was born with — a ring tracing a shape that has moved is the one artefact this
    /// pinning exists to prevent.
    func testTheActivityBeamFollowsACapsuleThatNarrows() throws {
        AppThemePalette.set(.system)
        defer { AppThemePalette.set(.system) }

        let row = SidebarHoverRowView(
            frame: NSRect(x: 0, y: 0, width: Fixture.width, height: Fixture.height)
        )
        row.setActivityBeam(workload: AgentWorkload(workingCount: 1, anyAtTopEffort: false))
        let beam = try XCTUnwrap(row.activityBeamForTesting)

        let tight = SidebarDensity(width: SidebarDefaults.tightDensityWidth)
        row.applySidebarDensity(tight)
        row.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            beam.frame,
            row.bounds.insetBy(
                dx: tight.selectionInsetX,
                dy: SidebarRowDefaults.hoverHighlightInsetY
            )
        )
    }

    /// Almost every row is never the selected working one, and telling those rows so must stay
    /// free: no host is mounted for a `.none` restatement.
    func testAnIdleRestatementMountsNoBeamHost() {
        let row = SidebarHoverRowView()
        row.setActivityBeam(workload: .none)
        XCTAssertNil(row.activityBeamForTesting)
    }

    /// The beam moving to another row fades this one's ring out rather than leaving two lit.
    func testClearingTheBeamDeactivatesTheMountedRing() {
        AppThemePalette.set(.system)
        defer { AppThemePalette.set(.system) }

        let row = SidebarHoverRowView(
            frame: NSRect(x: 0, y: 0, width: Fixture.width, height: Fixture.height)
        )
        row.setActivityBeam(workload: AgentWorkload(workingCount: 1, anyAtTopEffort: false))
        row.setActivityBeam(workload: .none)
        XCTAssertEqual(row.activityBeamForTesting?.appliedActiveForTesting, false)
    }

    // MARK: - Comparison

    /// Compares two corners to within a point, which is as exact as a *curved* edge can be
    /// compared across two fill strengths.
    ///
    /// The straight edges are asserted exactly — they land on pixel boundaries, so both states
    /// cover the same pixels completely. A curve does not: it leaves partly covered pixels, and
    /// the bitmap stores them gamma-encoded, so the coverage that reads as half of a solid
    /// accent is not quite the coverage that reads as half of a 6% wash. One point of
    /// disagreement is that encoding, not two shapes; ten would be a radius.
    private func assertCorner(
        _ corner: ClosedRange<Int>,
        matches expected: ClosedRange<Int>,
        _ message: String
    ) {
        XCTAssertEqual(
            Double(corner.lowerBound), Double(expected.lowerBound), accuracy: 1, message
        )
        XCTAssertEqual(
            Double(corner.upperBound), Double(expected.upperBound), accuracy: 1, message
        )
    }

    // MARK: - Probes

    /// How wide the fill is on its first scanline against how wide it is across the middle.
    ///
    /// The pair is the shape: equal means a square corner, narrower-at-the-top means a rounded
    /// one, and how much narrower is the radius. Rendered once per state and read twice, so
    /// the two numbers cannot come from two different draws.
    private func silhouette(
        of state: Highlight,
        density: SidebarDensity = .relaxed
    ) throws -> (top: ClosedRange<Int>, middle: ClosedRange<Int>) {
        let plain = try render(.none, density: density)
        let highlighted = try render(state, density: density)
        let scale = CGFloat(plain.pixelsWide) / Fixture.width
        let middle = plain.pixelsHigh / 2

        // The fill's own first row, not the row's: it starts `hoverHighlightInsetY` down.
        let top = Int(SidebarRowDefaults.hoverHighlightInsetY * scale)

        // What this state's ink is worth where it is unambiguously solid, so the edge below
        // can be read as a fraction of it rather than against an absolute that suits one
        // state and not the other.
        let solid = try delta(highlighted, plain, plain.pixelsWide / 2, middle)
        XCTAssertGreaterThan(solid, 0.02, "\(state) should be visible at all to be measured")

        return (
            try span(highlighted, over: plain, scanline: top, solid: solid, scale: scale, state),
            try span(highlighted, over: plain, scanline: middle, solid: solid, scale: scale, state)
        )
    }

    /// The horizontal extent of one scanline of fill, in points.
    ///
    /// Compared against an otherwise identical unhighlighted render, so "filled" means "this
    /// state added ink here" — no theme colour, appearance resolution or backing scale enters
    /// the answer.
    ///
    /// The edge is taken at half of `solid` rather than at a fixed threshold, because the two
    /// states paint in wildly different strengths: a hover fill is a 6% wash, whose half-covered
    /// antialiased pixel is a *thousandth* of the ground, while the same pixel of a solid accent
    /// is unmissable. Against one absolute the two shapes measured a point apart along any
    /// curved edge — same path, same draw, different fringe. As a fraction they do not, because
    /// half coverage is half coverage in either strength.
    private func span(
        _ highlighted: NSBitmapImageRep,
        over plain: NSBitmapImageRep,
        scanline: Int,
        solid: CGFloat,
        scale: CGFloat,
        _ state: Highlight
    ) throws -> ClosedRange<Int> {
        let filled = try (0..<plain.pixelsWide)
            .filter { try delta(highlighted, plain, $0, scanline) > solid / 2 }
            .map { Int(CGFloat($0) / scale) }

        let first = try XCTUnwrap(filled.first, "\(state) drew nothing on scanline \(scanline)")
        let last = try XCTUnwrap(filled.last, "\(state) drew nothing on scanline \(scanline)")
        return first...last
    }

    /// How far one pixel moved between the two renders. A change of any colour counts: this
    /// cannot key off the fill's hue, only off the fact that the state put something there.
    private func delta(
        _ lhs: NSBitmapImageRep,
        _ rhs: NSBitmapImageRep,
        _ x: Int,
        _ y: Int
    ) throws -> CGFloat {
        let left = try XCTUnwrap(lhs.colorAt(x: x, y: y), "No pixel at \(x),\(y)")
        let right = try XCTUnwrap(rhs.colorAt(x: x, y: y), "No pixel at \(x),\(y)")

        return abs(left.redComponent - right.redComponent)
            + abs(left.greenComponent - right.greenComponent)
            + abs(left.blueComponent - right.blueComponent)
    }

    // MARK: - Harness

    /// Draws the row view alone — no outline view, no session content — so what lands in the
    /// bitmap is the highlight and the ground under it and nothing else.
    private func render(
        _ state: Highlight,
        density: SidebarDensity = .relaxed
    ) throws -> NSBitmapImageRep {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: Fixture.width, height: Fixture.height))
        let row = SidebarHoverRowView(frame: host.bounds)
        row.applySidebarDensity(density)
        host.addSubview(row)

        switch state {
        case .none:
            break
        case .hovered:
            row.mouseEntered(with: try XCTUnwrap(Self.enterEvent(), "Failed to fake a hover"))
        case .selected:
            row.isSelected = true
            row.isEmphasized = true
        }

        host.wantsLayer = true
        host.layer?.backgroundColor = Fixture.ground.cgColor
        host.layoutSubtreeIfNeeded()

        let rep = try XCTUnwrap(
            host.bitmapImageRepForCachingDisplay(in: host.bounds),
            "Failed to build a bitmap for the row"
        )
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// The row reads nothing off the event — `mouseEntered` only records the hover — so a
    /// synthesized one reaches the hovered state without a pointer or test-only API.
    private static func enterEvent() -> NSEvent? {
        NSEvent.enterExitEvent(
            with: .mouseEntered,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            trackingNumber: 0,
            userData: nil
        )
    }

    /// Picked by material rather than by name: the point is the *shape* a theme asks for, and
    /// naming one here would make a renamed or retired style look like a highlight bug.
    private func squareTheme() throws -> AppTheme {
        try XCTUnwrap(
            AppThemeLibrary.stock.first { !$0.isSystem && $0.material.controlRadius == 0 },
            "Expected at least one stock theme with square controls"
        )
    }

    /// The roundest stock theme, so the taper it should produce is unmistakable rather than
    /// one antialiased pixel. Never System, which states no control corner of its own — its
    /// capsule takes the one AppKit rounds a source-list selection by, and a theme picked for
    /// having the broadest authored corner cannot be the one that authors none.
    private func roundTheme() throws -> AppTheme {
        try XCTUnwrap(
            AppThemeLibrary.stock
                .filter { !$0.isSystem }
                .max(by: { $0.material.controlRadius < $1.material.controlRadius }),
            "Expected at least one stock theme with rounded controls"
        )
    }

    /// `apply` is what the app itself calls, and it sets both halves of the state the row
    /// reads: `AppThemeLibrary.current`, which decides whether the row draws its own selection
    /// at all, and `AppThemePalette.current`, which carries the material the corner comes from.
    private func withTheme(_ theme: AppTheme, _ body: () throws -> Void) rethrows {
        let previous = AppThemeLibrary.current
        defer { AppThemeLibrary.apply(previous) }

        AppThemeLibrary.apply(theme)
        try body()
    }
}

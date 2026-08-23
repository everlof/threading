import AppKit
import XCTest
@testable import Threading

/// Every word the chrome writes can be read on the ground it is written on.
///
/// The bug: `Design.Text`'s tiers stated quietness and never stated legibility. Under **System**,
/// dark, `quaternary` is white at 10% — an attachments row's timestamp drew at **1.34:1** over the
/// panel, and at **1.20:1** once the row was selected. Both numbers were read off rendered pixels,
/// and neither was reachable from any assertion in the suite, because the four contrast gates the
/// app already had were each looking somewhere else (see `LabelLegibility`).
///
/// So the sweep is the point of this file, exactly as it is in `SelectionSurfaceTests`: every
/// stock theme, in every appearance it ships, at both contrast settings. The failure was never a
/// call site being careless — it was a vocabulary nobody had ever measured.
@MainActor
final class LabelLegibilityTests: XCTestCase {

    override func tearDown() {
        Design.Accessibility.increaseContrastOverrideForTesting = nil
        LabelLegibility.forgetCachedTiersForTesting()
        super.tearDown()
    }

    // MARK: - Helpers

    /// The tiers this rule covers, each with the floor it is held to and the name a failure
    /// should print. `label` is deliberately absent — see `Design.Text.label`.
    private var tiers: [(name: String, colour: () -> NSColor, floor: CGFloat)] {
        [
            ("secondary", { Design.Text.secondary }, LabelLegibility.Defaults.readingRatio),
            ("tertiary", { Design.Text.tertiary }, LabelLegibility.Defaults.readingRatio),
            ("quaternary", { Design.Text.quaternary }, LabelLegibility.Defaults.glanceRatio)
        ]
    }

    private func appearances(for theme: AppTheme) throws -> [NSAppearance] {
        if theme.isAdaptive {
            return [
                try XCTUnwrap(NSAppearance(named: .aqua)),
                try XCTUnwrap(NSAppearance(named: .darkAqua))
            ]
        }
        return [try XCTUnwrap(theme.mode.appearance)]
    }

    /// Every stock theme paired with every appearance it ships — **System included**, unlike the
    /// selection sweep next door: a label tier is drawn under System exactly as it is under a
    /// styled theme, and System is where the worst of these numbers was measured.
    private func themesAndAppearances() throws -> [(AppTheme, NSAppearance)] {
        try AppThemeLibrary.stock.flatMap { theme in
            try appearances(for: theme).map { (theme, $0) }
        }
    }

    private func withTheme(
        _ theme: AppTheme,
        under appearance: NSAppearance,
        _ body: () -> Void
    ) {
        let previous = AppThemePalette.current
        defer {
            AppThemePalette.set(previous)
            LabelLegibility.forgetCachedTiersForTesting()
        }
        AppThemePalette.set(theme)
        LabelLegibility.forgetCachedTiersForTesting()
        appearance.performAsCurrentDrawingAppearance(body)
    }

    /// What a tier actually looks like once it has been laid on a ground, which is the whole
    /// arithmetic the old gates skipped: `ThemeContrast.ratio` reads sRGB components and ignores
    /// alpha, so a tier has to be composited before it can be measured at all.
    private func ratio(_ ink: NSColor, on ground: NSColor) -> CGFloat {
        ThemeContrast.ratio(ink.composited(over: ground), ground)
    }

    // MARK: - The sweep

    /// The claim, over the whole catalogue: no tier is written on a ground it cannot be read on.
    func testEveryStockThemeLeavesEveryLabelTierReadableOnEveryGroundItLandsOn() throws {
        for (theme, appearance) in try themesAndAppearances() {
            withTheme(theme, under: appearance) {
                for ground in LabelLegibility.chromeGrounds {
                    for tier in tiers {
                        let measured = ratio(tier.colour(), on: ground)
                        XCTAssertGreaterThanOrEqual(
                            measured,
                            tier.floor - 0.01,
                            "\(theme.name) [\(appearance.name.rawValue)]: \(tier.name) reads at "
                                + "\(String(format: "%.2f", measured)):1 on "
                                + "\(ground.hexString), below its \(tier.floor):1 floor"
                        )
                    }
                }
            }
        }
    }

    /// The exact defect, pinned as a number rather than as a policy.
    ///
    /// System, dark, `quaternary` over the panel — the timestamp and the origin mark in an
    /// attachments row. It measured 1.34:1 in the screenshot that opened this, which is text and
    /// ground within a third of a stop of each other.
    func testTheReportedTimestampTierIsNoLongerInvisibleOnASystemDarkPanel() throws {
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        withTheme(.system, under: dark) {
            let panel = Design.Surface.panel.composited(over: Design.Surface.ground)
            let measured = ratio(Design.Text.quaternary, on: panel)

            XCTAssertGreaterThanOrEqual(
                measured,
                LabelLegibility.Defaults.glanceRatio - 0.01,
                "the tier a row's timestamp is set in reads at "
                    + "\(String(format: "%.2f", measured)):1"
            )
            // The old value, kept as the thing this must never fall back to: anything near 1:1 is
            // not low contrast, it is the same colour twice.
            XCTAssertGreaterThan(measured, 2, "quaternary is back where it started")
        }
    }

    /// The ladder is still a ladder. A floor applied per tier could have raised a quiet tier past
    /// a louder one, which would have made the vocabulary worse rather than only flatter.
    func testNoTierIsEverRaisedPastTheTierAboveIt() throws {
        for (theme, appearance) in try themesAndAppearances() {
            withTheme(theme, under: appearance) {
                for ground in LabelLegibility.chromeGrounds {
                    let ladder = [
                        ("label", Design.Text.label),
                        ("secondary", Design.Text.secondary),
                        ("tertiary", Design.Text.tertiary),
                        ("quaternary", Design.Text.quaternary)
                    ].map { ($0.0, ratio($0.1, on: ground)) }

                    for (louder, quieter) in zip(ladder, ladder.dropFirst()) {
                        XCTAssertGreaterThanOrEqual(
                            louder.1, quieter.1 - 0.01,
                            "\(theme.name) [\(appearance.name.rawValue)]: \(quieter.0) "
                                + "(\(String(format: "%.2f", quieter.1)):1) is louder than "
                                + "\(louder.0) (\(String(format: "%.2f", louder.1)):1)"
                        )
                    }
                }
            }
        }
    }

    // MARK: - Only as far as it must

    /// A tier that already reads is handed back **identically** — not re-derived, not rounded, not
    /// nudged. This is what keeps the rule from restyling a palette that was authored with care,
    /// and it is the same promise `SelectionSurface.quiet` and `NSColor.legible(on:)` make.
    func testATierThatAlreadyReadsIsLeftExactlyAsAuthored() {
        let ground = NSColor.black
        let comfortable = NSColor.white.withAlphaComponent(0.9)

        XCTAssertEqual(
            LabelLegibility.held(
                comfortable,
                at: LabelLegibility.Defaults.readingRatio,
                over: [ground],
                ceiling: 1
            ),
            comfortable,
            "a tier that already reads was second-guessed"
        )
    }

    /// And a tier that does not read gives back *as little* transparency as the floor requires —
    /// the claim that keeps "make it legible" from meaning "make it the label colour".
    func testAFailingTierIsRaisedToItsFloorAndNoFurther() throws {
        let ground = NSColor.black
        let floor = LabelLegibility.Defaults.glanceRatio
        let faint = NSColor.white.withAlphaComponent(0.1)

        let held = try XCTUnwrap(
            LabelLegibility.held(faint, at: floor, over: [ground], ceiling: 1)
                .usingColorSpace(.sRGB)
        )

        XCTAssertGreaterThanOrEqual(ratio(held, on: ground), floor - 0.01)
        XCTAssertGreaterThan(held.alphaComponent, 0.1, "the tier was not raised at all")
        // One step of the walk past the floor, at most: `strengthSteps` divides the range it can
        // travel, so the answer sits within one of those steps of the boundary.
        let step = (1 - 0.1) / CGFloat(LabelLegibility.Defaults.strengthSteps)
        let bare = NSColor.white.withAlphaComponent(held.alphaComponent - step - 0.001)
        XCTAssertLessThan(
            ratio(bare, on: ground), floor,
            "the tier was raised well past the floor it had to clear"
        )
    }

    /// The ceiling holds even when the floor cannot be reached under it: a tier may end up as
    /// quiet as the tier above it, and never louder.
    func testATierIsNeverRaisedPastItsCeiling() throws {
        let ground = NSColor(white: 0.5, alpha: 1)
        let held = try XCTUnwrap(
            LabelLegibility.held(
                NSColor.white.withAlphaComponent(0.05),
                at: LabelLegibility.Defaults.readingRatio,
                over: [ground],
                ceiling: 0.4
            ).usingColorSpace(.sRGB)
        )

        // Either it found a strength under the ceiling, or the ink cannot read on this ground at
        // any strength and the lightness fallback answered instead. Both are allowed; overshooting
        // the ceiling with the *same* ink is not. (`whiteComponent` is unavailable on an sRGB
        // colour and raises rather than converting, so the ink is identified by its channels.)
        let unchangedInk = held.redComponent >= 0.99
            && held.greenComponent >= 0.99
            && held.blueComponent >= 0.99
        if unchangedInk {
            XCTAssertLessThanOrEqual(held.alphaComponent, 0.4 + 0.001)
        }
    }

    // MARK: - Increase Contrast

    /// Contrast asked for is contrast given: the quiet tier stops being glanced at and is held to
    /// the reading floor like everything else.
    func testIncreaseContrastHoldsTheQuietestTierToTheReadingFloor() throws {
        Design.Accessibility.increaseContrastOverrideForTesting = true
        defer { Design.Accessibility.increaseContrastOverrideForTesting = nil }

        for (theme, appearance) in try themesAndAppearances() {
            withTheme(theme, under: appearance) {
                for ground in LabelLegibility.chromeGrounds {
                    let measured = ratio(Design.Text.quaternary, on: ground)
                    XCTAssertGreaterThanOrEqual(
                        measured,
                        LabelLegibility.Defaults.readingRatio - 0.01,
                        "\(theme.name) [\(appearance.name.rawValue)]: quaternary reads at "
                            + "\(String(format: "%.2f", measured)):1 with Increase Contrast on"
                    )
                }
            }
        }
    }

    // MARK: - Ink on a ground the theme does not own

    /// `Design.Text.on(_:)` was four constants chosen against no particular ground, in the one
    /// function whose entire purpose is that the ground is not known in advance.
    ///
    /// Its most-used answer is `Design.Ink.selection`, and white at 28% over the system's selected
    /// blue is 1.71:1 — which is how the pane's timestamps got *worse* when the row was clicked.
    func testTheInkForAnArbitraryGroundHoldsTheSameFloors() throws {
        let grounds: [NSColor] = [
            .white,
            .black,
            NSColor(srgbRed: 0, green: 0.35, blue: 0.82, alpha: 1),   // the system's selection
            NSColor(white: 0.5, alpha: 1),                            // the hardest case there is
            NSColor(srgbRed: 0.94, green: 0.90, blue: 0.83, alpha: 1) // a warm paper ground
        ]

        for ground in grounds {
            let ink = Design.Text.on(ground)
            let rungs: [(String, NSColor, CGFloat)] = [
                ("label", ink.label, LabelLegibility.Defaults.readingRatio),
                ("secondary", ink.secondary, LabelLegibility.Defaults.readingRatio),
                ("tertiary", ink.tertiary, LabelLegibility.Defaults.readingRatio),
                ("quaternary", ink.quaternary, LabelLegibility.Defaults.glanceRatio)
            ]
            for (name, colour, floor) in rungs {
                let measured = ratio(colour, on: ground)
                XCTAssertGreaterThanOrEqual(
                    measured, floor - 0.01,
                    "ink on \(ground.hexString): \(name) reads at "
                        + "\(String(format: "%.2f", measured)):1"
                )
            }
        }
    }

    /// And the same claim through the token a selected row's contents actually reach for.
    func testTheSelectionsOwnInkReadsOnTheSelectionsOwnFill() throws {
        for (theme, appearance) in try themesAndAppearances() {
            withTheme(theme, under: appearance) {
                let fill = Design.Surface.selectionFill.composited(over: Design.Surface.ground)
                let ink = Design.Ink.selection

                XCTAssertGreaterThanOrEqual(
                    ratio(ink.quaternary, on: fill),
                    LabelLegibility.Defaults.glanceRatio - 0.01,
                    "\(theme.name) [\(appearance.name.rawValue)]: a selected row's quietest words "
                        + "read at \(String(format: "%.2f", ratio(ink.quaternary, on: fill))):1"
                )
            }
        }
    }

    // MARK: - The row that knows what it painted

    /// `ThemedTableRowView.contentInk` is the seam this closes: a cell cannot work out which of
    /// four worlds it is in — System's own fill, a theme's accent, a fill held back until the
    /// chrome's ink reads, or no fill at all — and only the row knows.
    func testASelectedRowsInkIsMeasuredAgainstWhateverThatRowPainted() throws {
        for (theme, appearance) in try themesAndAppearances() {
            withTheme(theme, under: appearance) {
                let table = ThemedTableView()
                let row = ThemedTableRowView()
                table.addSubview(row)

                row.isSelected = false
                XCTAssertEqual(
                    row.contentInk.quaternary, Design.Ink.chrome.quaternary,
                    "\(theme.name): an unselected row handed out something other than chrome ink"
                )

                row.isSelected = true
                row.isEmphasized = true
                // The row's own answer, not a recomputation of it. `isEmphasized` is not simply
                // what it was set to — `ListSelectionStrength` may demote it — so a fixture that
                // rebuilt the fill by hand measured ink against a ground the row never painted,
                // and reported a failure the code did not have.
                guard let ground = row.selectionGround else {
                    return XCTFail("\(theme.name): a selected row reported no ground")
                }
                let measured = ratio(row.contentInk.quaternary, on: ground)

                XCTAssertGreaterThanOrEqual(
                    measured,
                    LabelLegibility.Defaults.glanceRatio - 0.01,
                    "\(theme.name) [\(appearance.name.rawValue)]: a selected row's quietest words "
                        + "read at \(String(format: "%.2f", measured)):1 on what it painted"
                )
            }
        }
    }
}

import XCTest
@testable import Threading

/// `Design.Diff.on(_:)` derives a diff's washes and markers from the ground they land on, and it
/// lands on three quite different grounds: the app theme's panel in Git Review, the terminal
/// palette's background in a conversation, and a status card's own fill. Nothing pinned any of
/// that, so these do — a derivation that is wrong on one ground and right on another is exactly
/// the failure it was written to prevent, and the only failure a single-ground check cannot see.
@MainActor
final class DiffInkTests: XCTestCase {

    override func tearDown() {
        Design.Accessibility.increaseContrastOverrideForTesting = nil
        AppThemeLibrary.apply(.system)
        AppThemePalette.set(.system)
        super.tearDown()
    }

    /// Grounds spanning the range the derivation actually meets: near-black, paper, mid-tone,
    /// and strongly tinted in both temperatures.
    private let grounds: [(String, NSColor)] = [
        ("near-black", NSColor(srgbRed: 0.07, green: 0.07, blue: 0.08, alpha: 1)),
        ("terminal fir", NSColor(srgbRed: 0.03, green: 0.13, blue: 0.10, alpha: 1)),
        ("panel fir", NSColor(srgbRed: 0.07, green: 0.20, blue: 0.16, alpha: 1)),
        ("mid slate", NSColor(srgbRed: 0.36, green: 0.40, blue: 0.44, alpha: 1)),
        ("warm paper", NSColor(srgbRed: 0.98, green: 0.96, blue: 0.90, alpha: 1)),
        ("snow", NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)),
        ("pure black", NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)),
        ("vaporwave violet", NSColor(srgbRed: 0.16, green: 0.08, blue: 0.33, alpha: 1))
    ]

    private let themes: [AppTheme] = [.system] + AppThemeStyles.all

    /// Runs `body` for every ground under every stock theme, in a fixed drawing appearance.
    ///
    /// The appearance has to be pinned: every colour in the recipe is dynamic, and resolving one
    /// outside a drawing appearance answers for whatever AppKit last had in hand — the same trap
    /// `DiffView.applyCurrentTheme` exists to close.
    private func forEachGroundAndTheme(
        _ body: (_ label: String, _ ground: NSColor, _ ink: Design.DiffInk) -> Void
    ) {
        for theme in themes {
            AppThemeLibrary.apply(theme)
            AppThemePalette.set(theme)

            for appearance in [NSAppearance(named: .aqua), NSAppearance(named: .darkAqua)] {
                appearance?.performAsCurrentDrawingAppearance {
                    for (name, ground) in grounds {
                        body("\(theme.name)/\(name)", ground, Design.Diff.on(ground))
                    }
                }
            }
        }
    }

    // MARK: - The stated asymmetry

    /// Removed is darker than added on **every** ground, which is the property carrying the
    /// distinction for a red-green colourblind reader — the one part of this they can use
    /// besides the `+`/`−` in the gutter. It is also the half most easily lost, because the two
    /// steps are computed from different branches on light and dark grounds.
    func testRemovedWashIsAlwaysDarkerThanAdded() {
        forEachGroundAndTheme { label, _, ink in
            XCTAssertLessThan(
                ink.removedWash.oklab.lightness,
                ink.addedWash.oklab.lightness,
                "\(label): removed must read darker than added"
            )
        }
    }

    // MARK: - Legibility

    /// The marker has to clear the floor on the wash it is drawn on. `legible(on:)` is applied
    /// twice against two different backgrounds, and the second call can in principle undo the
    /// first — this is what says it does not.
    func testInkClearsTheContrastFloorOnItsOwnWash() {
        forEachGroundAndTheme { label, _, ink in
            XCTAssertGreaterThanOrEqual(
                ThemeContrast.ratio(ink.added, ink.addedWash),
                ThemeContrast.minimumRatio,
                "\(label): the + marker is illegible on the added wash"
            )
            XCTAssertGreaterThanOrEqual(
                ThemeContrast.ratio(ink.removed, ink.removedWash),
                ThemeContrast.minimumRatio,
                "\(label): the − marker is illegible on the removed wash"
            )
        }
    }

    /// Changed code is neutral ink, not a second application of the line's red/green meaning.
    /// It still has to clear the same contrast floor on every theme and every host ground.
    func testBodyInkIsNeutralAndLegibleOnItsOwnWash() {
        forEachGroundAndTheme { label, _, ink in
            for (name, text, wash) in [
                ("added", ink.addedText, ink.addedWash),
                ("removed", ink.removedText, ink.removedWash),
            ] {
                XCTAssertLessThan(
                    text.oklab.chroma,
                    0.001,
                    "\(label): \(name) code ink picked up the wash's hue"
                )
                XCTAssertGreaterThanOrEqual(
                    ThemeContrast.ratio(text, wash),
                    ThemeContrast.minimumRatio,
                    "\(label): \(name) code ink is illegible on its wash"
                )
            }
        }
    }

    /// The same ink is also used for the `+27 −8` counters, which sit on the ground rather than
    /// on a wash.
    func testInkClearsTheContrastFloorOnTheBareGround() {
        forEachGroundAndTheme { label, ground, ink in
            let base = ground.composited(over: Design.Surface.ground)
            XCTAssertGreaterThanOrEqual(
                ThemeContrast.ratio(ink.added, base),
                ThemeContrast.minimumRatio,
                "\(label): the added counter is illegible on the ground"
            )
            XCTAssertGreaterThanOrEqual(
                ThemeContrast.ratio(ink.removed, base),
                ThemeContrast.minimumRatio,
                "\(label): the removed counter is illegible on the ground"
            )
        }
    }

    // MARK: - Direction

    /// Whatever the theme states, an added wash reads green and a removed one reads red. A theme
    /// is free to state a teal `statusPositive`; nothing it can state makes an added line orange.
    func testWashesStayOnTheirOwnSideOfTheWheel() {
        forEachGroundAndTheme { label, _, ink in
            // Oklab hue in radians: sRGB green is 2.49, sRGB red 0.51.
            let added = ink.addedWash.oklab.hue
            let removed = ink.removedWash.oklab.hue

            XCTAssertTrue(
                (2.2...3.15).contains(added),
                "\(label): added wash hue \(added) rad left the green arc"
            )
            // The upper bound carries slack the lower one does not need. Against a *pure black*
            // ground the wash sits near lightness 0.07, where the gamut mapper's ±0.0005 slack
            // is the same size as the channel values themselves — clamping a barely-negative
            // channel to zero moves the measured hue by a few hundredths of a radian while
            // moving the colour by under 1/255. Slack enough to absorb that, and nowhere near
            // enough to admit the orange (0.8 rad) this arc exists to exclude.
            XCTAssertTrue(
                (-0.2...0.55).contains(removed),
                "\(label): removed wash hue \(removed) rad left the red arc"
            )
        }
    }

    /// A wash nobody can see against its ground is not a wash. This is the failure a chroma
    /// floor and a lightness step exist to prevent, and it is ground-dependent — a green tint on
    /// an already-green ground is where it would happen.
    func testEachWashIsDistinguishableFromItsGround() {
        forEachGroundAndTheme { label, ground, ink in
            let base = ground.composited(over: Design.Surface.ground).oklab

            for (name, wash) in [("added", ink.addedWash), ("removed", ink.removedWash)] {
                let value = wash.oklab
                let separation = hypot(
                    value.lightness - base.lightness,
                    hypot(value.a - base.a, value.b - base.b)
                )
                XCTAssertGreaterThan(
                    separation, 0.012,
                    "\(label): the \(name) wash is invisible against its ground"
                )
            }
        }
    }

    // MARK: - Extremes and accessibility

    /// Pure black and pure white have no headroom on one side. The step is scaled by the room
    /// available precisely so those do not clip to a degenerate answer.
    func testExtremeGroundsProduceUsableWashes() {
        for ground in [NSColor.black, NSColor.white] {
            NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
                let ink = Design.Diff.on(ground)
                XCTAssertNotEqual(ink.addedWash.hexString, ink.removedWash.hexString)
                XCTAssertLessThan(ink.removedWash.oklab.lightness, ink.addedWash.oklab.lightness)
            }
        }
    }

    /// Increase Contrast strengthens the wash without moving it to the other side of the wheel —
    /// a stronger version of the same colour, not a different one.
    func testIncreaseContrastStrengthensWithoutChangingDirection() {
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            let ground = NSColor(srgbRed: 0.03, green: 0.13, blue: 0.10, alpha: 1)

            Design.Accessibility.increaseContrastOverrideForTesting = false
            let normal = Design.Diff.on(ground)

            Design.Accessibility.increaseContrastOverrideForTesting = true
            let boosted = Design.Diff.on(ground)

            let base = ground.composited(over: Design.Surface.ground).oklab
            XCTAssertGreaterThan(
                abs(boosted.addedWash.oklab.lightness - base.lightness),
                abs(normal.addedWash.oklab.lightness - base.lightness),
                "Increase Contrast did not strengthen the added wash"
            )
            XCTAssertTrue((2.2...3.15).contains(boosted.addedWash.oklab.hue))
            XCTAssertTrue((-0.2...0.5).contains(boosted.removedWash.oklab.hue))
        }
    }
}

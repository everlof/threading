import AppKit
import XCTest
@testable import Threading

/// A selection's fill and the ink on it are one decision.
///
/// They were two, made in different files, and they drifted apart in both directions at once: a
/// list row and a menu row filled with the theme's `selection` and wrote `Design.Text.label` on it
/// — 1.31:1 under Windows 98's solid navy — while the audit row and the completion row filled
/// with the same role and wrote `Design.Text.selected`, an ink measured against the *opaque*
/// accent, which under a theme whose selection is that accent at 20% is white on a pale wash.
///
/// The sweep below is the point of the type. It is stated over every stock theme and every
/// appearance each one ships, because the failure was never a call site being careless — it was a
/// promise ("held far enough back that the row's own label tiers still read over it") that no
/// theme was ever checked against.
@MainActor
final class SelectionSurfaceTests: XCTestCase {

    /// A ground no theme's own surfaces sit on, for the cases that want the arithmetic isolated.
    private static let neutralGround = NSColor.white

    // MARK: - Helpers

    /// A colour's components in sRGB, read **in the appearance currently drawing** — these tests
    /// run inside `performAsCurrentDrawingAppearance`, and resolving against `NSApp`'s appearance
    /// instead is how a dark variant's assertion quietly measures the light one.
    private func components(_ color: NSColor) -> [CGFloat] {
        guard let srgb = color.usingColorSpace(.sRGB) else { return [] }
        return [srgb.redComponent, srgb.greenComponent, srgb.blueComponent, srgb.alphaComponent]
    }

    private func assertSameColour(
        _ first: NSColor,
        _ second: NSColor,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let a = components(first)
        let b = components(second)
        XCTAssertEqual(a.count, b.count, message, file: file, line: line)
        for (left, right) in zip(a, b) {
            XCTAssertEqual(left, right, accuracy: 0.001, message, file: file, line: line)
        }
    }

    /// Adaptive styles answer under both appearances; a fixed style only under its own.
    private func appearances(for theme: AppTheme) throws -> [NSAppearance] {
        if theme.isAdaptive {
            return [
                try XCTUnwrap(NSAppearance(named: .aqua)),
                try XCTUnwrap(NSAppearance(named: .darkAqua))
            ]
        }
        return [try XCTUnwrap(theme.mode.appearance)]
    }

    /// Runs `body` with `theme` in force under `appearance`, which is both halves of the answer:
    /// the palette decides which colours the roles resolve to, and the drawing appearance decides
    /// which variant of each.
    private func withTheme(
        _ theme: AppTheme,
        under appearance: NSAppearance,
        _ body: () -> Void
    ) {
        let previous = AppThemePalette.current
        defer { AppThemePalette.set(previous) }

        AppThemePalette.set(theme)
        appearance.performAsCurrentDrawingAppearance(body)
    }

    /// Every stock theme paired with every appearance it ships, styled ones only: under **System**
    /// a list row hands its highlight back to AppKit and paints none of this.
    private func styledThemesAndAppearances() throws -> [(AppTheme, NSAppearance)] {
        try AppThemeLibrary.stock
            .filter { !$0.isSystem }
            .flatMap { theme in try appearances(for: theme).map { (theme, $0) } }
    }

    // MARK: - Quiet: a surface that cannot reach its contents' ink

    /// The claim `ThemedTableRowView` makes in its own documentation, now checked.
    ///
    /// A list row draws the fill and its **cells** draw the text — nine view controllers, inking
    /// themselves from `Design.Text` as anything on the chrome's ground should. The row cannot tell
    /// them what it painted, so what it paints has to be something they still read on.
    func testEveryStockThemeLeavesAListRowsLabelReadable() throws {
        for (theme, appearance) in try styledThemesAndAppearances() {
            withTheme(theme, under: appearance) {
                let ground = Design.Surface.background
                let quiet = SelectionSurface.quiet(over: ground)
                let ratio = ThemeContrast.ratio(Design.Text.label, quiet.ground)

                XCTAssertGreaterThanOrEqual(
                    ratio,
                    SelectionSurface.Defaults.minimumLabelRatio,
                    "\(theme.name) [\(appearance.name.rawValue)]: a selected list row's title "
                        + "reads at \(String(format: "%.2f", ratio)):1"
                )
            }
        }
    }

    /// A theme that authored a selection its labels already read on is never second-guessed. This
    /// is most of the catalogue, and it is what keeps the rule from restyling the whole app to fix
    /// two themes.
    func testAThemeThatAlreadyKeepsThePromiseIsLeftExactlyAsAuthored() throws {
        var untouched = 0
        for (theme, appearance) in try styledThemesAndAppearances() {
            withTheme(theme, under: appearance) {
                let ground = Design.Surface.background
                let stated = SelectionSurface.stated(over: ground)
                guard ThemeContrast.ratio(Design.Text.label, stated.ground)
                    >= SelectionSurface.Defaults.minimumLabelRatio else { return }

                untouched += 1
                assertSameColour(
                    SelectionSurface.quiet(over: ground).fill,
                    stated.fill,
                    "\(theme.name): a compliant theme was restyled anyway"
                )
            }
        }

        XCTAssertGreaterThan(untouched, 0, "no theme exercised the leave-it-alone path")
    }

    /// Windows 98 is the reported case and the worst of them: solid `#000080` over the `#C0C0C0`
    /// sidebar leaves its own near-black label at 1.31:1. It is held back — and only as far as it
    /// has to be, so the row is still visibly navy rather than a wash.
    func testTheReportedThemeIsHeldBackAndOnlyAsFarAsItMust() throws {
        let appearance = try XCTUnwrap(NSAppearance(named: .aqua))

        withTheme(AppThemeStyles.win98, under: appearance) {
            let ground = Design.Surface.background
            let stated = SelectionSurface.stated(over: ground)
            let quiet = SelectionSurface.quiet(over: ground)

            XCTAssertLessThan(
                ThemeContrast.ratio(Design.Text.label, stated.ground),
                SelectionSurface.Defaults.minimumLabelRatio,
                "the fixture no longer reproduces the reported case"
            )
            XCTAssertGreaterThanOrEqual(
                ThemeContrast.ratio(Design.Text.label, quiet.ground),
                SelectionSurface.Defaults.minimumLabelRatio
            )

            let authored = stated.fill.usingColorSpace(.sRGB)?.alphaComponent ?? 0
            let held = quiet.fill.usingColorSpace(.sRGB)?.alphaComponent ?? 0
            XCTAssertLessThan(held, authored, "the fill was not held back at all")
            XCTAssertGreaterThan(
                held,
                authored / 4,
                "held back so far the selection is barely a selection"
            )
        }
    }

    // MARK: - Stated: a surface that inks its own contents

    /// The ink follows the fill rather than a constant, so it comes out *opposite* under the two
    /// families of theme — light on a solid navy, dark on a pale wash — without either call
    /// site knowing which it has.
    func testStatedInkReadsOnWhateverTheThemeAuthored() throws {
        for (theme, appearance) in try styledThemesAndAppearances() {
            withTheme(theme, under: appearance) {
                let stated = SelectionSurface.stated(over: Design.Surface.background)
                let ratio = ThemeContrast.ratio(stated.ink.label, stated.ground)

                XCTAssertGreaterThanOrEqual(
                    ratio,
                    SelectionSurface.Defaults.minimumLabelRatio,
                    "\(theme.name) [\(appearance.name.rawValue)]: text on a selection it states "
                        + "itself reads at \(String(format: "%.2f", ratio)):1"
                )
            }
        }
    }

    /// Both directions of the original bug, in one assertion each, against the two themes that
    /// produced them: the solid selection wants light ink and the wash wants dark, and
    /// neither `Design.Text.label` nor `Design.Text.selected` could have answered both.
    func testTheInkInvertsBetweenAnOpaqueSelectionAndAWash() throws {
        let appearance = try XCTUnwrap(NSAppearance(named: .aqua))

        var navyInk = CGFloat.nan
        withTheme(AppThemeStyles.win98, under: appearance) {
            navyInk = IconBackplate.tone(
                of: SelectionSurface.stated(over: Design.Surface.background).ink.label
            )
        }
        XCTAssertGreaterThan(navyInk, 0.5, "a solid navy selection should be written on in light ink")

        var washInk = CGFloat.nan
        withTheme(AppThemeStyles.christmas, under: appearance) {
            washInk = IconBackplate.tone(
                of: SelectionSurface.stated(over: Design.Surface.background).ink.label
            )
        }
        XCTAssertLessThan(washInk, 0.5, "a 20% wash should be written on in dark ink")
    }

    // MARK: - Distinct: a run of selected text

    /// The ground a field's selected text lands on: the well the field paints, over the pane.
    private func fieldWell() -> NSColor {
        Design.Surface.field.composited(over: Design.Surface.background)
    }

    /// A highlight is a highlight only if it is seen. `stated` holds the ink to the fill; this
    /// holds the fill to its ground, over both grounds selected text actually sits on — a field's
    /// well and the pane a transparent text view is laid over — and keeps the ink promise too.
    func testEveryStockThemeSetsSelectedTextApartFromItsGround() throws {
        let floor = SelectionSurface.Defaults.minimumTextDistance
        for (theme, appearance) in try styledThemesAndAppearances() {
            withTheme(theme, under: appearance) {
                for (name, ground) in [("field well", fieldWell()), ("pane", Design.Surface.background)] {
                    let distinct = SelectionSurface.distinct(over: ground)
                    let distance = ThemeContrast.perceptualDistance(distinct.ground, ground)
                    let ratio = ThemeContrast.ratio(distinct.ink.label, distinct.ground)
                    let context = "\(theme.name) [\(appearance.name.rawValue)] over the \(name)"

                    XCTAssertGreaterThanOrEqual(
                        distance,
                        floor,
                        "\(context): selected text stands ΔE \(String(format: "%.1f", distance)) "
                            + "from its ground"
                    )
                    XCTAssertGreaterThanOrEqual(
                        ratio,
                        SelectionSurface.Defaults.minimumLabelRatio,
                        "\(context): selected text reads at \(String(format: "%.2f", ratio)):1"
                    )
                }
            }
        }
    }

    /// A theme whose selection already stands apart is painted exactly as authored — the rule
    /// raises the faint cases and restyles nothing else.
    func testASelectionThatAlreadyStandsApartIsLeftAsStated() throws {
        var untouched = 0
        for (theme, appearance) in try styledThemesAndAppearances() {
            withTheme(theme, under: appearance) {
                let ground = fieldWell()
                let stated = SelectionSurface.stated(over: ground)
                guard ThemeContrast.perceptualDistance(stated.ground, ground)
                    >= SelectionSurface.Defaults.minimumTextDistance else { return }

                untouched += 1
                assertSameColour(
                    SelectionSurface.distinct(over: ground).fill,
                    stated.fill,
                    "\(theme.name): a selection that already stood apart was raised anyway"
                )
            }
        }

        XCTAssertGreaterThan(untouched, 0, "no theme exercised the leave-it-alone path")
    }

    /// The reported case: a URL selected in the browser's address field under Pure's night
    /// variant, `#292929` over the `#101010` well — ΔE 11.9, the distance macOS keeps for an
    /// *inactive* highlight. It is raised clear of the floor, lighter, and keeps light ink.
    func testTheReportedAddressFieldSelectionIsRaised() throws {
        let appearance = try XCTUnwrap(NSAppearance(named: .darkAqua))
        let floor = SelectionSurface.Defaults.minimumTextDistance

        withTheme(AppThemeStyles.pure, under: appearance) {
            let ground = fieldWell()
            let stated = SelectionSurface.stated(over: ground)
            let distinct = SelectionSurface.distinct(over: ground)

            XCTAssertLessThan(
                ThemeContrast.perceptualDistance(stated.ground, ground),
                floor,
                "the fixture no longer reproduces the reported case"
            )
            XCTAssertGreaterThanOrEqual(
                ThemeContrast.perceptualDistance(distinct.ground, ground),
                floor
            )
            XCTAssertGreaterThan(
                IconBackplate.tone(of: distinct.ground),
                IconBackplate.tone(of: stated.ground),
                "a selection on a dark well should be raised lighter"
            )
            XCTAssertGreaterThan(
                IconBackplate.tone(of: distinct.ink.label),
                0.5,
                "a raised dark selection should still be written on in light ink"
            )
        }
    }

    // MARK: - Dynamic: a surface that states its colours once

    /// `selectedTextAttributes` is set at construction and read by TextKit for the life of the
    /// view, so the resolution has to live in the colours. A value captured at build time would
    /// pin a text view's selection to the theme it was created under.
    func testDynamicColoursFollowALiveThemeSwitch() throws {
        let appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        let selection = SelectionSurface.dynamic { Self.neutralGround }

        var fills: [[CGFloat]] = []
        var inks: [[CGFloat]] = []
        for theme in [AppThemeStyles.win98, AppThemeStyles.christmas] {
            withTheme(theme, under: appearance) {
                fills.append(components(selection.fill))
                inks.append(components(selection.ink.label))
            }
        }

        XCTAssertNotEqual(fills[0], fills[1], "one dynamic fill answered two themes the same way")
        XCTAssertNotEqual(inks[0], inks[1], "the ink did not follow the fill across the switch")
    }
}

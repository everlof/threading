import AppKit
import XCTest
@testable import Skalman

/// The scope chain, and the guard that stops a theme making the terminal unusable.
///
/// Both are pure, which is the reason they are testable at all: resolution reads three
/// optional names and a set, rather than three singletons and a window.
final class ThemeResolutionTests: XCTestCase {

    private let available: Set<String> = ["Basic", "Pro", "Ocean", "Homebrew"]

    // MARK: - Order

    func testSessionWinsOverProjectAndGlobal() {
        let resolved = ThemeResolution.resolve(
            session: "Ocean",
            project: "Pro",
            global: "Basic",
            available: available
        )

        XCTAssertEqual(resolved, ThemeResolution.Assignment(scope: .session, themeName: "Ocean"))
    }

    func testProjectWinsWhenSessionHasNoTheme() {
        let resolved = ThemeResolution.resolve(
            session: nil,
            project: "Pro",
            global: "Basic",
            available: available
        )

        XCTAssertEqual(resolved, ThemeResolution.Assignment(scope: .project, themeName: "Pro"))
    }

    func testGlobalAppliesWhenNothingNarrowerIsAssigned() {
        let resolved = ThemeResolution.resolve(
            session: nil,
            project: nil,
            global: "Basic",
            available: available
        )

        XCTAssertEqual(resolved, ThemeResolution.Assignment(scope: .global, themeName: "Basic"))
    }

    /// Absent means *inherit*, not "copy the default at creation": a session that never chose
    /// follows the default wherever it moves.
    func testUnassignedSessionFollowsAChangedGlobal() {
        let before = ThemeResolution.resolve(
            session: nil, project: nil, global: "Basic", available: available
        )
        let after = ThemeResolution.resolve(
            session: nil, project: nil, global: "Ocean", available: available
        )

        XCTAssertEqual(before?.themeName, "Basic")
        XCTAssertEqual(after?.themeName, "Ocean")
    }

    // MARK: - Dangling Names

    /// A deleted theme leaves its name behind on every record that named it. That degrades to
    /// inheriting from the next scope out — never to a terminal with no theme at all.
    func testDeletedSessionThemeFallsBackToTheProject() {
        let resolved = ThemeResolution.resolve(
            session: "Deleted",
            project: "Pro",
            global: "Basic",
            available: available
        )

        XCTAssertEqual(resolved, ThemeResolution.Assignment(scope: .project, themeName: "Pro"))
    }

    func testDeletedSessionAndProjectThemesFallBackToTheGlobal() {
        let resolved = ThemeResolution.resolve(
            session: "Deleted",
            project: "AlsoDeleted",
            global: "Basic",
            available: available
        )

        XCTAssertEqual(resolved, ThemeResolution.Assignment(scope: .global, themeName: "Basic"))
    }

    /// Nothing valid anywhere is reported as nothing, so the caller can answer with the
    /// profile's own embedded copy rather than being handed a name it cannot look up.
    func testNothingResolvesWhenEveryNameIsUnknown() {
        XCTAssertNil(
            ThemeResolution.resolve(
                session: "Gone", project: "Gone", global: "Gone", available: available
            )
        )
    }

    func testEmptyThemeListResolvesToNothing() {
        XCTAssertNil(
            ThemeResolution.resolve(session: nil, project: nil, global: "Basic", available: [])
        )
    }

    // MARK: - Contrast Guard

    func testLegibleThemePasses() {
        XCTAssertTrue(
            ThemeContrast.isLegible(
                foreground: TerminalTheme.basic.foreground,
                background: TerminalTheme.basic.background
            )
        )
    }

    func testEveryBuiltInThemeIsLegible() {
        for theme in TerminalTheme.builtInThemes {
            XCTAssertTrue(
                ThemeContrast.isLegible(
                    foreground: theme.foreground,
                    background: theme.background
                ),
                "\(theme.name) fails the contrast floor its own tools enforce"
            )
        }
    }

    func testTextOnItsOwnBackgroundColourIsRejected() {
        let colour = NSColor(hex: "#1E1E1E")!
        XCTAssertFalse(ThemeContrast.isLegible(foreground: colour, background: colour))
    }

    func testNearlyInvisibleTextIsRejected() {
        XCTAssertFalse(
            ThemeContrast.isLegible(
                foreground: NSColor(hex: "#202020")!,
                background: NSColor(hex: "#101010")!
            )
        )
    }

    /// The floor is deliberately low. A dim-on-dark palette people actually use has to pass, or
    /// the guard stops being a safety net and starts being a taste.
    func testLowContrastButReadablePalettePasses() {
        XCTAssertTrue(
            ThemeContrast.isLegible(
                foreground: NSColor(hex: "#93A1A1")!,
                background: NSColor(hex: "#002B36")!
            )
        )
    }

    // MARK: - Colour Keys

    func testWireNamesAreSnakeCase() {
        XCTAssertEqual(ThemeColorKey.brightMagenta.wireName, "bright_magenta")
        XCTAssertEqual(ThemeColorKey.foreground.wireName, "foreground")
    }

    func testEveryColourKeyRoundTripsThroughItsWireName() {
        for key in ThemeColorKey.allCases {
            XCTAssertEqual(ThemeColorKey.named(key.wireName), key)
        }
    }

    func testColourKeysCoverTheWholePalette() {
        let grouped = ThemeColorKey.main + ThemeColorKey.normal + ThemeColorKey.bright
        XCTAssertEqual(Set(grouped), Set(ThemeColorKey.allCases))
        XCTAssertEqual(grouped.count, ThemeColorKey.allCases.count, "a key is in two groups")
    }

    func testSubscriptWritesThroughToTheNamedColour() {
        var theme = TerminalTheme.basic
        let orange = NSColor(hex: "#FF8800")!

        theme[.brightCyan] = orange

        XCTAssertEqual(theme.brightCyan.hexString, orange.hexString)
        XCTAssertEqual(theme[.brightCyan].hexString, orange.hexString)
    }
}

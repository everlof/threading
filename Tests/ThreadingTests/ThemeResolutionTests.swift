import AppKit
import XCTest
@testable import Threading

/// The scope chain, and the guard that stops a theme making the terminal unusable.
///
/// Both are pure, which is the reason they are testable at all: resolution reads three
/// optional IDs and a set, rather than three singletons and a window.
final class ThemeResolutionTests: XCTestCase {

    private let available: Set<TerminalThemeID> = [.basic, .pro, .ocean, .homebrew]

    // MARK: - Order

    func testSessionWinsOverProjectAndGlobal() {
        let resolved = ThemeResolution.resolve(
            session: .ocean,
            project: .pro,
            global: .basic,
            available: available
        )

        XCTAssertEqual(resolved, ThemeResolution.Assignment(scope: .session, themeID: .ocean))
    }

    func testProjectWinsWhenSessionHasNoTheme() {
        let resolved = ThemeResolution.resolve(
            session: nil,
            project: .pro,
            global: .basic,
            available: available
        )

        XCTAssertEqual(resolved, ThemeResolution.Assignment(scope: .project, themeID: .pro))
    }

    func testGlobalAppliesWhenNothingNarrowerIsAssigned() {
        let resolved = ThemeResolution.resolve(
            session: nil,
            project: nil,
            global: .basic,
            available: available
        )

        XCTAssertEqual(resolved, ThemeResolution.Assignment(scope: .global, themeID: .basic))
    }

    /// Absent means *inherit*, not "copy the default at creation": a session that never chose
    /// follows the default wherever it moves.
    func testUnassignedSessionFollowsAChangedGlobal() {
        let before = ThemeResolution.resolve(
            session: nil, project: nil, global: .basic, available: available
        )
        let after = ThemeResolution.resolve(
            session: nil, project: nil, global: .ocean, available: available
        )

        XCTAssertEqual(before?.themeID, .basic)
        XCTAssertEqual(after?.themeID, .ocean)
    }

    // MARK: - Dangling IDs

    /// A deleted theme leaves its ID behind on every record that selected it. That degrades to
    /// inheriting from the next scope out — never to a terminal with no theme at all.
    func testDeletedSessionThemeFallsBackToTheProject() {
        let resolved = ThemeResolution.resolve(
            session: TerminalThemeID("deleted"),
            project: .pro,
            global: .basic,
            available: available
        )

        XCTAssertEqual(resolved, ThemeResolution.Assignment(scope: .project, themeID: .pro))
    }

    func testDeletedSessionAndProjectThemesFallBackToTheGlobal() {
        let resolved = ThemeResolution.resolve(
            session: TerminalThemeID("deleted"),
            project: TerminalThemeID("also-deleted"),
            global: .basic,
            available: available
        )

        XCTAssertEqual(resolved, ThemeResolution.Assignment(scope: .global, themeID: .basic))
    }

    /// Nothing valid anywhere is reported as nothing, so the caller can answer with the
    /// profile's own embedded copy rather than being handed a name it cannot look up.
    func testNothingResolvesWhenEveryIDIsUnknown() {
        XCTAssertNil(
            ThemeResolution.resolve(
                session: TerminalThemeID("gone"),
                project: TerminalThemeID("gone"),
                global: TerminalThemeID("gone"),
                available: available
            )
        )
    }

    func testEmptyThemeListResolvesToNothing() {
        XCTAssertNil(
            ThemeResolution.resolve(session: nil, project: nil, global: .basic, available: [])
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

// MARK: - Identity and Migration

@MainActor
final class TerminalThemeIdentityTests: XCTestCase {

    func testBuiltInThemeIDsAreStableAndUnique() {
        XCTAssertEqual(TerminalTheme.basic.id, .basic)
        XCTAssertEqual(TerminalTheme.pro.id, .pro)
        XCTAssertEqual(TerminalTheme.homebrew.id, .homebrew)
        XCTAssertEqual(TerminalTheme.ocean.id, .ocean)
        XCTAssertEqual(
            Set(TerminalTheme.builtInThemes.map(\.id)).count,
            TerminalTheme.builtInThemes.count
        )
    }

    func testDuplicatingCreatesANewIdentityWhileRenamingPreservesIt() {
        let source = TerminalTheme.ocean
        let duplicate = source.duplicated(named: "Ocean Variant")
        let renamed = duplicate.renamed("Ocean Variant Renamed")

        XCTAssertNotEqual(duplicate.id, source.id)
        XCTAssertEqual(renamed.id, duplicate.id)
        XCTAssertEqual(renamed.name, "Ocean Variant Renamed")
    }

    func testStoredCustomThemeKeepsItsIDAcrossRename() throws {
        let manager = ThemeManager.shared
        let original = TerminalTheme.basic.duplicated(
            named: "Identity Probe \(UUID().uuidString)"
        )
        XCTAssertTrue(ThemeAssignments.create(original))
        defer {
            if let stored = manager.theme(withID: original.id) {
                _ = manager.deleteTheme(stored)
            }
        }

        XCTAssertTrue(
            ThemeAssignments.rename(original, to: "\(original.name) Renamed")
        )
        let renamed = try XCTUnwrap(manager.theme(withID: original.id))
        XCTAssertEqual(renamed.id, original.id)
        XCTAssertEqual(renamed.name, "\(original.name) Renamed")
    }

    func testNamesAreUniqueCaseInsensitively() {
        let colliding = TerminalTheme.basic.duplicated(named: "oCeAn")

        XCTAssertFalse(ThemeAssignments.create(colliding))
        XCTAssertNil(ThemeManager.shared.theme(withID: colliding.id))
    }

    /// A colour that will not parse falls back to the stock palette's value *for that role*.
    ///
    /// It used to fall back to white, which is the one answer that can make the terminal
    /// unusable: a dark theme whose background failed to parse drew paper, and the palette
    /// written to read on a dark ground was invisible on it. White is also indistinguishable
    /// from a theme that is genuinely white, so nothing reported the loss.
    func testAnUnparseableColourFallsBackToItsRoleRatherThanToWhite() throws {
        let source = TerminalTheme.ocean
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(source))
                as? [String: Any]
        )
        object["background"] = "not-a-colour"
        object["red"] = "#gg0000"

        let decoded = try JSONDecoder().decode(
            TerminalTheme.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(
            decoded.background.hexString,
            TerminalTheme.basic.background.hexString,
            "an unparseable background did not fall back to a background"
        )
        XCTAssertEqual(
            decoded.red.hexString,
            TerminalTheme.basic.red.hexString,
            "an unparseable red did not fall back to a red"
        )
        XCTAssertNotEqual(
            decoded.background.hexString,
            NSColor.white.hexString,
            "the background fell back to white, which is what made a dark theme unreadable"
        )

        // Everything that *did* parse is untouched: one bad value costs one colour.
        XCTAssertEqual(decoded.foreground.hexString, source.foreground.hexString)
        XCTAssertEqual(decoded.green.hexString, source.green.hexString)
    }

    func testLegacyThemeWithoutIDGetsDeterministicTaggedIdentity() throws {
        let oldName = "Old Custom \(UUID().uuidString)"
        let source = TerminalTheme.basic.duplicated(named: oldName)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(source))
                as? [String: Any]
        )
        object.removeValue(forKey: "id")

        let decoded = try JSONDecoder().decode(
            TerminalTheme.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(decoded.id, .legacyName(oldName))
        XCTAssertEqual(decoded.id.legacyName, oldName)

        let rewritten = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded))
                as? [String: Any]
        )
        XCTAssertEqual(rewritten["id"] as? String, decoded.id.rawValue)
    }

    func testLegacyCaseOnlyNameCollisionKeepsItsTaggedIdentity() {
        var custom = TerminalTheme.basic.renamed("ocean")
        custom.id = .legacyName("ocean")

        let migration = ThemeManager.normaliseLegacyThemes([custom])

        XCTAssertEqual(migration.first?.name, "ocean 2")
        XCTAssertEqual(migration.first?.id, .legacyName("ocean"))
    }

    func testLegacySessionAndProjectNamesDecodeButOnlyIDsAreReencoded() throws {
        let session = try JSONDecoder().decode(
            AgentSession.self,
            from: Data(#"{"kind":"claude","themeName":"Ocean"}"#.utf8)
        )
        let project = try JSONDecoder().decode(
            Project.self,
            from: Data(#"{"folderPath":"/tmp/theme-probe","themeName":"Homebrew"}"#.utf8)
        )

        XCTAssertEqual(session.themeID, .ocean)
        XCTAssertEqual(project.themeID, .homebrew)

        let sessionJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(session))
                as? [String: Any]
        )
        let projectJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(project))
                as? [String: Any]
        )
        XCTAssertEqual(sessionJSON["themeID"] as? String, TerminalThemeID.ocean.rawValue)
        XCTAssertEqual(projectJSON["themeID"] as? String, TerminalThemeID.homebrew.rawValue)
        XCTAssertNil(sessionJSON["themeName"])
        XCTAssertNil(projectJSON["themeName"])
    }
}

// MARK: - Follow App Theme

/// The terminal-theme list's app-theme entry is a reserved ID rather than a fourth setting —
/// that is what lets it inherit down the same three scopes as any palette.
@MainActor
final class FollowsAppThemeTests: XCTestCase {

    override func tearDown() {
        AppThemeLibrary.apply(.system)
        super.tearDown()
    }

    /// The whole point of making it an ID: `ThemeResolution` needs no case for it, so a session
    /// can follow the chrome while its project names a palette, and the narrowest scope still
    /// wins.
    func testTheEntryResolvesLikeAnyOtherNameInTheChain() {
        let available: Set<TerminalThemeID> = [.basic, .pro, .followsAppTheme]

        let session = ThemeResolution.resolve(
            session: .followsAppTheme, project: .pro, global: .basic,
            available: available
        )
        XCTAssertEqual(session?.scope, .session)
        XCTAssertEqual(session?.themeID, .followsAppTheme)

        let project = ThemeResolution.resolve(
            session: nil, project: .followsAppTheme, global: .basic,
            available: available
        )
        XCTAssertEqual(project?.scope, .project)
        XCTAssertEqual(project?.themeID, .followsAppTheme)
    }

    /// It has to be in `availableIDs`, or resolution treats a scope that chose it as dangling
    /// and silently inherits past it — which would look exactly like the choice not sticking.
    func testTheEntryIsAvailableToResolveAgainst() {
        XCTAssertTrue(ThemeAssignments.availableIDs.contains(.followsAppTheme))
    }

    /// **The shipped default follows the chrome**, which is what makes Inherit mean anything.
    ///
    /// The chain's last answer is the default profile's embedded theme, and while that was
    /// `.basic` the one state every session ships in — Inherit all the way up — resolved to a
    /// fixed white-on-black palette. Switching app theme moved the window and left the terminal
    /// inside it alone, and the two read as one thing broken rather than two settings.
    func testTheShippedDefaultFollowsTheAppTheme() {
        XCTAssertEqual(
            TerminalProfile.default.theme.id,
            .followsAppTheme,
            "a fresh install's terminal does not follow its chrome"
        )
    }

    /// Stored as the reserved ID and not as the palette it happened to mean at the time, so the
    /// chain's last answer re-resolves like any other scope — asserted through
    /// `ThemeAssignments.defaultTheme`, the singleton path the app actually reads.
    ///
    /// The default is *written* first rather than assumed: `PreferenceStore`'s scratch suite is
    /// named and therefore persistent, so a profile stored by an earlier run of
    /// `ThemeToolTests.testSetThemeCanMakeTheGlobalDefaultFollowAppTheme` outlives it and shadows
    /// the factory value — which is the same shadowing a real user with a saved profile sees, and
    /// exactly why this reads the shipped struct instead of trusting what is on disk.
    func testTheDefaultsPaletteMovesWithTheAppTheme() {
        let previous = ThemeAssignments.defaultTheme
        defer { ThemeAssignments.setDefaultTheme(previous) }
        ThemeAssignments.setDefaultTheme(TerminalProfile.default.theme)

        XCTAssertEqual(ThemeAssignments.defaultTheme.id, .followsAppTheme)

        AppThemeLibrary.apply(AppThemeStyles.cyberpunk)
        let cyber = ThemeAssignments.palette(withID: ThemeAssignments.defaultTheme.id)

        AppThemeLibrary.apply(AppThemeStyles.newsprint)
        let newsprint = ThemeAssignments.palette(withID: ThemeAssignments.defaultTheme.id)

        XCTAssertEqual(cyber.background.hexString,
                       AppThemeStyles.cyberpunk.terminalPalette.background.hexString)
        XCTAssertEqual(newsprint.background.hexString,
                       AppThemeStyles.newsprint.terminalPalette.background.hexString)
        XCTAssertNotEqual(cyber.background.hexString, newsprint.background.hexString,
                          "the default stayed on the palette it was created with")
    }

    /// A session that never chose — the state everything ships in — reaches the app theme through
    /// two empty scopes. This is the user-visible claim: switch chrome, the terminal moves.
    ///
    /// Resolved against the shipped default rather than the stored one, so the claim being made is
    /// about what the app ships with and not about what this machine has on disk.
    func testASessionThatChoseNothingReachesTheAppThemeThroughTheChain() throws {
        let resolved = try XCTUnwrap(ThemeResolution.resolve(
            session: nil,
            project: nil,
            global: TerminalProfile.default.theme.id,
            available: ThemeAssignments.availableIDs
        ))
        XCTAssertEqual(resolved.scope, .global)
        XCTAssertEqual(resolved.themeID, .followsAppTheme)

        AppThemeLibrary.apply(AppThemeStyles.bauhaus)
        XCTAssertEqual(
            ThemeAssignments.palette(withID: resolved.themeID).background.hexString,
            AppThemeStyles.bauhaus.terminalPalette.background.hexString,
            "an inheriting session did not land on the app theme's own palette"
        )
    }

    /// The palette is the live one, not a copy taken when the choice was made.
    func testThePaletteFollowsTheAppThemeRatherThanBeingCopied() {
        AppThemeLibrary.apply(AppThemeStyles.cyberpunk)
        let cyber = ThemeAssignments.palette(named: TerminalThemeNames.followsAppTheme)

        AppThemeLibrary.apply(AppThemeStyles.swissMinimalist)
        let swiss = ThemeAssignments.palette(named: TerminalThemeNames.followsAppTheme)

        XCTAssertNotEqual(cyber.background, swiss.background,
                          "the palette did not move with the app theme")
        XCTAssertEqual(cyber.name, "Cyberpunk")
        XCTAssertEqual(swiss.name, "Swiss Minimalist")
    }

    /// A user theme wearing the reserved name would shadow the entry at every scope that chose
    /// it, and the entry would stop meaning one thing.
    func testTheNameCannotBeTakenByAUserTheme() {
        let manager = ThemeManager.shared
        let stolen = TerminalTheme.basic.renamed(TerminalThemeNames.followsAppTheme)

        manager.addTheme(stolen)
        XCTAssertNil(manager.customThemes.first { $0.name == TerminalThemeNames.followsAppTheme },
                     "a custom theme took the reserved name")

        let mine = TerminalTheme.basic.renamed("Reserved Name Probe")
        manager.addTheme(mine)
        defer { _ = manager.deleteTheme(mine) }
        XCTAssertFalse(manager.renameTheme(mine, to: TerminalThemeNames.followsAppTheme),
                       "a rename took the reserved name")
    }

    /// Every stated palette has to be readable on its own ground — the same floor a palette
    /// arriving over MCP is held to, applied to the ones we ship.
    func testEveryAppThemePaletteIsLegible() {
        for theme in [AppTheme.system] + AppThemeStyles.all {
            let palette = theme.terminalPalette
            XCTAssertTrue(
                ThemeContrast.isLegible(foreground: palette.foreground, background: palette.background),
                "\(theme.name)'s terminal text is not legible on its own background"
            )
        }
    }
}

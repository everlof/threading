import Foundation
import XCTest
@testable import ThreadingDomain

/// The persisted contract of a terminal theme's identity.
///
/// Every case here is about state already written to disk: a theme ID is stored in the project
/// database and in session records, and state from before IDs existed is keyed by the theme's
/// *name*. Getting any of these wrong does not fail loudly — a theme assignment quietly stops
/// resolving and the terminal falls back to the default, which reads as the user's choice being
/// forgotten rather than as a bug.
final class TerminalThemeIDTests: XCTestCase {

    func testEncodesAsABareStringLikeEveryOtherStoredIdentity() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let id = TerminalThemeID("rose-moon")

        XCTAssertEqual(try encoder.encode(id), try encoder.encode("rose-moon"))
        XCTAssertEqual(try decoder.decode(TerminalThemeID.self, from: encoder.encode("rose-moon")), id)
    }

    /// The legacy tag is base64 made URL-safe with its padding stripped. Names are chosen so their
    /// encodings contain `+`, `/` and each amount of padding, because the decoder restores all
    /// three and a mistake in any of them only shows up for *some* names.
    func testLegacyNameRoundTripsEveryBase64Shape() {
        let names = [
            "Basic Custom",      // no padding
            "Ocean?",            // encodes with a "/"
            "Tides>>>",          // encodes with a "+"
            "a",                 // two padding characters stripped
            "ab",                // one padding character stripped
            "Solarized — Dark",  // multi-byte UTF-8
        ]
        for name in names {
            let id = TerminalThemeID.legacyName(name)
            XCTAssertFalse(id.rawValue.contains("+"), "\(name) left a '+' in \(id.rawValue)")
            XCTAssertFalse(id.rawValue.contains("/"), "\(name) left a '/' in \(id.rawValue)")
            XCTAssertFalse(id.rawValue.contains("="), "\(name) left padding in \(id.rawValue)")
            XCTAssertEqual(id.legacyName, name, "\(name) did not survive \(id.rawValue)")
        }
    }

    func testAnOrdinaryIDIsNotMistakenForALegacyTag() {
        XCTAssertNil(TerminalThemeID.basic.legacyName)
        XCTAssertNil(TerminalThemeID.makeCustom().legacyName)
    }

    /// The four names that shipped before IDs map to fixed IDs; anything else becomes a legacy tag
    /// the assignment layer resolves once against the theme library.
    func testMigrationMapsTheBuiltInNamesToTheirFixedIdentities() {
        XCTAssertEqual(TerminalThemeID.migratedFromName("Basic"), .basic)
        XCTAssertEqual(TerminalThemeID.migratedFromName("Pro"), .pro)
        XCTAssertEqual(TerminalThemeID.migratedFromName("Homebrew"), .homebrew)
        XCTAssertEqual(TerminalThemeID.migratedFromName("Ocean"), .ocean)
        XCTAssertEqual(
            TerminalThemeID.migratedFromName(TerminalThemeNames.followsAppTheme),
            .followsAppTheme
        )

        let custom = TerminalThemeID.migratedFromName("My Theme")
        XCTAssertEqual(custom.legacyName, "My Theme")
    }

    /// Recovery from an ID collision has to be deterministic. Its doc comment records why: the
    /// migration once used a fresh UUID here, so if the rewrite failed the ID changed on every
    /// launch and any project assignment saved in between became dangling.
    func testCollisionRecoveryIsStableAcrossCalls() {
        let first = TerminalThemeID.recoveredFromCollision(name: "Night Owl", ordinal: 2)
        let second = TerminalThemeID.recoveredFromCollision(name: "Night Owl", ordinal: 2)

        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first, TerminalThemeID.recoveredFromCollision(name: "Night Owl", ordinal: 3))
        XCTAssertNotEqual(first, TerminalThemeID.recoveredFromCollision(name: "Day Owl", ordinal: 2))
    }

    func testFreshCustomIdentitiesDoNotCollide() {
        XCTAssertNotEqual(TerminalThemeID.makeCustom(), TerminalThemeID.makeCustom())
    }
}

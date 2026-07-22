import XCTest
@testable import Skalman

/// Naming a login after the person rather than after the shell alias.
///
/// Aliases are named after the *agent* — `claude-dblock`, `claude-vlundborg` — so a menu of
/// them asks the user to tell two logins apart by four characters in the middle of a word. The
/// address the CLI already records names the person instead.
final class AccountNameTests: XCTestCase {

    func testALocalPartBecomesAName() {
        XCTAssertEqual(AccountName.derived(fromEmail: "daniel.block3@example.com"), "Daniel Block")
        XCTAssertEqual(AccountName.derived(fromEmail: "victor.lundborg@example.com"), "Victor Lundborg")
    }

    /// Underscores, hyphens and plus-addressing are all separators people actually use.
    func testEverySeparatorSplitsWords() {
        XCTAssertEqual(AccountName.derived(fromEmail: "ada_lovelace@x.io"), "Ada Lovelace")
        XCTAssertEqual(AccountName.derived(fromEmail: "ada-lovelace@x.io"), "Ada Lovelace")
        XCTAssertEqual(AccountName.derived(fromEmail: "ada+work@x.io"), "Ada Work")
    }

    /// Digits on the end of a name are almost always "that address was taken", not a name.
    func testTrailingDigitsAreDropped() {
        XCTAssertEqual(AccountName.derived(fromEmail: "block99@x.io"), "Block")
        XCTAssertEqual(AccountName.derived(fromEmail: "2daniel@x.io"), "Daniel")
    }

    func testASingleWordStillReadsAsAName() {
        XCTAssertEqual(AccountName.derived(fromEmail: "everlof@x.io"), "Everlof")
    }

    /// Nothing readable comes out of these, and the caller falls back to the alias — which is
    /// at least the name the user types.
    func testUnreadableLocalPartsYieldNothing() {
        XCTAssertNil(AccountName.derived(fromEmail: "a@x.io"))
        XCTAssertNil(AccountName.derived(fromEmail: "12345@x.io"))
        XCTAssertNil(AccountName.derived(fromEmail: "@x.io"))
    }

    func testCaseIsNormalised() {
        XCTAssertEqual(AccountName.derived(fromEmail: "DANIEL.BLOCK@x.io"), "Daniel Block")
        XCTAssertEqual(AccountName.derived(fromEmail: "mcDONALD@x.io"), "Mcdonald")
    }
}

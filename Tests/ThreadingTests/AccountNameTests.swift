import XCTest
@testable import Threading

/// Naming a login after the person rather than after the shell alias.
///
/// Aliases are named after the *agent* — `claude-nhartley`, `claude-ikeller` — so a menu of
/// them asks the user to tell two logins apart by four characters in the middle of a word. The
/// address the CLI already records names the person instead.
@MainActor
final class AccountNameTests: XCTestCase {

    func testALocalPartBecomesAName() {
        XCTAssertEqual(AccountName.derived(fromEmail: "nova.hartley3@example.com"), "Nova Hartley")
        XCTAssertEqual(AccountName.derived(fromEmail: "ines.keller@example.com"), "Ines Keller")
    }

    /// Underscores, hyphens and plus-addressing are all separators people actually use.
    func testEverySeparatorSplitsWords() {
        XCTAssertEqual(AccountName.derived(fromEmail: "ada_lovelace@x.io"), "Ada Lovelace")
        XCTAssertEqual(AccountName.derived(fromEmail: "ada-lovelace@x.io"), "Ada Lovelace")
        XCTAssertEqual(AccountName.derived(fromEmail: "ada+work@x.io"), "Ada Work")
    }

    /// Digits on the end of a name are almost always "that address was taken", not a name.
    func testTrailingDigitsAreDropped() {
        XCTAssertEqual(AccountName.derived(fromEmail: "hartley99@x.io"), "Hartley")
        XCTAssertEqual(AccountName.derived(fromEmail: "2nova@x.io"), "Nova")
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
        XCTAssertEqual(AccountName.derived(fromEmail: "NOVA.HARTLEY@x.io"), "Nova Hartley")
        XCTAssertEqual(AccountName.derived(fromEmail: "mcDONALD@x.io"), "Mcdonald")
    }

    /// Automatic email naming is useful only until the user supplies the answer. In particular,
    /// `openai-01@…` derives to "Openai" and used to keep appearing beside the account image
    /// after Settings had accepted a different name.
    func testAnExplicitNameOutranksTheEmailDerivedName() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AccountNameTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let payload = Data(#"{"email":"openai-01@rinda.ventures"}"#.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let document: [String: Any] = [
            "tokens": ["id_token": "header.\(payload).signature"]
        ]
        try JSONSerialization.data(withJSONObject: document).write(
            to: directory.appendingPathComponent(AgentAccountDefaults.codexAuthMarker),
            options: .atomic
        )

        let account = AgentAccount(
            provider: .codex,
            handle: .named("codex-\(UUID().uuidString.lowercased())"),
            configPath: directory.path,
            displayName: "codex-rinda",
            displayNameOverride: "Rinda Work"
        )

        XCTAssertEqual(AccountName.names(for: [account])[account.id], "Rinda Work")
    }
}

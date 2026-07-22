import XCTest
@testable import Skalman

/// The diff highlighter's lexer. Pure, so every case that used to need a rendered pane to see
/// is a two-line assertion here.
final class SyntaxTests: XCTestCase {

    // MARK: - Helpers

    private func roles(_ line: String, _ language: SyntaxLanguage) -> [(SyntaxRole, String)] {
        var state = Syntax.State()
        return Syntax.tokens(in: line, language: language, state: &state)
            .map { ($0.role, String(line[$0.range])) }
    }

    private func assertRoles(
        _ line: String,
        _ language: SyntaxLanguage,
        _ expected: [(SyntaxRole, String)],
        file: StaticString = #filePath,
        line lineNumber: UInt = #line
    ) {
        let actual = roles(line, language)
        XCTAssertEqual(actual.map(\.1), expected.map(\.1), "text", file: file, line: lineNumber)
        XCTAssertEqual(
            actual.map { String(describing: $0.0) },
            expected.map { String(describing: $0.0) },
            "roles", file: file, line: lineNumber
        )
    }

    // MARK: - Language Detection

    func testExtensionPicksLanguage() {
        XCTAssertNotNil(Syntax.language(forPath: "Sources/App/Main.swift"))
        XCTAssertNotNil(Syntax.language(forPath: "web/index.ts"))
        XCTAssertNotNil(Syntax.language(forPath: "Makefile"))
        XCTAssertNotNil(Syntax.language(forPath: "deploy/Dockerfile"))
    }

    func testUnknownExtensionIsNotGuessed() {
        // A wrong guess colours half a line and reads as a bug in the diff; plain is honest.
        XCTAssertNil(Syntax.language(forPath: "README.md"))
        XCTAssertNil(Syntax.language(forPath: "notes.txt"))
        XCTAssertNil(Syntax.language(forPath: "LICENSE"))
        XCTAssertNil(Syntax.language(forPath: ""))
    }

    // MARK: - Swift

    func testSwiftDeclaration() {
        assertRoles(
            "    private let count: Int = 42",
            SyntaxLanguages.swift,
            [(.keyword, "private"), (.keyword, "let"), (.type, "Int"), (.number, "42")]
        )
    }

    func testSwiftStringIsOneToken() {
        assertRoles(
            #"let name = "let is not a keyword here""#,
            SyntaxLanguages.swift,
            [(.keyword, "let"), (.string, #""let is not a keyword here""#)]
        )
    }

    func testEscapedQuoteDoesNotEndTheString() {
        assertRoles(
            #"x = "a\"b" + 1"#,
            SyntaxLanguages.swift,
            [(.string, #""a\"b""#), (.number, "1")]
        )
    }

    func testUnterminatedStringEndsAtTheLine() {
        // Half a multi-line string is a normal thing to see in a diff.
        assertRoles(#"let a = "opening"#, SyntaxLanguages.swift, [(.keyword, "let"), (.string, #""opening"#)])
    }

    func testLineCommentSwallowsTheRest() {
        assertRoles(
            "let x = 1 // let y = 2",
            SyntaxLanguages.swift,
            [(.keyword, "let"), (.number, "1"), (.comment, "// let y = 2")]
        )
    }

    func testSigilledKeywords() {
        // `@` and `#` carry their identifier with them, so an attribute is one token and not a
        // stray symbol followed by a capitalized name read as a type.
        assertRoles(
            "@MainActor func go() {}",
            SyntaxLanguages.swift,
            [(.keyword, "@MainActor"), (.keyword, "func")]
        )
        assertRoles("#if DEBUG", SyntaxLanguages.swift, [(.keyword, "#if"), (.type, "DEBUG")])
    }

    // MARK: - Numbers

    func testNumberFormats() {
        for literal in ["0xFF", "1_000", "3.14", "1e-9"] {
            let tokens = roles("x = \(literal)", SyntaxLanguages.swift)
            XCTAssertEqual(tokens.map(\.1), [literal], literal)
        }
    }

    func testIdentifierContainingDigitsIsNotANumber() {
        XCTAssertTrue(roles("utf8Decoder = nil", SyntaxLanguages.swift).allSatisfy { $0.1 != "8" })
    }

    // MARK: - Block Comments

    func testBlockCommentClosingOnTheSameLine() {
        assertRoles(
            "let a = /* note */ 1",
            SyntaxLanguages.swift,
            [(.keyword, "let"), (.comment, "/* note */"), (.number, "1")]
        )
    }

    func testBlockCommentCarriesToTheNextLine() {
        var state = Syntax.State()
        _ = Syntax.tokens(in: "/* opening", language: SyntaxLanguages.swift, state: &state)
        XCTAssertTrue(state.inBlockComment)

        let middle = "let x = 1"
        let tokens = Syntax.tokens(in: middle, language: SyntaxLanguages.swift, state: &state)
        XCTAssertEqual(tokens.map { String(middle[$0.range]) }, [middle], "a commented-out line is a comment")

        let closing = "closing */ let y = 2"
        let closed = Syntax.tokens(in: closing, language: SyntaxLanguages.swift, state: &state)
        XCTAssertFalse(state.inBlockComment)
        XCTAssertEqual(
            closed.map { String(closing[$0.range]) },
            ["closing */", "let", "2"],
            "code resumes after the close"
        )
    }

    // MARK: - Other Languages

    func testPythonHashIsAComment() {
        assertRoles(
            "def f(): # not a directive",
            SyntaxLanguages.python,
            [(.keyword, "def"), (.comment, "# not a directive")]
        )
    }

    func testShellVariablesSurviveTheIdentifierScan() {
        let tokens = roles("export PATH=$HOME/bin", SyntaxLanguages.shell)
        XCTAssertEqual(tokens.map(\.1), ["export"])
    }

    func testJSONLiterals() {
        assertRoles(
            #"{"enabled": true, "count": 3}"#,
            SyntaxLanguages.json,
            [(.string, #""enabled""#), (.keyword, "true"), (.string, #""count""#), (.number, "3")]
        )
    }

    func testSQLIsCaseSensitiveToItsOwnTable() {
        // The keyword set is lowercase, which is what the parser was given; an uppercased
        // dialect simply renders plain rather than half-coloured.
        XCTAssertEqual(roles("select id from t", SyntaxLanguages.sql).map(\.1), ["select", "from"])
    }

    // MARK: - Robustness

    func testEmptyLineProducesNoTokens() {
        XCTAssertTrue(roles("", SyntaxLanguages.swift).isEmpty)
        XCTAssertTrue(roles("     ", SyntaxLanguages.swift).isEmpty)
    }

    func testNonASCIIRangesStayValid() {
        // Ranges are String.Index-based, so an emoji before a keyword must not shift the token.
        let line = "// 🎉 done"
        let tokens = roles(line, SyntaxLanguages.swift)
        XCTAssertEqual(tokens.map(\.1), [line])

        let mixed = #"let emoji = "🎉🎉" // tail"#
        XCTAssertEqual(roles(mixed, SyntaxLanguages.swift).map(\.1), ["let", #""🎉🎉""#, "// tail"])
    }
}

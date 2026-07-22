import XCTest
@testable import Skalman

/// Turning a config identifier into the name the composer's chip shows.
///
/// The chip said "Default model", which names the setting rather than the answer. These are the
/// identifiers actually found in the Claude and Codex configs on a real machine, so the mapping
/// is pinned against what the CLIs write rather than against what looks plausible.
final class ModelNameTests: XCTestCase {

    func testLongContextVariantsAreNamedAndMarked() {
        XCTAssertEqual(ModelName.display(for: "claude-fable-5[1m]"), "Fable 5 · 1M")
        XCTAssertEqual(ModelName.display(for: "opus[1m]"), "Opus · 1M")
    }

    func testPlainAliasesReadAsFamilies() {
        XCTAssertEqual(ModelName.display(for: "opus"), "Opus")
        XCTAssertEqual(ModelName.display(for: "sonnet"), "Sonnet")
        XCTAssertEqual(ModelName.display(for: "fable"), "Fable")
    }

    func testDatedIdentifiersReadAsTheirFamily() {
        XCTAssertEqual(ModelName.display(for: "claude-opus-4-8"), "Opus 4.8")
        XCTAssertEqual(ModelName.display(for: "claude-haiku-4-5-20251001"), "Haiku 4.5")
    }

    /// An identifier this does not know is handed back, not dropped. A model released after
    /// this table was written should read as itself — a wrong friendly name would be worse
    /// than an unfamiliar accurate one, since this string says what the session will cost.
    func testUnknownIdentifiersSurviveIntact() {
        XCTAssertEqual(ModelName.display(for: "gpt-5-codex"), "gpt-5-codex")
        XCTAssertEqual(ModelName.display(for: "o3-mini"), "o3-mini")
    }

    func testLongContextMarkSurvivesAnUnknownFamily() {
        XCTAssertEqual(ModelName.display(for: "some-future-model[1m]"), "some-future-model · 1M")
    }

    func testEmptyIdentifierIsLeftAlone() {
        XCTAssertEqual(ModelName.display(for: ""), "")
        XCTAssertEqual(ModelName.display(for: "   "), "   ")
    }
}

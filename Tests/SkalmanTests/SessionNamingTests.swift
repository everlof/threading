import XCTest
@testable import Skalman

final class SessionNamingTests: XCTestCase {

    // MARK: - Prompt Titles

    func testPromptTitleTakesTheFirstLine() {
        XCTAssertEqual(
            SessionNaming.promptTitle(from: "Fix the tests\nand then the build"),
            "Fix the tests"
        )
    }

    func testPromptTitleCapsLength() throws {
        let long = String(repeating: "word ", count: 40)
        let title = try XCTUnwrap(SessionNaming.promptTitle(from: long))
        XCTAssertLessThanOrEqual(title.count, ImportDefaults.titleLimit)
    }

    func testPromptTitleRejectsInjectedScaffolding() {
        XCTAssertNil(SessionNaming.promptTitle(from: "<command-name>/clear</command-name>"))
        XCTAssertNil(SessionNaming.promptTitle(from: "Caveat: the messages below were"))
    }

    func testPromptTitleRejectsEmptiness() {
        XCTAssertNil(SessionNaming.promptTitle(from: ""))
        XCTAssertNil(SessionNaming.promptTitle(from: "  \n  "))
    }

    // MARK: - Placeholder Detection

    func testAgentAndAccountNamesArePlaceholders() {
        for title in ["Claude Code", "Claude Code 2", "claude code 10"] {
            XCTAssertTrue(
                SessionNaming.isPlaceholderTitle(title, kind: .claude, accountDisplayName: nil),
                title
            )
        }

        XCTAssertTrue(SessionNaming.isPlaceholderTitle(
            "claudedb 3", kind: .claude, accountDisplayName: "claudedb"
        ))
        XCTAssertTrue(SessionNaming.isPlaceholderTitle(
            "Codex", kind: .codex, accountDisplayName: nil
        ))
    }

    func testGenericLabelsArePlaceholders() {
        for title in ["", "New Session", "Side Chat"] {
            XCTAssertTrue(
                SessionNaming.isPlaceholderTitle(title, kind: .claude, accountDisplayName: nil),
                title
            )
        }
    }

    func testOnlyAgentAndAccountNamesAreAgentDerived() {
        // The backfill clears these outright; a generic label is also a placeholder but
        // beats the fallback it would be cleared to, so it must not count as agent-derived.
        XCTAssertTrue(SessionNaming.isAgentDerivedTitle(
            "Claude Code 2", kind: .claude, accountDisplayName: nil
        ))
        XCTAssertTrue(SessionNaming.isAgentDerivedTitle(
            "claudedb 3", kind: .claude, accountDisplayName: "claudedb"
        ))

        for title in ["", "New Session", "Side Chat", "Fix the tests"] {
            XCTAssertFalse(
                SessionNaming.isAgentDerivedTitle(title, kind: .claude, accountDisplayName: nil),
                title
            )
        }
    }

    func testRealTitlesAreNotPlaceholders() {
        for title in ["Fix favicon discovery", "Claude Code keeps crashing on launch"] {
            XCTAssertFalse(
                SessionNaming.isPlaceholderTitle(title, kind: .claude, accountDisplayName: nil),
                title
            )
        }
    }

    // MARK: - Noise Detection

    func testProductAndProjectNamesAreNoise() {
        for title in ["Claude Code", "claude", "sonda", "checkout-dir"] {
            XCTAssertTrue(SessionNaming.isNoiseTitle(
                title,
                kind: .claude,
                accountDisplayName: nil,
                projectName: "sonda",
                folderBasename: "checkout-dir"
            ), title)
        }
    }

    func testARealAgentTitleIsNotNoise() {
        XCTAssertFalse(SessionNaming.isNoiseTitle(
            "Add favicon discovery for projects",
            kind: .claude,
            accountDisplayName: "claudedb",
            projectName: "sonda",
            folderBasename: "sonda"
        ))
    }

    // MARK: - Claude Transcript Titles

    func testTheLastAITitleWins() throws {
        let url = try writeTranscript([
            #"{"type":"ai-title","aiTitle":"First name"}"#,
            #"{"type":"user","message":{"content":"hello"}}"#,
            #"{"type":"ai-title","aiTitle":"Second name"}"#
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(SessionNaming.claudeTranscriptTitle(at: url), "Second name")
    }

    func testACustomTitleOutranksAnyAITitle() throws {
        // After a /rename the CLI keeps re-appending *both* records, interleaved — presence
        // decides, not order.
        let url = try writeTranscript([
            #"{"type":"ai-title","aiTitle":"Generated"}"#,
            #"{"type":"custom-title","customTitle":"Chosen"}"#,
            #"{"type":"ai-title","aiTitle":"Generated"}"#
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(SessionNaming.claudeTranscriptTitle(at: url), "Chosen")
    }

    func testTitleIsFoundInTheTailOfALongTranscript() throws {
        // The window opens mid-record; the partial first line must be dropped, not parsed.
        var lines = fillerRecords(totalBytes: SessionNamingDefaults.titleTailBytes * 2)
        lines.append(#"{"type":"ai-title","aiTitle":"Near the end"}"#)

        let url = try writeTranscript(lines)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(SessionNaming.claudeTranscriptTitle(at: url), "Near the end")
    }

    func testTitleBuriedBeyondTheTailIsStillFound() throws {
        // One enormous turn appended since the last title record: the tail misses it and the
        // whole-file scan is the net underneath.
        var lines = [#"{"type":"ai-title","aiTitle":"Early and only"}"#]
        lines.append(contentsOf: fillerRecords(
            totalBytes: SessionNamingDefaults.titleTailBytes * 2
        ))

        let url = try writeTranscript(lines)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(SessionNaming.claudeTranscriptTitle(at: url), "Early and only")
    }

    func testAMissingTranscriptHasNoTitle() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        XCTAssertNil(SessionNaming.claudeTranscriptTitle(at: url))
    }

    // MARK: - Display Precedence

    @MainActor
    func testDisplayTitlePrefersCustomThenAgentThenPrompt() {
        withAgentTitlesEnabled {
            var session = AgentSession(kind: .claude, title: "Fix the tests")
            XCTAssertEqual(session.displayTitle, "Fix the tests")

            session.agentTitle = "Repairing the test suite"
            XCTAssertEqual(session.displayTitle, "Repairing the test suite")

            session.customTitle = "My name"
            XCTAssertEqual(session.displayTitle, "My name")
        }
    }

    @MainActor
    func testAnUnnamedSessionDisplaysTheGenericLabelNeverTheAgent() {
        withAgentTitlesEnabled {
            let session = AgentSession(kind: .claude, title: "")
            XCTAssertEqual(session.displayTitle, AgentDefaults.untitledSessionName)
        }
    }

    // MARK: - Launch Names

    func testOnlyAnExplicitRenameIsForwardedToTheLaunch() {
        var session = AgentSession(kind: .claude, title: "Fix the tests")
        session.agentTitle = "Repairing the test suite"

        // Anything less deliberate than the user's own choice would mark the conversation
        // custom-titled in the CLI and switch off its own title generation.
        XCTAssertNil(session.launchName)

        session.customTitle = "My name"
        XCTAssertEqual(session.launchName, "My name")
    }

    // MARK: - Helpers

    private func writeTranscript(_ lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionNamingTests-\(UUID().uuidString)")
            .appendingPathExtension("jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Ordinary conversation records adding up to at least `totalBytes`.
    private func fillerRecords(totalBytes: Int) -> [String] {
        let text = String(repeating: "x", count: 1024)
        let line = #"{"type":"assistant","message":{"content":"\#(text)"}}"#
        return Array(repeating: line, count: totalBytes / line.count + 1)
    }

    /// Runs `body` with the sidebar's agent-title preference on, restoring the default's
    /// registered state afterwards so other tests see what they always saw.
    @MainActor
    private func withAgentTitlesEnabled(_ body: () -> Void) {
        let key = "usesTerminalTitleInSidebar"
        let previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(true, forKey: key)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        body()
    }
}

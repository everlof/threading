import XCTest
@testable import Threading

/// The commit draft's judgement, tested without a process: what the agent is asked, and how
/// its answer is read. The parsing pins the part a Codex release would break.
final class CommitMessageComposerTests: XCTestCase {

    // MARK: - Prompt

    func testThePromptCarriesTheVoiceSampleAndTheDiff() {
        let prompt = CommitMessageComposer.prompt(
            stagedDiff: "diff --git a/File.swift b/File.swift",
            recentSubjects: ["Weigh the pane seam", "Answer the terminal's own colour query"]
        )

        XCTAssertTrue(prompt.contains("- Weigh the pane seam"))
        XCTAssertTrue(prompt.contains("diff --git a/File.swift"))
        XCTAssertTrue(prompt.contains("subject line"))
    }

    func testAnOversizedDiffIsTruncatedAndSaysSo() {
        let huge = String(repeating: "x", count: CommitDraftDefaults.diffCharacterCap + 500)
        let prompt = CommitMessageComposer.prompt(stagedDiff: huge, recentSubjects: [])

        XCTAssertTrue(prompt.contains("… (truncated)"))
        XCTAssertLessThan(prompt.count, CommitDraftDefaults.diffCharacterCap + 1_000)
    }

    func testAnEmptyVoiceSampleAsksForNoVoice() {
        let prompt = CommitMessageComposer.prompt(stagedDiff: "diff", recentSubjects: [])
        XCTAssertFalse(prompt.contains("recent commit subjects"))
    }

    // MARK: - Answer Cleanup

    func testCleanupSurvivesFencesQuotesAndPreamble() {
        // Models still fence, quote, and preface even when told not to.
        XCTAssertEqual(
            CommitMessageComposer.cleaned("```\nFix the flaky Quick Look test\n```"),
            "Fix the flaky Quick Look test"
        )
        XCTAssertEqual(
            CommitMessageComposer.cleaned("\"Restore the backplate fix\""),
            "Restore the backplate fix"
        )
        XCTAssertEqual(
            CommitMessageComposer.cleaned("\n\n  Keep the sidebar mark its size  \n\nBody."),
            "Keep the sidebar mark its size"
        )
    }

    // MARK: - JSONL

    func testTheLastAgentMessageWins() {
        let output = """
        {"type":"item.completed","item":{"type":"agent_message","text":"First thought"}}
        not json at all
        {"type":"item.completed","item":{"type":"command_execution","text":"ls"}}
        {"type":"item.completed","item":{"type":"agent_message","text":"Final answer"}}
        """

        XCTAssertEqual(
            CommitMessageComposer.finalAgentMessage(fromJSONL: output),
            "Final answer"
        )
    }

    func testNoAgentMessageMeansNoAnswer() {
        XCTAssertNil(CommitMessageComposer.finalAgentMessage(fromJSONL: "{\"type\":\"other\"}"))
    }
}

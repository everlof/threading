import XCTest
@testable import Threading

/// The AI settings search's contract with two CLIs and one catalogue: what the run is asked,
/// how its answer is dug out of a merged capture, and which of its claims the catalogue lets
/// through. All of it is string-shaped and silently breakable, which is why each piece is
/// pinned rather than trusted.
@MainActor
final class SettingsSearchResearchTests: XCTestCase {

    // MARK: - The prompt

    /// What the run is asked is a decision worth pinning: the tool it must call, the reply
    /// shape it must use, and the user's own words, verbatim.
    func testThePromptCarriesTheQueryTheToolAndTheReplyShape() {
        let prompt = SettingsSearchResearch.prompt(query: "stop it flashing when done")

        XCTAssertTrue(prompt.contains("stop it flashing when done"))
        XCTAssertTrue(prompt.contains("list_settings"))
        XCTAssertTrue(prompt.contains(#"{"matches":["#))
        XCTAssertTrue(
            prompt.contains(#""setting""#),
            "the prompt has to offer the setting-level answer or every reply stays page-level"
        )
        XCTAssertTrue(
            prompt.contains(#"{"matches":[]}"#),
            "the prompt never said an empty answer is allowed, so the model will invent one"
        )
    }

    // MARK: - Reading the answer

    /// Claude's `--print --output-format json` envelope arrives merged with whatever the CLI
    /// wrote to stderr, so the reader scans lines for the envelope rather than parsing the
    /// whole capture.
    func testAClaudeEnvelopeIsFoundAmongStderrNoise() {
        let output = """
        some stderr warning about a deprecated flag
        {"type":"result","subtype":"success","result":"{\\"matches\\":[{\\"page\\":\\"general\\",\\"reason\\":\\"r\\"}]}","is_error":false}
        """

        let answer = SettingsSearchResearch.answerText(fromOutput: output, kind: .claude)
        XCTAssertEqual(answer, #"{"matches":[{"page":"general","reason":"r"}]}"#)
    }

    /// The Codex reader is `CommitMessageComposer`'s, shared on purpose — one copy of the
    /// parsing a Codex release would break. This pins only that the research path reaches it.
    func testACodexAnswerIsTheLastCompletedAgentMessage() {
        let output = """
        {"type":"item.completed","item":{"type":"agent_message","text":"thinking aloud"}}
        {"type":"item.completed","item":{"type":"agent_message","text":"{\\"matches\\":[]}"}}
        """

        let answer = SettingsSearchResearch.answerText(fromOutput: output, kind: .codex)
        XCTAssertEqual(answer, #"{"matches":[]}"#)
    }

    /// Models fence, preface and apologise even when told not to. The JSON is taken from the
    /// first `{` to the last `}`, so all of that survives — and a reply with no object in it
    /// is an honest nil rather than an empty success.
    func testMatchesSurviveFencesAndProseAroundTheJSON() {
        let dressed = """
        Sure! Here is the JSON you asked for:
        ```json
        {"matches":[{"page":"themes","reason":"Text size lives here."}]}
        ```
        """

        XCTAssertEqual(
            SettingsSearchResearch.rawMatches(fromAnswer: dressed),
            [SettingsSearchResearch.RawMatch(page: "themes", reason: "Text size lives here.")]
        )
        XCTAssertEqual(
            SettingsSearchResearch.rawMatches(fromAnswer: #"{"matches":[]}"#),
            []
        )
        XCTAssertNil(SettingsSearchResearch.rawMatches(fromAnswer: "I could not decide."))
    }

    // MARK: - Validation

    /// Only pages the catalogue vouches for reach the UI: an invented id is dropped, and a
    /// model that answered with the title it showed the user gets one more chance as a title.
    func testValidationKeepsCataloguePagesAndResolvesTitles() {
        let matches = SettingsSearchResearch.validated([
            .init(page: SettingsPages.generalID, reason: "Notifications live here."),
            .init(page: "made-up-page", reason: "x"),
            .init(page: "Themes", reason: "Text size lives here.")
        ])

        XCTAssertEqual(matches.map(\.pageID), [SettingsPages.generalID, SettingsPages.themesID])
        XCTAssertEqual(matches.first?.reason, "Notifications live here.")
        XCTAssertEqual(matches.first?.title, SettingsPages.page(id: SettingsPages.generalID)?.title)
    }

    /// A named setting is vouched for against the page's own entries — case-insensitively,
    /// since a model may re-case what it read — and an invented one degrades to the page
    /// rather than promising a scroll to a row that does not exist.
    func testValidationResolvesSettingsAndDegradesInventedOnes() throws {
        let silence = L10n.string("Silence every sound")
        let matches = SettingsSearchResearch.validated([
            .init(page: SettingsPages.generalID, setting: silence.lowercased(), reason: "mute"),
            .init(page: SettingsPages.generalID, setting: "No Such Setting", reason: "x")
        ])

        XCTAssertEqual(matches.count, 2, "two destinations on one page are two answers")
        let resolved = try XCTUnwrap(matches.first)
        XCTAssertEqual(resolved.settingTitle, silence, "resolved to the catalogue's spelling")
        XCTAssertEqual(
            resolved.settingSection, L10n.string("Silence"),
            "the section travels with the setting so the row can print the path"
        )
        let degraded = try XCTUnwrap(matches.last)
        XCTAssertNil(degraded.settingTitle)
        XCTAssertEqual(degraded.pageID, SettingsPages.generalID)
    }

    /// A repeated page is one suggestion, and more than four stops being an answer — the cap
    /// the prompt asks for, enforced rather than trusted.
    func testValidationDeduplicatesAndCapsTheAnswer() {
        let everything = SettingsPages.builtIn.map {
            SettingsSearchResearch.RawMatch(page: $0.id, reason: nil)
        }
        XCTAssertEqual(
            SettingsSearchResearch.validated(everything + everything).count,
            SettingsResearchDefaults.maximumMatches
        )

        let repeated = SettingsSearchResearch.validated([
            .init(page: SettingsPages.generalID, reason: "first"),
            .init(page: SettingsPages.generalID, reason: "second")
        ])
        XCTAssertEqual(repeated.map(\.reason), ["first"])
    }
}

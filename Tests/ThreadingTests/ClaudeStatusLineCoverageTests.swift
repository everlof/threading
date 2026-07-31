import XCTest
@testable import Threading

/// Covers how Threading decides which facts an account's Claude `statusLine` already shows, so
/// the session's status card can add the rest instead of repeating them.
///
/// The decision is a search for values Threading already holds, not a parse of the line, and the
/// direction it fails in is the point: an unrecognised rendering reads as *not covered*, which
/// duplicates a fact rather than hiding one.
final class ClaudeStatusLineCoverageTests: XCTestCase {

    // MARK: - Fixtures

    /// The real output of the status line on the machine this was written against, colours and
    /// all, for the payload in `facts` below. Kept verbatim: the escapes are the thing being
    /// defended against, so a hand-cleaned copy would test nothing.
    private static let colouredLine = """
        \u{1B}[38;2;0;153;255mOpus 5\u{1B}[0m \u{1B}[2m|\u{1B}[0m \
        \u{1B}[38;2;46;149;153mAnotherTerminal\u{1B}[0m\u{1B}[2m@\u{1B}[0m\
        \u{1B}[38;2;0;160;0mtest-levels-and-sidebar-archive\u{1B}[0m \
        \u{1B}[2m(\u{1B}[0m\u{1B}[38;2;0;160;0m+1699\u{1B}[0m \u{1B}[38;2;255;85;85m-331\u{1B}[0m\
        \u{1B}[2m)\u{1B}[0m \u{1B}[2m|\u{1B}[0m \u{1B}[38;2;255;176;85m135k/1.0m\u{1B}[0m \
        \u{1B}[2m|\u{1B}[0m effort: \u{1B}[38;2;0;160;0mhigh\u{1B}[0m
        """

    /// What `~/.claude-dblock` actually draws: a bridge with no forward config, usage only.
    private static let usageOnlyLine = "Claude · 5h 21% · 7d 28%"

    private func facts(
        model: String? = "Opus 5",
        effort: String? = "high",
        fastMode: Bool? = false,
        branch: String? = "test-levels-and-sidebar-archive",
        added: Int? = 1699,
        removed: Int? = 331
    ) -> ClaudeStatusLineCoverage.Facts {
        var facts = ClaudeStatusLineCoverage.Facts(
            workingDirectory: "/Users/example/repo/AnotherTerminal",
            projectDirectory: "/Users/example/repo/AnotherTerminal"
        )
        facts.modelIdentifier = "claude-opus-5"
        facts.modelDisplayName = model
        facts.effort = effort
        facts.fastMode = fastMode
        facts.branch = branch
        facts.linesAdded = added
        facts.linesRemoved = removed
        return facts
    }

    // MARK: - Escape Stripping

    /// A truecolor escape wraps the model name, so a match against the raw bytes would miss it.
    func testColourIsRemovedBeforeAnythingIsMatched() {
        let stripped = ClaudeStatusLineCoverage.strippingANSI(Self.colouredLine)

        XCTAssertFalse(stripped.contains("\u{1B}"), "no escape may survive stripping")
        XCTAssertFalse(stripped.contains("38;2;"), "SGR parameters must go with their escape")
        XCTAssertTrue(stripped.contains("Opus 5"))
        XCTAssertTrue(stripped.contains("test-levels-and-sidebar-archive"))
    }

    func testStrippingLeavesPlainTextExactlyAsItWas() {
        XCTAssertEqual(
            ClaudeStatusLineCoverage.strippingANSI(Self.usageOnlyLine),
            Self.usageOnlyLine
        )
    }

    /// A lone escape with no CSI, and a truncated sequence, must not eat the rest of the line or
    /// spin: the input is another program's stdout and carries no guarantees.
    func testMalformedEscapesDoNotConsumeTheLine() {
        XCTAssertEqual(ClaudeStatusLineCoverage.strippingANSI("a\u{1B}b"), "ab")
        XCTAssertEqual(ClaudeStatusLineCoverage.strippingANSI("a\u{1B}[38;2;0"), "a")
        XCTAssertEqual(ClaudeStatusLineCoverage.strippingANSI("\u{1B}[0mx"), "x")
    }

    // MARK: - Coverage

    /// The rich line: everything the card would add is already on screen, so it adds nothing.
    func testARichStatusLineCoversEveryFactTheCardWouldAdd() {
        let coverage = ClaudeStatusLineCoverage.coverage(
            inOutput: ClaudeStatusLineCoverage.strippingANSI(Self.colouredLine),
            facts: facts()
        )

        XCTAssertTrue(coverage.isConfigured)
        XCTAssertTrue(coverage.model, "the line prints \"Opus 5\"")
        XCTAssertTrue(coverage.effort, "the line prints \"effort: high\"")
        XCTAssertTrue(coverage.branch)
        XCTAssertTrue(coverage.changes, "+1699 -331 is the pair the line prints")
    }

    /// `~/.claude-dblock`: usage only, so the card owes the user model, effort, branch and
    /// changes — which is the whole reason this exists.
    func testAUsageOnlyStatusLineCoversNothingTheCardShows() {
        let coverage = ClaudeStatusLineCoverage.coverage(
            inOutput: Self.usageOnlyLine,
            facts: facts()
        )

        XCTAssertTrue(coverage.isConfigured)
        XCTAssertFalse(coverage.model)
        XCTAssertFalse(coverage.effort)
        XCTAssertFalse(coverage.branch)
        XCTAssertFalse(coverage.changes)
        XCTAssertFalse(coverage.coversEverything)
    }

    /// The word "Claude" is in that line, and the model is not. Matching the *account's* name or
    /// the CLI's name for the model identifier would read as covered and hide the one fact the
    /// user said they miss.
    func testTheWordClaudeIsNotAModelReading() {
        let coverage = ClaudeStatusLineCoverage.coverage(
            inOutput: "Claude · 5h 21% · 7d 28%",
            facts: facts(model: "Opus 5")
        )

        XCTAssertFalse(coverage.model)
    }

    /// Off is indistinguishable from absent — there is no word to look for — so fast mode is only
    /// ever reported as covered when it is on.
    func testFastModeOffIsNeverReportedAsCovered() {
        let onScreen = "Opus 5 | fast | main"

        XCTAssertFalse(
            ClaudeStatusLineCoverage.coverage(
                inOutput: onScreen,
                facts: facts(fastMode: false)
            ).fastMode
        )
        XCTAssertTrue(
            ClaudeStatusLineCoverage.coverage(
                inOutput: onScreen,
                facts: facts(fastMode: true)
            ).fastMode
        )
    }

    /// A token total of "135k/1.0m" contains no diff pair, and a bare number elsewhere must not
    /// pass for one: the counts are matched as the pair a numstat summary prints.
    func testABareNumberIsNotADiffStat() {
        XCTAssertFalse(
            ClaudeStatusLineCoverage.coverage(
                inOutput: "Opus 5 | 1699 tokens",
                facts: facts(added: 1699, removed: 331)
            ).changes,
            "1699 without its +, and without the removal, is not a diff reading"
        )
    }

    /// A clean checkout has no counts to print, so nothing can be matched and the card has
    /// nothing to add either. Reporting "covered" here would be true but meaningless; reporting
    /// "not covered" must not make the card show "+0 -0".
    func testACleanCheckoutReportsNoChangeCoverage() {
        XCTAssertFalse(
            ClaudeStatusLineCoverage.coverage(
                inOutput: Self.colouredLine,
                facts: facts(added: 0, removed: 0)
            ).changes
        )
    }

    /// Short values are noise: a two-character branch name would be found inside some unrelated
    /// number on the line.
    func testValuesTooShortToBeDistinctAreNotMatched() {
        XCTAssertFalse(
            ClaudeStatusLineCoverage.coverage(
                inOutput: "5h 21% · 7d 28%",
                facts: facts(model: nil, effort: nil, branch: "5h")
            ).branch
        )
    }

    /// Matching is case-insensitive: a script may upper-case a branch or a model name.
    func testMatchingIgnoresCase() {
        XCTAssertTrue(
            ClaudeStatusLineCoverage.coverage(
                inOutput: "OPUS 5 | MAIN",
                facts: facts(model: "Opus 5", branch: "main")
            ).model
        )
    }

    /// An account with no `statusLine` — `~/.claude-science` here — and every failure mode land
    /// on the same answer, so a caller has one state to handle.
    func testNoStatusLineCoversNothing() {
        let none = ClaudeStatusLineCoverage.Coverage.none

        XCTAssertFalse(none.isConfigured)
        XCTAssertFalse(none.model)
        XCTAssertFalse(none.coversEverything)
    }

    // MARK: - Suppression

    /// The wrapper the launcher writes when the user hides the line: the command survives
    /// whole — a pipeline or list wraps as one group — and neither stdout nor stderr reaches
    /// the terminal. The shape was verified against the real Claudex bridge, which kept
    /// writing its cache while printing nothing.
    func testSilencingWrapsTheWholeCommandAndBothStreams() {
        XCTAssertEqual(
            ClaudeStatusLineCoverage.silencedCommand(wrapping: "statusline.sh"),
            "{ statusline.sh ; } >/dev/null 2>&1"
        )
        XCTAssertEqual(
            ClaudeStatusLineCoverage.silencedCommand(wrapping: "read x | jq . && echo done"),
            "{ read x | jq . && echo done ; } >/dev/null 2>&1"
        )
    }

    /// Resolution follows the CLI's own layer order, most-specific-first: a project's
    /// `.claude/settings.local.json` beats its `settings.json`, which beats the account's.
    /// Only `type: "command"` resolves — any other shape draws nothing, so there is nothing
    /// to silence.
    func testResolutionFollowsTheSettingsLayers() throws {
        // A managed policy replaces every writable layer outright, so on a machine that has
        // one this test would truthfully resolve the managed command and prove nothing.
        try XCTSkipIf(
            FileManager.default.fileExists(atPath: ClaudeSettingsDefaults.managedSettingsPath),
            "managed settings replace the layers under test"
        )

        let account = try makeDirectory(named: "coverage-account")
        let project = try makeDirectory(named: "coverage-project")
        defer {
            try? FileManager.default.removeItem(at: account)
            try? FileManager.default.removeItem(at: project)
        }

        func write(_ json: String, to url: URL) throws {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(json.utf8).write(to: url)
        }

        let fixture = AgentAccount(
            provider: .claude,
            handle: .named("coverage"),
            configPath: account.path
        )

        // Only the account layer: its command resolves.
        try write(
            #"{"statusLine": {"type": "command", "command": "account-line"}}"#,
            to: account.appendingPathComponent("settings.json")
        )
        XCTAssertEqual(
            ClaudeStatusLineCoverage.resolvedCommand(
                account: fixture,
                projectDirectory: project.path
            ),
            "account-line"
        )

        // A project layer overrides the account's.
        try write(
            #"{"statusLine": {"type": "command", "command": "project-line"}}"#,
            to: project.appendingPathComponent(".claude/settings.json")
        )
        XCTAssertEqual(
            ClaudeStatusLineCoverage.resolvedCommand(
                account: fixture,
                projectDirectory: project.path
            ),
            "project-line"
        )

        // The local file overrides both.
        try write(
            #"{"statusLine": {"type": "command", "command": "local-line"}}"#,
            to: project.appendingPathComponent(".claude/settings.local.json")
        )
        XCTAssertEqual(
            ClaudeStatusLineCoverage.resolvedCommand(
                account: fixture,
                projectDirectory: project.path
            ),
            "local-line"
        )

        // A shape that draws nothing resolves nothing — that layer simply does not count.
        try write(
            #"{"statusLine": {"type": "static", "text": "hello"}}"#,
            to: project.appendingPathComponent(".claude/settings.local.json")
        )
        XCTAssertEqual(
            ClaudeStatusLineCoverage.resolvedCommand(
                account: fixture,
                projectDirectory: project.path
            ),
            "project-line",
            "a non-command layer is skipped, not resolved as empty"
        )
    }

    private func makeDirectory(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

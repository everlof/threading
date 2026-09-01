import XCTest
@testable import Threading

/// Covers what `AgentModels` reads out of the agent CLIs' own files, now that it remembers each
/// file per write rather than per call.
///
/// Caching a provider's file is only safe if the answer cannot go stale, so every case here is
/// really the same question asked twice: does the second read still tell the truth after the CLI
/// has rewritten the file underneath it?
final class ProviderSettingsReadingTests: XCTestCase {

    // MARK: - Fixtures

    private var configPath: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        configPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-settings-reading-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: configPath, withIntermediateDirectories: true)
        AgentModels.forgetCachedProviderFiles()
    }

    override func tearDown() {
        if let configPath { try? FileManager.default.removeItem(at: configPath) }
        AgentModels.forgetCachedProviderFiles()
        super.tearDown()
    }

    private func account(_ kind: AgentKind) -> AgentAccount {
        AgentAccount(provider: kind, handle: .named("fixture"), configPath: configPath.path)
    }

    private func write(_ contents: String, named name: String) throws {
        try Data(contents.utf8).write(to: configPath.appendingPathComponent(name))
    }

    private func claudeState(additionalModels: [String]) -> String {
        let entries = additionalModels
            .map { #"{"value": "\#($0)", "label": "\#($0) label"}"# }
            .joined(separator: ",")
        return #"{"\#(AgentDefaults.claudeAdditionalModelsKey)": [\#(entries)]}"#
    }

    // MARK: - Claude state

    /// The extra models a login may select come out of `.claude.json`, and a rewrite of it is
    /// visible on the very next read. This is the file that used to be re-parsed on every 200
    /// bytes of agent output.
    func testTheExtraModelListFollowsRewritesOfTheStateFile() throws {
        let account = account(.claude)

        try write(claudeState(additionalModels: ["claude-fable-5[1m]"]), named: AgentDefaults.claudeStateFile)
        var identifiers = AgentModels.available(for: .claude, account: account)
        XCTAssertTrue(
            identifiers.contains("claude-fable-5[1m]"),
            "a model only the CLI's cache names must still reach the menu"
        )

        try write(claudeState(additionalModels: ["some-new-grant"]), named: AgentDefaults.claudeStateFile)
        identifiers = AgentModels.available(for: .claude, account: account)
        XCTAssertTrue(identifiers.contains("some-new-grant"), "a rewrite must be read immediately")
        XCTAssertFalse(
            identifiers.contains("claude-fable-5[1m]"),
            "a model the login no longer offers must stop being offered"
        )
    }

    /// The documented aliases stand alone when the CLI has never written a state file, rather
    /// than the absent file emptying the menu.
    func testTheDocumentedAliasesSurviveAnAbsentStateFile() {
        let identifiers = AgentModels.available(for: .claude, account: account(.claude))
        for alias in AgentDefaults.claudeModels {
            XCTAssertTrue(identifiers.contains(alias), "\(alias) is a documented alias")
        }
    }

    // MARK: - Claude settings

    func testAConfiguredSettingFollowsRewritesOfTheSettingsFile() throws {
        let account = account(.claude)

        try write(#"{"\#(AgentDefaults.claudeEffortKey)": "high"}"#, named: AgentDefaults.claudeSettingsFile)
        XCTAssertEqual(AgentModels.defaultEffort(for: .claude, account: account), "high")

        try write(#"{"\#(AgentDefaults.claudeEffortKey)": "low"}"#, named: AgentDefaults.claudeSettingsFile)
        XCTAssertEqual(AgentModels.defaultEffort(for: .claude, account: account), "low")
    }

    /// An empty string is not a setting. It was refused when the file was scanned per key, and
    /// collecting the keys up front must not turn it into an answer.
    func testAnEmptySettingReadsAsAbsent() throws {
        try write(#"{"\#(AgentDefaults.claudeEffortKey)": ""}"#, named: AgentDefaults.claudeSettingsFile)
        XCTAssertNil(AgentModels.defaultEffort(for: .claude, account: account(.claude)))
    }

    /// A non-string value is absent rather than coerced — `as? String` failing is what refused it
    /// before, and collecting only the strings has to refuse it the same way.
    func testANonStringSettingReadsAsAbsent() throws {
        try write(#"{"\#(AgentDefaults.claudeEffortKey)": 7}"#, named: AgentDefaults.claudeSettingsFile)
        XCTAssertNil(AgentModels.defaultEffort(for: .claude, account: account(.claude)))
    }

    // MARK: - Codex config.toml

    func testATopLevelScalarIsReadAndUnquoted() throws {
        try write("model = \"gpt-5-codex\"\n", named: AgentDefaults.codexConfigFile)
        XCTAssertEqual(
            AgentModels.configuredCodexValue(AgentDefaults.codexModelKey, account: account(.codex)),
            "gpt-5-codex"
        )
    }

    /// A longer key that merely starts with the one being asked for is a different key.
    func testAKeyIsNotSatisfiedByALongerOne() throws {
        try write("model_provider = \"openai\"\n", named: AgentDefaults.codexConfigFile)
        XCTAssertNil(
            AgentModels.configuredCodexValue(AgentDefaults.codexModelKey, account: account(.codex))
        )
    }

    /// The previous reader returned at its first match, so a duplicate key later in the file
    /// never won. Collecting the file into a dictionary must keep that order.
    func testTheFirstAssignmentOfAKeyWins() throws {
        try write("model = \"first\"\nmodel = \"second\"\n", named: AgentDefaults.codexConfigFile)
        XCTAssertEqual(
            AgentModels.configuredCodexValue(AgentDefaults.codexModelKey, account: account(.codex)),
            "first"
        )
    }

    /// And it returned nil at that first match when the value was empty, rather than carrying on
    /// to a later assignment. Empty is therefore collected and refused at the lookup.
    func testAnEmptyFirstAssignmentRefusesRatherThanFallingThrough() throws {
        try write("model = \"\"\nmodel = \"later\"\n", named: AgentDefaults.codexConfigFile)
        XCTAssertNil(
            AgentModels.configuredCodexValue(AgentDefaults.codexModelKey, account: account(.codex))
        )
    }

    /// A commented-out assignment is not an assignment.
    func testACommentedAssignmentIsIgnored() throws {
        try write("# model = \"commented\"\nmodel = \"real\"\n", named: AgentDefaults.codexConfigFile)
        XCTAssertEqual(
            AgentModels.configuredCodexValue(AgentDefaults.codexModelKey, account: account(.codex)),
            "real"
        )
    }

    /// A `[table]` header carries no `=` and must not be mistaken for one.
    func testATableHeaderIsNotAnAssignment() throws {
        try write("[profiles.work]\nmodel = \"in-table\"\n", named: AgentDefaults.codexConfigFile)
        XCTAssertEqual(
            AgentModels.configuredCodexValue(AgentDefaults.codexModelKey, account: account(.codex)),
            "in-table",
            "the previous reader matched a key wherever it appeared; that behaviour is preserved"
        )
    }

    func testAConfiguredCodexValueFollowsRewrites() throws {
        let account = account(.codex)
        try write("model = \"first\"\n", named: AgentDefaults.codexConfigFile)
        XCTAssertEqual(
            AgentModels.configuredCodexValue(AgentDefaults.codexModelKey, account: account),
            "first"
        )

        try write("model = \"second-model\"\n", named: AgentDefaults.codexConfigFile)
        XCTAssertEqual(
            AgentModels.configuredCodexValue(AgentDefaults.codexModelKey, account: account),
            "second-model",
            "a rewritten config must be read immediately"
        )
    }
}

import XCTest
@testable import Threading

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

    func testClaudeEffortComesFromTheRoutedAccountsSettings() throws {
        let directory = try temporaryAccountDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(#"{"model":"opus","effortLevel":"xhigh"}"#.utf8).write(
            to: directory.appendingPathComponent(AgentDefaults.claudeSettingsFile)
        )
        let account = AgentAccount(
            provider: .claude,
            handle: .standard,
            configPath: directory.path
        )

        XCTAssertEqual(AgentModels.defaultEffort(for: .claude, account: account), "xhigh")
    }

    func testCodexEffortComesFromTheRoutedAccountsConfig() throws {
        let directory = try temporaryAccountDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("""
            model = "gpt-5.6-sol"
            model_reasoning_effort = "high"
            """.utf8).write(
                to: directory.appendingPathComponent(AgentDefaults.codexConfigFile)
            )
        let account = AgentAccount(
            provider: .codex,
            handle: .standard,
            configPath: directory.path
        )

        XCTAssertEqual(AgentModels.defaultEffort(for: .codex, account: account), "high")
    }

    func testCodexModelsAndFastTierComeFromTheRoutedAccountsCatalog() throws {
        let directory = try temporaryAccountDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("""
            {
              "models": [
                {
                  "slug": "gpt-visible",
                  "display_name": "GPT Visible",
                  "visibility": "list",
                  "additional_speed_tiers": ["fast"],
                  "service_tiers": [
                    {"id": "priority-v2", "name": "Fast", "description": "Quick"}
                  ],
                  "default_service_tier": "priority-v2",
                  "default_reasoning_level": "low",
                  "supported_reasoning_levels": [
                    {"effort": "low", "description": "Quick work"},
                    {"effort": "xhigh", "description": "Deep work"},
                    {"effort": "max", "description": "Hardest work"},
                    {"effort": "ultra", "description": "Delegated work"}
                  ]
                },
                {
                  "slug": "gpt-hidden",
                  "display_name": "GPT Hidden",
                  "visibility": "hide"
                }
              ]
            }
            """.utf8).write(
                to: directory.appendingPathComponent(AgentDefaults.codexModelsCacheFile)
            )
        let account = AgentAccount(
            provider: .codex,
            handle: .standard,
            configPath: directory.path
        )

        let options = AgentModels.options(for: .codex, account: account)
        XCTAssertEqual(options.map(\.identifier), ["gpt-visible"])
        XCTAssertEqual(options.first?.displayName, "GPT Visible")
        XCTAssertEqual(options.first?.fastServiceTier, "priority-v2")
        XCTAssertTrue(options.first?.supportsFastMode == true)
        XCTAssertEqual(options.first?.defaultReasoningLevel, "low")
        XCTAssertEqual(
            options.first?.reasoningLevels.map(\.effort),
            ["low", "xhigh", "max", "ultra"]
        )
        XCTAssertEqual(
            options.first?.reasoningLevels.map(\.displayName),
            ["Light", "Extra High", "Max", "Ultra"]
        )
        XCTAssertEqual(
            options.first?.reasoningLevels.last?.description,
            "Delegated work"
        )
        XCTAssertEqual(
            AgentModels.defaultFastMode(
                for: .codex,
                model: "gpt-visible",
                account: account
            ),
            true
        )
    }

    func testUnsupportedAccountEffortFallsBackToTheSelectedModelsDefault() throws {
        let directory = try temporaryAccountDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(#"model_reasoning_effort = "ultra""#.utf8).write(
            to: directory.appendingPathComponent(AgentDefaults.codexConfigFile)
        )
        try Data("""
            {"models":[{
              "slug":"gpt-no-ultra",
              "display_name":"GPT No Ultra",
              "visibility":"list",
              "default_reasoning_level":"medium",
              "supported_reasoning_levels":[
                {"effort":"low","description":"Quick"},
                {"effort":"medium","description":"Balanced"},
                {"effort":"max","description":"Deep"}
              ]
            }]}
            """.utf8).write(
                to: directory.appendingPathComponent(AgentDefaults.codexModelsCacheFile)
            )
        let account = AgentAccount(
            provider: .codex,
            handle: .standard,
            configPath: directory.path
        )
        var session = AgentSession(kind: .codex, title: "Effort")

        XCTAssertEqual(
            AgentModels.effectiveEffort(
                for: session,
                model: "gpt-no-ultra",
                account: account
            ),
            "medium"
        )

        session.reasoningEffort = "max"
        XCTAssertEqual(
            AgentModels.effectiveEffort(
                for: session,
                model: "gpt-no-ultra",
                account: account
            ),
            "max"
        )
    }

    func testExplicitCodexServiceTierWinsOverTheCatalogDefault() throws {
        let directory = try temporaryAccountDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(#"service_tier = "default""#.utf8).write(
            to: directory.appendingPathComponent(AgentDefaults.codexConfigFile)
        )
        try Data("""
            {"models":[{
              "slug":"gpt-fast",
              "display_name":"GPT Fast",
              "visibility":"list",
              "service_tiers":[{"id":"priority","name":"Fast"}],
              "default_service_tier":"priority"
            }]}
            """.utf8).write(
                to: directory.appendingPathComponent(AgentDefaults.codexModelsCacheFile)
            )
        let account = AgentAccount(
            provider: .codex,
            handle: .standard,
            configPath: directory.path
        )

        XCTAssertEqual(
            AgentModels.defaultFastMode(
                for: .codex,
                model: "gpt-fast",
                account: account
            ),
            false
        )
    }

    func testClaudeFastModeCapabilityMatchesOpusFamilyNotDatedVersions() {
        // A family match keeps a future Opus working without a code change — the point of not
        // pinning opus-4-7/4-8.
        XCTAssertTrue(AgentModels.claudeSupportsFastMode("opus"))
        XCTAssertTrue(AgentModels.claudeSupportsFastMode("claude-opus-4-8"))
        XCTAssertTrue(AgentModels.claudeSupportsFastMode("claude-opus-4-9-future"))
        XCTAssertTrue(AgentModels.claudeSupportsFastMode("Claude-Opus-4-8"), "case-insensitive")

        XCTAssertFalse(AgentModels.claudeSupportsFastMode("sonnet"))
        XCTAssertFalse(AgentModels.claudeSupportsFastMode("claude-sonnet-5"))
        XCTAssertFalse(AgentModels.claudeSupportsFastMode("fable"))
        XCTAssertFalse(AgentModels.claudeSupportsFastMode(nil), "nil default is not guessed")
    }

    // MARK: - Scoped Limits

    /// A limit is named after the family it meters while a session carries the id its CLI was
    /// launched with, so the match has to cross the two vocabularies — and keep crossing them
    /// when the next Fable ships.
    func testScopedLimitMetersItsWholeFamily() {
        XCTAssertTrue(ModelName.scope("Fable", meters: "claude-fable-5[1m]"))
        XCTAssertTrue(ModelName.scope("Fable", meters: "fable"))
        XCTAssertTrue(ModelName.scope("fable", meters: "claude-fable-6-future"))
        XCTAssertTrue(ModelName.scope("Opus", meters: "claude-opus-4-8"))
        XCTAssertTrue(ModelName.scope("GPT-5.3-Codex-Spark", meters: "gpt-5.3-codex-spark"))
    }

    /// The direction that matters: a scoped limit wrongly applied would put a session in the red
    /// over a model it is not running, which is exactly what keeping these windows separate is
    /// for.
    func testScopedLimitDoesNotMeterAnotherModel() {
        XCTAssertFalse(ModelName.scope("Fable", meters: "claude-opus-4-8"))
        XCTAssertFalse(ModelName.scope("Opus", meters: "claude-sonnet-5"))
        XCTAssertFalse(ModelName.scope("Fable", meters: ""))
        XCTAssertFalse(ModelName.scope("", meters: "claude-fable-5"))
        XCTAssertFalse(ModelName.scope("  ", meters: "claude-fable-5"))
    }

    /// The friendly name is read too, so a limit named after what the *chip* says still matches
    /// an id that spells it differently.
    func testScopedLimitMatchesTheFriendlyName() {
        XCTAssertTrue(ModelName.scope("Fable 5", meters: "claude-fable-5[1m]"))
        XCTAssertTrue(ModelName.scope("Haiku 4.5", meters: "claude-haiku-4-5-20251001"))
    }

    private func temporaryAccountDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-model-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }
}

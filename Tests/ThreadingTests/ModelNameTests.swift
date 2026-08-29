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

    func testEveryClaudeModelPublishesTheCLIsSessionEffortLevels() {
        let expected = ["low", "medium", "high", "xhigh", "max"]

        for option in AgentModels.options(for: .claude, account: nil) {
            XCTAssertEqual(option.reasoningLevels.map(\.effort), expected, option.identifier)
        }
        XCTAssertEqual(
            AgentModels.option(
                identifier: "opus[1m]",
                for: .claude,
                account: nil
            )?.reasoningLevels.map(\.effort),
            expected,
            "a configured long-context variant is still governed by Claude's session contract"
        )
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

    /// The iPhone represents the account's default model as nil on the wire while still allowing
    /// an explicit effort. Admission must validate that effort against the resolved default;
    /// requiring an explicit model makes the first request fail and only its refresh-backed retry
    /// succeed.
    func testExplicitEffortIsAcceptedForAnInheritedDefaultModel() throws {
        let directory = try temporaryAccountDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(#"model = "gpt-default""#.utf8).write(
            to: directory.appendingPathComponent(AgentDefaults.codexConfigFile)
        )
        try Data("""
            {"models":[{
              "slug":"gpt-default",
              "display_name":"GPT Default",
              "visibility":"list",
              "default_reasoning_level":"medium",
              "supported_reasoning_levels":[
                {"effort":"medium","description":"Balanced"},
                {"effort":"high","description":"Deep"}
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

        XCTAssertTrue(AgentModels.supports(
            reasoningEffort: "high",
            kind: .codex,
            model: nil,
            account: account
        ))
        XCTAssertFalse(AgentModels.supports(
            reasoningEffort: "ultra",
            kind: .codex,
            model: nil,
            account: account
        ))
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

        XCTAssertTrue(session.setReasoningEffort("max"))
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

    /// A phone's draft, the report chat and the Mac composer all send no model to mean "the
    /// account's default" — while showing that default's own Fast control. The gate has to
    /// answer for the model that will run, or it refuses a speed its own catalogue offered:
    /// a create request from the phone came back *Unsupported Speed* for exactly that.
    func testCodexFastControlForAnOmittedModelIsTheAccountDefaultsAnswer() throws {
        let directory = try temporaryAccountDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("""
            {
              "models": [
                {
                  "slug": "gpt-fast",
                  "display_name": "GPT Fast",
                  "visibility": "list",
                  "service_tiers": [
                    {"id": "priority", "name": "Fast", "description": "Quick"}
                  ]
                },
                {
                  "slug": "gpt-plain",
                  "display_name": "GPT Plain",
                  "visibility": "list"
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
        let config = directory.appendingPathComponent(AgentDefaults.codexConfigFile)

        try Data("model = \"gpt-fast\"\n".utf8).write(to: config)
        XCTAssertTrue(AgentModels.supportsFastMode(kind: .codex, model: nil, account: account))
        XCTAssertEqual(
            AgentModels.supportsFastMode(kind: .codex, model: nil, account: account),
            AgentModels.supportsFastMode(
                kind: .codex,
                model: AgentModels.defaultModel(for: .codex, account: account),
                account: account
            ),
            "the catalogue answers per model id and the gate answers for nil; they must agree"
        )

        try Data("model = \"gpt-plain\"\n".utf8).write(to: config)
        XCTAssertFalse(AgentModels.supportsFastMode(kind: .codex, model: nil, account: account))
        XCTAssertTrue(
            AgentModels.supportsFastMode(kind: .codex, model: "gpt-fast", account: account),
            "an explicit model still answers for itself"
        )

        try FileManager.default.removeItem(at: config)
        XCTAssertFalse(
            AgentModels.supportsFastMode(kind: .codex, model: nil, account: account),
            "an account naming no model is unknown, and unknown is no control"
        )
    }

    /// The same contract on the control-channel mechanism: an omitted model resolves through the
    /// login's own `settings.json` before the family test, and only a login naming no model at
    /// all is still "not guessed".
    func testClaudeFastControlForAnOmittedModelIsTheAccountDefaultsAnswer() throws {
        let directory = try temporaryAccountDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let account = AgentAccount(
            provider: .claude,
            handle: .standard,
            configPath: directory.path
        )
        let settings = directory.appendingPathComponent(AgentDefaults.claudeSettingsFile)

        try Data(#"{"model":"opus"}"#.utf8).write(to: settings)
        XCTAssertTrue(AgentModels.supportsFastMode(kind: .claude, model: nil, account: account))

        try Data(#"{"model":"sonnet"}"#.utf8).write(to: settings)
        XCTAssertFalse(AgentModels.supportsFastMode(kind: .claude, model: nil, account: account))
        XCTAssertTrue(
            AgentModels.supportsFastMode(kind: .claude, model: "opus", account: account),
            "an explicit model still answers for itself"
        )

        try Data("{}".utf8).write(to: settings)
        XCTAssertFalse(AgentModels.supportsFastMode(kind: .claude, model: nil, account: account))
        XCTAssertFalse(
            AgentModels.supportsFastMode(kind: .claude, model: nil, account: nil),
            "no login at all is not guessed either"
        )
    }

    /// Codex truncates `models_cache.json` and then writes it, so for a moment every half-minute
    /// the file is empty. That moment must not turn the catalogue into the bare configured model
    /// — which is how a phone's chat was refused for a speed the Mac had just offered it — and
    /// a genuinely new catalogue must still replace the remembered one.
    func testCodexCatalogSurvivesTheCacheBeingRewrittenInPlace() throws {
        let directory = try temporaryAccountDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = directory.appendingPathComponent(AgentDefaults.codexModelsCacheFile)
        try Data("model = \"gpt-first\"\n".utf8).write(
            to: directory.appendingPathComponent(AgentDefaults.codexConfigFile)
        )
        let account = AgentAccount(
            provider: .codex,
            handle: .standard,
            configPath: directory.path
        )

        XCTAssertEqual(
            AgentModels.options(for: .codex, account: account).map(\.identifier),
            ["gpt-first"],
            "a login Codex has not written a catalogue for still offers its configured model"
        )
        XCTAssertFalse(AgentModels.supportsFastMode(kind: .codex, model: nil, account: account))

        try Data("""
            {
              "models": [
                {
                  "slug": "gpt-first",
                  "display_name": "GPT First",
                  "visibility": "list",
                  "service_tiers": [{"id": "priority", "name": "Fast", "description": ""}],
                  "supported_reasoning_levels": [{"effort": "low", "description": ""}]
                }
              ]
            }
            """.utf8).write(to: cache)
        XCTAssertTrue(AgentModels.supportsFastMode(kind: .codex, model: nil, account: account))
        XCTAssertTrue(
            AgentModels.supports(reasoningEffort: "low", kind: .codex, model: nil, account: account)
        )

        // The truncate half of Codex's rewrite, held open: the file exists and is empty.
        try Data().write(to: cache)
        XCTAssertEqual(
            AgentModels.options(for: .codex, account: account).map(\.identifier),
            ["gpt-first"]
        )
        XCTAssertTrue(
            AgentModels.supportsFastMode(kind: .codex, model: nil, account: account),
            "an empty cache answered for the login instead of the catalogue it had proved"
        )
        XCTAssertTrue(
            AgentModels.supports(reasoningEffort: "low", kind: .codex, model: nil, account: account),
            "the effort levels went with the Fast tier"
        )

        // A half-written file is no better than an empty one.
        try Data("{\"models\": [{\"slug\": \"gpt-".utf8).write(to: cache)
        XCTAssertTrue(AgentModels.supportsFastMode(kind: .codex, model: nil, account: account))

        // A new catalogue is read as itself, not remembered away.
        try Data("""
            {
              "models": [
                {"slug": "gpt-second", "display_name": "GPT Second", "visibility": "list"}
              ]
            }
            """.utf8).write(to: cache)
        XCTAssertEqual(
            AgentModels.options(for: .codex, account: account).map(\.identifier),
            ["gpt-second"]
        )
        XCTAssertFalse(
            AgentModels.supportsFastMode(kind: .codex, model: "gpt-second", account: account)
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

    // MARK: - Tiers

    /// The ranking a model picker is ordered by. Anthropic's own tiering, which is also the order
    /// of the list prices — so this is checkable against something outside the app.
    func testTheTiersDescendFromTheMostCapable() {
        XCTAssertEqual(
            ModelName.Tier.allCases,
            [.fable, .opus, .sonnet, .haiku],
            "the tier order is the menu order; a reshuffle here reorders every model picker"
        )
    }

    /// Every spelling of the same model answers the same tier. The id a CLI hands us is `fable`,
    /// `claude-fable-5` or `claude-fable-5[1m]` depending on where it was read, and a tier that
    /// matched only one of them would sort the other two as unranked.
    func testEverySpellingOfAModelSharesItsTier() {
        XCTAssertEqual(ModelName.tier(of: "fable"), .fable)
        XCTAssertEqual(ModelName.tier(of: "claude-fable-5"), .fable)
        XCTAssertEqual(ModelName.tier(of: "claude-fable-5[1m]"), .fable)
        XCTAssertEqual(ModelName.tier(of: "CLAUDE-FABLE-5"), .fable)
        XCTAssertEqual(ModelName.tier(of: "opus"), .opus)
        XCTAssertEqual(ModelName.tier(of: "claude-opus-4-8"), .opus)
        XCTAssertEqual(ModelName.tier(of: "claude-sonnet-4-6"), .sonnet)
        XCTAssertEqual(ModelName.tier(of: "claude-haiku-4-5-20251001"), .haiku)
    }

    /// Mythos is Fable's tier: the same capabilities at the same price through a different
    /// distribution, so a picker that ranked it apart would be describing the channel, not the
    /// model.
    func testMythosRanksWithFable() {
        XCTAssertEqual(ModelName.tier(of: "claude-mythos-5"), .fable)
    }

    /// A model no tier names keeps a nil rank rather than being guessed into one — an
    /// organisation's own grant sorted above Opus on a hunch would be worse than one left where
    /// its source listed it.
    func testAnUnknownModelHasNoTier() {
        XCTAssertNil(ModelName.tier(of: "claude-quasar-9"))
        XCTAssertNil(ModelName.tier(of: "gpt-5-codex"))
        XCTAssertNil(ModelName.tier(of: ""))
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

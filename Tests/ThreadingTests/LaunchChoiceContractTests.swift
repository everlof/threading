import XCTest
@testable import Threading

/// What the new-session catalogue offers a phone is what the Mac's create gate accepts.
///
/// The catalogue and the gate answered "can this login run this" with two copies of the rule,
/// and the copies drifted apart twice: the gate refused a Fast the catalogue advertised for the
/// account's default, and later refused a login's configured `opus[1m]` — which the catalogue
/// offered as that login's default — on every chat a phone started there. The phone cannot
/// recover from that: its refreshed catalogue offers the refused choice straight back.
///
/// Each fixture is a login shaped the way a real one has been: a default no alias names, an
/// organisation default, a cached long-context grant, a Codex catalogue whose models differ in
/// effort and speed, and a Codex model only `config.toml` names. For each, every combination a
/// phone can be shown — and the one it sends when the user leaves everything on Auto — must
/// pass `AgentRunChoice.refusal`, the rule `handleCreateSession` refuses with.
@MainActor
final class LaunchChoiceContractTests: XCTestCase {

    private var directories: [URL] = []

    override func setUp() async throws {
        try await super.setUp()
        AgentModels.forgetCachedProviderFiles()
        ClaudeAccountLastRunModel.forgetAll()
    }

    override func tearDown() async throws {
        for directory in directories {
            try? FileManager.default.removeItem(at: directory)
        }
        directories = []
        ModelAliasResolutionStore.shared.forgetAll()
        try await super.tearDown()
    }

    // MARK: - Claude

    /// The reported login: its own settings name `opus[1m]`, which no alias or cache lists.
    func testAClaudeDefaultNoAliasNamesIsAccepted() throws {
        let account = try claudeAccount(files: [
            AgentDefaults.claudeSettingsFile: #"{"model": "opus[1m]"}"#,
        ])

        XCTAssertEqual(AgentModels.defaultModel(for: .claude, account: account), "opus[1m]")
        assertEveryOfferIsAccepted(kind: .claude, account: account)
    }

    func testAClaudeOrganisationDefaultAndCachedGrantAreAccepted() throws {
        let account = try claudeAccount(files: [
            AgentDefaults.claudeStateFile: #"""
            {"orgModelDefaultCache": {"model": "claude-opus-4-8"},
             "additionalModelOptionsCache": [
               {"value": "claude-fable-5[1m]", "label": "Fable",
                "description": "Fable 5 · Most capable"}
             ]}
            """#,
        ])

        assertEveryOfferIsAccepted(kind: .claude, account: account)
    }

    func testAnUnconfiguredClaudeLoginIsAccepted() throws {
        assertEveryOfferIsAccepted(kind: .claude, account: try claudeAccount(files: [:]))
    }

    // MARK: - Codex

    /// Models whose effort subsets and Fast tiers differ, and a default that names one of them.
    func testACodexCatalogueWithPerModelEffortsAndSpeedsIsAccepted() throws {
        let account = try codexAccount(files: [
            AgentDefaults.codexConfigFile: """
            model = "gpt-steady"
            model_reasoning_effort = "xhigh"
            """,
            AgentDefaults.codexModelsCacheFile: Self.codexCatalogue,
        ])

        assertEveryOfferIsAccepted(kind: .codex, account: account)
    }

    /// The Codex shape of the reported bug: the configured model is one the catalogue omits.
    func testACodexDefaultTheCatalogueOmitsIsAccepted() throws {
        let account = try codexAccount(files: [
            AgentDefaults.codexConfigFile: #"model = "gpt-config-only""#,
            AgentDefaults.codexModelsCacheFile: Self.codexCatalogue,
        ])

        XCTAssertTrue(
            RemoteNewSessionModelCatalog.choices(for: .codex, account: account)
                .contains { $0.id == "gpt-config-only" }
        )
        assertEveryOfferIsAccepted(kind: .codex, account: account)
    }

    /// No catalogue yet: the configured model is the whole offer, and it must start.
    func testACodexLoginBeforeItsFirstCatalogueIsAccepted() throws {
        let account = try codexAccount(files: [
            AgentDefaults.codexConfigFile: #"model = "gpt-config-only""#,
        ])

        assertEveryOfferIsAccepted(kind: .codex, account: account)
    }

    // MARK: - The gate is not vacuous

    /// The contract above would pass for a gate that accepted everything.
    func testTheGateStillRefusesWhatNoLoginOffers() throws {
        let account = try codexAccount(files: [
            AgentDefaults.codexConfigFile: #"model = "gpt-steady""#,
            AgentDefaults.codexModelsCacheFile: Self.codexCatalogue,
        ])

        XCTAssertEqual(
            AgentRunChoice(model: "gpt-withdrawn").refusal(kind: .codex, account: account),
            .unknownModel
        )
        XCTAssertEqual(
            AgentRunChoice(model: "gpt-steady", reasoningEffort: "ultra")
                .refusal(kind: .codex, account: account),
            .unknownReasoningEffort
        )
        XCTAssertEqual(
            AgentRunChoice(model: "gpt-steady", fastMode: true)
                .refusal(kind: .codex, account: account),
            .unsupportedSpeed
        )
    }

    // MARK: - Honoured choices

    /// What a report launch publishes and what a moved send carries are the gate applied one
    /// choice at a time, so whatever they keep is admitted — including from choices that were
    /// valid on some other login and none of which this one offers.
    func testAnHonouredChoiceIsAlwaysAdmittedAndKeepsWhatWasValid() throws {
        let logins: [(AgentKind, AgentAccount)] = [
            (.claude, try claudeAccount(files: [
                AgentDefaults.claudeSettingsFile: #"{"model": "opus[1m]"}"#,
            ])),
            (.codex, try codexAccount(files: [
                AgentDefaults.codexConfigFile: #"model = "gpt-config-only""#,
                AgentDefaults.codexModelsCacheFile: Self.codexCatalogue,
            ])),
        ]
        let strangers = [
            AgentRunChoice(model: "withdrawn", reasoningEffort: "ultra", fastMode: true),
            AgentRunChoice(model: nil, reasoningEffort: "ultra", fastMode: false),
            AgentRunChoice(model: "gpt-steady", reasoningEffort: "low", fastMode: true),
            AgentRunChoice(model: "opus[1m]", reasoningEffort: "max", fastMode: true),
        ]

        for (kind, account) in logins {
            for choice in strangers + offers(kind: kind, account: account) {
                let honoured = choice.honoured(kind: kind, account: account)
                XCTAssertNil(
                    honoured.refusal(kind: kind, account: account),
                    "\(kind.rawValue) honoured \(choice) as \(honoured), which the gate refuses"
                )
                if choice.refusal(kind: kind, account: account) == nil {
                    XCTAssertEqual(honoured, choice, "an admitted choice is kept whole")
                }
            }
        }
    }

    // MARK: - Private Methods

    /// A catalogue whose two models disagree about effort and speed, so a rule that checked
    /// one model's levels against the other's would show up.
    private static let codexCatalogue = """
        {"models":[
          {"slug":"gpt-quick","display_name":"GPT Quick","visibility":"list",
           "service_tiers":[{"id":"priority","name":"Fast","description":"Quick"}],
           "default_service_tier":"priority",
           "default_reasoning_level":"low",
           "supported_reasoning_levels":[
             {"effort":"low","description":"Quick"},
             {"effort":"ultra","description":"Delegated"}
           ]},
          {"slug":"gpt-steady","display_name":"GPT Steady","visibility":"list",
           "default_reasoning_level":"medium",
           "supported_reasoning_levels":[
             {"effort":"medium","description":"Balanced"},
             {"effort":"xhigh","description":"Deep"}
           ]},
          {"slug":"gpt-internal","display_name":"GPT Internal","visibility":"hide"}
        ]}
        """

    /// Fails for each combination the catalogue offers that the gate would refuse.
    private func assertEveryOfferIsAccepted(
        kind: AgentKind,
        account: AgentAccount,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let choices = RemoteNewSessionModelCatalog.choices(for: kind, account: account)
        XCTAssertFalse(choices.isEmpty, "the fixture offers no models", file: file, line: line)

        for choice in offers(kind: kind, account: account) {
            XCTAssertNil(
                choice.refusal(kind: kind, account: account),
                "offered \(choice) and refused it",
                file: file,
                line: line
            )
        }
    }

    /// Every combination a phone can send for this login: each offered model with each of its
    /// levels and speeds, the same for the account's default left as nil, and Auto as the
    /// phone resolves it at Start — the default's concrete id and its published effort.
    private func offers(kind: AgentKind, account: AgentAccount) -> [AgentRunChoice] {
        let choices = RemoteNewSessionModelCatalog.choices(for: kind, account: account)
        let defaultID = AgentModels.defaultModel(for: kind, account: account)

        var offers: [AgentRunChoice] = []
        func addEveryCombination(model: String?, row: RemoteModelChoiceDTO) {
            let efforts: [String?] = [nil] + row.reasoning.map(\.id)
            let speeds: [Bool?] = row.supportsFastMode == true ? [nil, true, false] : [nil]
            for effort in efforts {
                for speed in speeds {
                    offers.append(
                        AgentRunChoice(model: model, reasoningEffort: effort, fastMode: speed)
                    )
                }
            }
        }
        for row in choices {
            addEveryCombination(model: row.id, row: row)
        }
        if let defaultRow = choices.first(where: { $0.id == defaultID }) {
            addEveryCombination(model: nil, row: defaultRow)
        }

        // `SessionDraftRunChoiceResolution.launch`: the default row, else the first, with its
        // published effort when that row lists it.
        if let auto = choices.first(where: { $0.id == defaultID }) ?? choices.first {
            let effort = auto.defaultReasoningID.flatMap { id in
                auto.reasoning.contains { $0.id == id } ? id : nil
            }
            offers.append(AgentRunChoice(model: auto.id, reasoningEffort: effort))
        }
        return offers
    }

    private func claudeAccount(files: [String: String]) throws -> AgentAccount {
        AgentAccount(
            provider: .claude,
            handle: .named("contract-\(UUID().uuidString)"),
            configPath: try directory(with: files).path
        )
    }

    private func codexAccount(files: [String: String]) throws -> AgentAccount {
        AgentAccount(
            provider: .codex,
            handle: .named("contract-\(UUID().uuidString)"),
            configPath: try directory(with: files).path
        )
    }

    private func directory(with files: [String: String]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("launch-contract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        for (name, contents) in files {
            try Data(contents.utf8).write(to: directory.appendingPathComponent(name))
        }
        return directory
    }
}

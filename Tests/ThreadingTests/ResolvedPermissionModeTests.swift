import XCTest
@testable import Threading

/// Covers what the permission-mode and speed chips *say* when the conversation has pinned
/// nothing of its own.
///
/// Both used to answer "Agent's Setting" — the name of a place, in a control whose whole job is
/// to say what the session will do. The model chip had already solved the same problem
/// (`ResolvedDefaultModel`): name the value, qualify where it came from, and fall back to a
/// generic label only when no source can name one at all. These pin that behaviour for the other
/// two chips, and the order the sources are asked in.
final class ResolvedPermissionModeTests: XCTestCase {

    // MARK: - Order

    /// Threading's own default outranks the agent's configuration because it *becomes* the
    /// launch flag; the configuration outranks observation because it describes the next launch
    /// while a transcript describes where a session got to; and this login's earlier run answers
    /// only when nothing about this one can.
    func testTheSourcesAreAskedInOrderOfAuthority() {
        XCTAssertEqual(
            ResolvedPermissionMode.resolve(
                appDefault: .plan,
                configured: .acceptEdits,
                observed: .auto,
                remembered: .dontAsk
            ),
            ResolvedPermissionMode(mode: .plan, source: .appDefault)
        )
        XCTAssertEqual(
            ResolvedPermissionMode.resolve(
                appDefault: nil,
                configured: .acceptEdits,
                observed: .auto,
                remembered: .dontAsk
            ),
            ResolvedPermissionMode(mode: .acceptEdits, source: .agentConfiguration)
        )
        XCTAssertEqual(
            ResolvedPermissionMode.resolve(
                appDefault: nil,
                configured: nil,
                observed: .auto,
                remembered: .dontAsk
            ),
            ResolvedPermissionMode(mode: .auto, source: .observedInThisConversation)
        )
        XCTAssertEqual(
            ResolvedPermissionMode.resolve(
                appDefault: nil,
                configured: nil,
                observed: nil,
                remembered: .dontAsk
            ),
            ResolvedPermissionMode(mode: .dontAsk, source: .rememberedFromEarlierRun)
        )
    }

    /// The one case that still names a place: a login that has never run this agent, whose
    /// runtime configures nothing this app reads. Naming a mode here would be a guess, and the
    /// CLI's own unset fallback is decided by a server-side gate rather than by a file.
    func testNothingCanNameItOnlyWhenNoSourceAnswers() {
        XCTAssertNil(
            ResolvedPermissionMode.resolve(appDefault: nil, configured: nil).mode
        )
        XCTAssertEqual(
            PermissionModePresentation.chipTitle(
                selected: nil,
                inherited: ResolvedPermissionMode.resolve(appDefault: nil, configured: nil)
            ),
            PermissionModePresentation.agentSettingTitle
        )
    }

    // MARK: - Codex states its posture as a pair

    /// Codex has no single mode: the six postures are six distinct
    /// `approval_policy`/`sandbox_mode` combinations, so reading one back is reading the pair.
    /// Round-tripping every case is what holds the two directions to each other — a mapping that
    /// changed in one direction only is exactly the bug their adjacency exists to prevent.
    func testEveryModeRoundTripsThroughCodexsTwoAxes() {
        for mode in AgentPermissionMode.allCases {
            XCTAssertEqual(
                AgentPermissionMode(
                    codexApprovalPolicy: mode.codexApprovalPolicy,
                    sandboxMode: mode.codexSandboxMode
                ),
                mode,
                "\(mode) does not survive a round trip through Codex's two axes"
            )
        }
    }

    /// A pair that names none of the six is a posture this vocabulary cannot state, and a pair
    /// missing an axis is a configuration this app has not been given. Both read as nothing
    /// rather than as the nearest mode.
    func testAPairThatNamesNoneOfTheSixReadsAsNothing() {
        XCTAssertNil(
            AgentPermissionMode(
                codexApprovalPolicy: AgentDefaults.codexApprovalOnRequest,
                sandboxMode: AgentDefaults.codexSandboxReadOnly
            ),
            "on-request with read-only is neither Auto nor Plan"
        )
        XCTAssertNil(
            AgentPermissionMode(
                codexApprovalPolicy: AgentDefaults.codexApprovalNever,
                sandboxMode: nil
            ),
            "one axis cannot name a posture Codex defaults the other half of"
        )
        XCTAssertNil(AgentPermissionMode(codexApprovalPolicy: nil, sandboxMode: nil))
    }

    /// And the whole way through, from a `config.toml` on disk to a mode: this is what lets a
    /// Codex session's chip read "Bypass Permissions" instead of "Agent's Setting".
    func testCodexsOwnConfigurationNamesTheModeItWillRunIn() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try Data(
            """
            model = "gpt-5.6-sol"
            approval_policy = "never"
            sandbox_mode = "danger-full-access"
            """.utf8
        ).write(to: directory.appendingPathComponent(AgentDefaults.codexConfigFile))

        let account = AgentAccount(
            provider: .codex,
            handle: .named("codex"),
            configPath: directory.path
        )
        XCTAssertEqual(
            ResolvedPermissionMode.configured(
                for: .codex,
                account: account,
                projectDirectory: nil
            ),
            .bypassPermissions
        )
    }

    /// Grok and OpenCode state none of the six anywhere this app reads, and say so by answering
    /// nothing rather than by having been forgotten in a branch.
    func testARuntimeThatConfiguresNoModeAnswersNothing() {
        for kind in [AgentKind.grok, .openCode] {
            XCTAssertNil(
                ResolvedPermissionMode.configured(
                    for: kind,
                    account: AgentAccount(
                        provider: kind,
                        handle: .named("x"),
                        configPath: NSTemporaryDirectory()
                    ),
                    projectDirectory: nil
                )
            )
        }
    }

    // MARK: - How the menu qualifies it

    /// A configured mode and a remembered one are both named, and told apart in words: one is a
    /// setting the user can go and change, the other is where the agent got to last time and may
    /// not describe the next launch.
    func testTheMarkedRowSaysWhereItsModeCameFrom() {
        XCTAssertEqual(
            PermissionModePresentation.rowTitle(
                .auto,
                inherited: ResolvedPermissionMode(mode: .auto, source: .agentConfiguration)
            ),
            "\(AgentPermissionMode.auto.displayName)\(PermissionModePresentation.defaultSuffix)"
        )
        XCTAssertEqual(
            PermissionModePresentation.rowTitle(
                .auto,
                inherited: ResolvedPermissionMode(mode: .auto, source: .rememberedFromEarlierRun)
            ),
            "\(AgentPermissionMode.auto.displayName)\(PermissionModePresentation.lastUsedSuffix)"
        )
        XCTAssertEqual(
            PermissionModePresentation.rowTitle(
                .plan,
                inherited: ResolvedPermissionMode(mode: .auto, source: .agentConfiguration)
            ),
            AgentPermissionMode.plan.displayName,
            "only the inherited row is marked"
        )
    }

    /// The chip carries the value; the tooltip carries whose value it is. A mode the user picked
    /// here needs no explaining, so it gets none.
    func testTheChipsTooltipNamesTheSourceAndOnlyWhenInheriting() throws {
        XCTAssertNil(
            PermissionModePresentation.chipTooltip(
                selected: .plan,
                inherited: ResolvedPermissionMode(mode: .auto, source: .agentConfiguration)
            )
        )
        XCTAssertNil(
            PermissionModePresentation.chipTooltip(
                selected: nil,
                inherited: ResolvedPermissionMode(mode: nil, source: .agentConfiguration)
            )
        )

        for source in [
            ResolvedPermissionMode.Source.appDefault,
            .agentConfiguration,
            .observedInThisConversation,
            .rememberedFromEarlierRun
        ] {
            let tooltip = try XCTUnwrap(
                PermissionModePresentation.chipTooltip(
                    selected: nil,
                    inherited: ResolvedPermissionMode(mode: .auto, source: source)
                )
            )
            XCTAssertTrue(
                tooltip.contains(AgentPermissionMode.auto.displayName),
                "a tooltip that does not name the mode explains nothing: \(tooltip)"
            )
        }
    }

    // MARK: - Speed

    /// A Claude conversation that has chosen no speed runs Standard: its fast mode is a live
    /// control-channel flag, and the flag starts off. The chip used to say "Agent's Setting"
    /// while `AgentModels.effectiveFastMode` — the function that decides what actually happens —
    /// had always resolved the same case to Standard.
    @MainActor
    func testAClaudeConversationThatChoseNoSpeedReadsAsStandard() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-speed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let account = AgentAccount(
            provider: .claude,
            handle: .named("speed"),
            configPath: directory.path
        )
        let previous = AppSettings.shared.startupSpeed(for: .claude)
        AppSettings.shared.setStartupSpeed(.agentSetting, for: .claude)
        defer { AppSettings.shared.setStartupSpeed(previous, for: .claude) }
        ClaudeSettings.forgetAll()

        XCTAssertEqual(
            ConversationSpeedPresentation.chipTitle(
                selected: nil,
                kind: .claude,
                model: "opus",
                account: account,
                projectDirectory: directory.path
            ),
            ConversationSpeedPresentation.standardTitle
        )

        try Data(#"{"fastMode": true}"#.utf8)
            .write(to: directory.appendingPathComponent(ClaudeSettingsDefaults.settingsFile))
        ClaudeSettings.forgetAll()

        XCTAssertEqual(
            ConversationSpeedPresentation.chipTitle(
                selected: nil,
                kind: .claude,
                model: "opus",
                account: account,
                projectDirectory: directory.path
            ),
            ConversationSpeedPresentation.fastTitle,
            "a login whose own settings turn fast mode on was reported as Standard"
        )
    }

    /// The two are one resolution rather than two that agree by inspection: the chip asks
    /// `AgentModels.effectiveFastMode`, which is what the launcher and the status card ask.
    @MainActor
    func testTheChipAndTheLaunchResolutionCannotDisagree() {
        for selected in [nil, true, false] as [Bool?] {
            let effective = AgentModels.effectiveFastMode(
                selected: selected,
                kind: .claude,
                model: "opus",
                account: nil,
                startupSpeed: AppSettings.shared.startupSpeed(for: .claude)
            )
            let title = ConversationSpeedPresentation.chipTitle(
                selected: selected,
                kind: .claude,
                model: "opus",
                account: nil
            )
            switch effective {
            case true: XCTAssertEqual(title, ConversationSpeedPresentation.fastTitle)
            case false: XCTAssertEqual(title, ConversationSpeedPresentation.standardTitle)
            case nil: XCTFail("a Claude conversation has no unknown speed")
            }
        }
    }
}

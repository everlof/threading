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
                for: .claude,
                selected: nil,
                inherited: ResolvedPermissionMode.resolve(appDefault: nil, configured: nil)
            ),
            PermissionModePresentation.agentSettingTitle
        )
    }

    // MARK: - Codex states its posture as a configuration

    /// Codex has no single mode: the six postures are six distinct approval, sandbox and
    /// reviewer combinations, so reading one back means reading the complete configuration.
    /// Round-tripping every case is what holds the two directions to each other — a mapping that
    /// changed in one direction only is exactly the bug their adjacency exists to prevent.
    func testEveryModeRoundTripsThroughCodexsThreeAxes() {
        for mode in AgentPermissionMode.allCases {
            XCTAssertEqual(
                AgentPermissionMode(
                    codexApprovalPolicy: mode.codexApprovalPolicy,
                    sandboxMode: mode.codexSandboxMode,
                    approvalsReviewer: mode.codexApprovalsReviewer
                ),
                mode,
                "\(mode) does not survive a round trip through Codex's three axes"
            )
        }
    }

    /// A configuration that names none of the six is a posture this vocabulary cannot state,
    /// and one missing an axis is a configuration this app has not been given. Both read as
    /// nothing rather than as the nearest mode.
    func testAConfigurationThatNamesNoneOfTheSixReadsAsNothing() {
        XCTAssertNil(
            AgentPermissionMode(
                codexApprovalPolicy: AgentDefaults.codexApprovalOnRequest,
                sandboxMode: AgentDefaults.codexSandboxReadOnly,
                approvalsReviewer: AgentDefaults.codexApprovalsReviewerAutoReview
            ),
            "on-request with read-only is neither Auto nor Plan"
        )
        XCTAssertNil(
            AgentPermissionMode(
                codexApprovalPolicy: AgentDefaults.codexApprovalNever,
                sandboxMode: nil,
                approvalsReviewer: AgentDefaults.codexApprovalsReviewerUser
            ),
            "one axis cannot name a posture Codex defaults the other half of"
        )
        XCTAssertNil(AgentPermissionMode(
            codexApprovalPolicy: nil,
            sandboxMode: nil,
            approvalsReviewer: nil
        ))
        XCTAssertNil(
            AgentPermissionMode(
                codexApprovalPolicy: AgentDefaults.codexApprovalOnRequest,
                sandboxMode: AgentDefaults.codexSandboxWorkspaceWrite,
                approvalsReviewer: nil
            ),
            "Codex's default human reviewer is plain Auto, not Auto (Approve for me)"
        )
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

    /// `on-request` plus `workspace-write` is Codex's ordinary Auto preset until the reviewer
    /// axis opts into Auto-review. The chip must not promise Approve for me from only the pair.
    func testCodexConfigurationNamesAutoOnlyWithTheAutomaticReviewer() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-auto-review-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let config = directory.appendingPathComponent(AgentDefaults.codexConfigFile)
        let account = AgentAccount(
            provider: .codex,
            handle: .named("codex"),
            configPath: directory.path
        )
        try Data(
            """
            approval_policy = "on-request"
            sandbox_mode = "workspace-write"
            """.utf8
        ).write(to: config)
        XCTAssertNil(
            ResolvedPermissionMode.configured(
                for: .codex,
                account: account,
                projectDirectory: nil
            )
        )

        try Data(
            """
            approval_policy = "on-request"
            sandbox_mode = "workspace-write"
            approvals_reviewer = "auto_review"
            """.utf8
        ).write(to: config)
        XCTAssertEqual(
            ResolvedPermissionMode.configured(
                for: .codex,
                account: account,
                projectDirectory: nil
            ),
            .auto
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
                for: .claude,
                inherited: ResolvedPermissionMode(mode: .auto, source: .agentConfiguration)
            ),
            "\(AgentPermissionMode.auto.displayName)\(PermissionModePresentation.defaultSuffix)"
        )
        XCTAssertEqual(
            PermissionModePresentation.rowTitle(
                .auto,
                for: .claude,
                inherited: ResolvedPermissionMode(mode: .auto, source: .rememberedFromEarlierRun)
            ),
            "\(AgentPermissionMode.auto.displayName)\(PermissionModePresentation.lastUsedSuffix)"
        )
        XCTAssertEqual(
            PermissionModePresentation.rowTitle(
                .plan,
                for: .claude,
                inherited: ResolvedPermissionMode(mode: .auto, source: .agentConfiguration)
            ),
            AgentPermissionMode.plan.displayName,
            "only the inherited row is marked"
        )
    }

    // MARK: - What a source is allowed to promise

    /// Two of the four states the *next launch*; two only report one. The launch line is what
    /// makes the difference real: an app-wide default becomes `--permission-mode` and a runtime
    /// reads its own configuration, while nothing replays a mode out of a transcript.
    func testOnlyASettingGovernsTheNextLaunch() {
        XCTAssertTrue(ResolvedPermissionMode.Source.appDefault.governsNextLaunch)
        XCTAssertTrue(ResolvedPermissionMode.Source.agentConfiguration.governsNextLaunch)
        XCTAssertFalse(ResolvedPermissionMode.Source.observedInThisConversation.governsNextLaunch)
        XCTAssertFalse(ResolvedPermissionMode.Source.rememberedFromEarlierRun.governsNextLaunch)

        XCTAssertEqual(
            ResolvedPermissionMode(mode: .auto, source: .agentConfiguration).governingMode,
            .auto
        )
        XCTAssertNil(
            ResolvedPermissionMode(mode: .auto, source: .rememberedFromEarlierRun).governingMode,
            "a mode this login merely ran in last time governs nothing"
        )
        XCTAssertNil(
            ResolvedPermissionMode(mode: .auto, source: .observedInThisConversation).governingMode
        )
    }

    /// The bug this pair exists to prevent: the menu marked the *remembered* mode as the row that
    /// means "inherit", so choosing Auto answered nil, the session recorded no mode, the launch
    /// line carried no `--permission-mode`, and the chat started asking about every tool while
    /// the chip above it read Auto. A report is an ordinary row now — it pins.
    func testAModeNothingWillStateAgainIsPinnedRatherThanInherited() throws {
        for source in [
            ResolvedPermissionMode.Source.rememberedFromEarlierRun,
            .observedInThisConversation
        ] {
            let items = menuItems(
                inherited: ResolvedPermissionMode(mode: .auto, source: source),
                selected: nil
            )
            let auto = try XCTUnwrap(
                items.first { $0.title.hasPrefix(AgentPermissionMode.auto.displayName) },
                "\(source) lost its Auto row"
            )
            XCTAssertEqual(
                auto.representedValue as? AgentPermissionMode,
                .auto,
                "choosing Auto under \(source) recorded no choice at all"
            )
            XCTAssertFalse(
                auto.isSelected,
                "a session following nothing is not running \(source)'s remembered mode"
            )

            let inherit = try XCTUnwrap(
                items.first { $0.title == PermissionModePresentation.agentSettingRowTitle },
                "with nothing governing, inherit needs a row of its own"
            )
            XCTAssertNil(inherit.representedValue)
            XCTAssertTrue(inherit.isSelected)
        }
    }

    /// And the case that stays as it was: a mode the next launch *will* state again is the
    /// inherit row, marked where it stands, with no second row repeating it.
    func testAConfiguredModeIsStillTheRowThatMeansInherit() throws {
        for source in [ResolvedPermissionMode.Source.appDefault, .agentConfiguration] {
            let items = menuItems(
                inherited: ResolvedPermissionMode(mode: .auto, source: source),
                selected: nil
            )
            let auto = try XCTUnwrap(
                items.first { $0.title.hasPrefix(AgentPermissionMode.auto.displayName) }
            )
            XCTAssertNil(
                auto.representedValue,
                "\(source) is followed rather than copied onto the session"
            )
            XCTAssertTrue(auto.isSelected)
            XCTAssertFalse(
                items.contains { $0.title == PermissionModePresentation.agentSettingRowTitle },
                "\(source) already names the inherited mode; a second row would duplicate it"
            )
        }
    }

    /// Every mode a menu offers can be reached, whatever the inherited answer is: the row's own
    /// action answers the same value its `representedValue` does, so the two kinds of caller —
    /// a chip reading the value back, a presented menu running the action — cannot disagree
    /// about what was chosen.
    func testChoosingAModeAnswersThatModeThroughBothRoutes() throws {
        for source in ResolvedPermissionModeTests.everySource {
            for mode in AgentPermissionMode.allCases {
                var chosen: AgentPermissionMode??
                let inherited = ResolvedPermissionMode(mode: .auto, source: source)
                let items = menuItems(inherited: inherited, selected: nil) { chosen = $0 }
                let row = try XCTUnwrap(
                    items.first { $0.title.hasPrefix(mode.displayName) },
                    "\(mode) is missing from a menu resolved from \(source)"
                )
                row.onChoose?()

                let expected = mode == inherited.governingMode ? nil : mode
                XCTAssertEqual(
                    row.representedValue as? AgentPermissionMode,
                    expected
                )
                XCTAssertEqual(
                    try XCTUnwrap(chosen, "\(mode) chose nothing under \(source)"),
                    expected,
                    "the row's action and its value disagree for \(mode) under \(source)"
                )
            }
        }
    }

    /// A chip states what is in force. A setting states the next launch and a running agent
    /// states itself, so both are named — but a mode read out of a *different* conversation is
    /// neither, and naming it is how the composer came to promise Auto over a session that
    /// launched with no `--permission-mode` at all.
    func testTheChipDoesNotNameAModeNothingWillApply() {
        XCTAssertEqual(
            PermissionModePresentation.chipTitle(
                for: .claude,
                selected: nil,
                inherited: ResolvedPermissionMode(mode: .auto, source: .rememberedFromEarlierRun)
            ),
            PermissionModePresentation.agentSettingTitle
        )
        for source in [
            ResolvedPermissionMode.Source.appDefault,
            .agentConfiguration,
            .observedInThisConversation
        ] {
            XCTAssertEqual(
                PermissionModePresentation.chipTitle(
                    for: .claude,
                    selected: nil,
                    inherited: ResolvedPermissionMode(mode: .auto, source: source)
                ),
                AgentPermissionMode.auto.displayName,
                "\(source) names a posture that is in force and should be shown"
            )
        }
        XCTAssertEqual(
            PermissionModePresentation.chipTitle(
                for: .claude,
                selected: .plan,
                inherited: ResolvedPermissionMode(mode: .auto, source: .rememberedFromEarlierRun)
            ),
            AgentPermissionMode.plan.displayName,
            "the session's own choice outranks every source"
        )
    }

    /// The chip carries the value; the tooltip carries whose value it is. A mode the user picked
    /// here needs no explaining, so it gets none.
    func testTheChipsTooltipNamesTheSourceAndOnlyWhenInheriting() throws {
        XCTAssertNil(
            PermissionModePresentation.chipTooltip(
                for: .claude,
                selected: .plan,
                inherited: ResolvedPermissionMode(mode: .auto, source: .agentConfiguration)
            )
        )
        XCTAssertNil(
            PermissionModePresentation.chipTooltip(
                for: .claude,
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
                    for: .claude,
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

    /// The chip drew a bolt whatever it said. A bolt is what Fast *looks* like everywhere in this
    /// app — the status card's `speedMark` appears only while fast mode is on — so a chip reading
    /// "Standard" under one said the opposite of its own words, and contradicted the card in the
    /// same window.
    @MainActor
    func testTheChipWearsTheBoltOnlyWhileItSaysFast() {
        for selected in [nil, true, false] as [Bool?] {
            let chip = ConversationSpeedPresentation.chip(
                selected: selected,
                kind: .claude,
                model: "opus",
                account: nil
            )
            if chip.title == ConversationSpeedPresentation.fastTitle {
                XCTAssertEqual(
                    chip.symbolName,
                    ConversationSpeedPresentation.fastSymbol,
                    "Fast lost the mark that means it"
                )
            } else {
                XCTAssertEqual(
                    chip.symbolName,
                    ConversationSpeedPresentation.ordinarySymbol,
                    "“\(chip.title)” was marked with the bolt that means Fast"
                )
            }
        }
    }

    /// Both marks have to exist as images, or a chip that resolves correctly still draws nothing:
    /// `ChipView.configure(symbolName:title:)` silently keeps no icon for a name AppKit cannot
    /// resolve on this OS.
    @MainActor
    func testBothSpeedMarksResolveOnThisSystem() {
        for name in [
            ConversationSpeedPresentation.fastSymbol,
            ConversationSpeedPresentation.ordinarySymbol
        ] {
            XCTAssertNotNil(
                NSImage(systemSymbolName: name, accessibilityDescription: nil),
                "“\(name)” is not a symbol this system can draw"
            )
        }
    }

    // MARK: - Fixtures

    /// Written out rather than derived: `Source` is not `CaseIterable`, and a fifth source added
    /// without a line here would quietly go untested by every loop above.
    private static let everySource: [ResolvedPermissionMode.Source] = [
        .appDefault,
        .agentConfiguration,
        .observedInThisConversation,
        .rememberedFromEarlierRun
    ]

    /// The rows one surface would offer, with the separators and the timing note dropped.
    ///
    /// `whenTheSessionStarts` because it adds no note — these assert what choosing a row records,
    /// which is the same on all three surfaces.
    private func menuItems(
        inherited: ResolvedPermissionMode,
        selected: AgentPermissionMode?,
        onChoose: ((AgentPermissionMode?) -> Void)? = nil
    ) -> [ThemedMenuItem] {
        PermissionModePresentation.rows(
            for: .claude,
            selected: selected,
            inherited: inherited,
            timing: .whenTheSessionStarts,
            onChoose: onChoose
        ).compactMap { entry in
            guard case .item(let item) = entry else { return nil }
            return item
        }
    }
}

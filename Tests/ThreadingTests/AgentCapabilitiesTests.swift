import XCTest
@testable import Threading

/// The provider matrix, held to the code that reads it.
///
/// `AgentKind.capabilities` is the only place a runtime is named to decide what the host may do
/// with it — `scripts/check_architecture_boundaries.sh` keeps it that way. That makes the matrix
/// a single point of failure worth asserting from the other side: these tests check that a
/// capability and the code it governs cannot drift apart, and that adding a fifth runtime is a
/// matter of filling in one switch rather than re-reading the app.
final class AgentCapabilitiesTests: XCTestCase {

    // MARK: - Matrix Invariants

    /// Every capability occupies its own bit.
    ///
    /// Hand-written `1 << N` shifts have one silent failure: reuse a shift and two unrelated
    /// capabilities become the same flag, so granting either grants both and no call site can
    /// tell. The list is written out rather than derived — deriving it from the same
    /// declarations that could collide would prove nothing.
    func testEveryCapabilityOccupiesItsOwnBit() {
        let all: [(String, AgentCapabilities)] = [
            ("resume", .resume),
            ("presetSessionID", .presetSessionID),
            ("accounts", .accounts),
            ("nativeUI", .nativeUI),
            ("permissionModes", .permissionModes),
            ("forking", .forking),
            ("threadingBridge", .threadingBridge),
            ("remoteControl", .remoteControl),
            ("statusLine", .statusLine),
            ("transcriptTitles", .transcriptTitles),
            ("transcriptModelRecord", .transcriptModelRecord),
            ("serviceTierFastMode", .serviceTierFastMode),
            ("liveFastModeControl", .liveFastModeControl),
            ("slashCommandPrefix", .slashCommandPrefix),
            ("sharedSubagentIdentity", .sharedSubagentIdentity),
            ("deferredSessionIdentifier", .deferredSessionIdentifier),
            ("transcriptUsageIndex", .transcriptUsageIndex),
            ("terminalThreadingBridge", .terminalThreadingBridge),
            ("openingFileAttachments", .openingFileAttachments),
            ("headlessResearch", .headlessResearch),
            ("transcriptPermissionModeRecord", .transcriptPermissionModeRecord),
            ("anchoredUsageWindow", .anchoredUsageWindow),
            ("transcriptUsageLimitRecord", .transcriptUsageLimitRecord),
            ("providerTitleMetadata", .providerTitleMetadata),
            ("providerArchive", .providerArchive),
            ("transcriptInterruptedTurnRecord", .transcriptInterruptedTurnRecord)
        ]

        var seen: [Int: String] = [:]
        for (name, capability) in all {
            XCTAssertEqual(
                capability.rawValue.nonzeroBitCount,
                1,
                "\(name) is not a single flag"
            )
            if let owner = seen[capability.rawValue] {
                XCTFail("\(name) shares a bit with \(owner)")
            }
            seen[capability.rawValue] = name
        }
    }

    /// Every runtime hosts a conversation that can be picked up again; nothing here is a
    /// one-shot. `ResumeState.initial(for:)` depends on this, and would hand out `.unavailable`
    /// — the state that used to mean "this is a shell" — to a runtime that lost it.
    func testEveryRuntimeCanResume() {
        for kind in AgentKind.allCases {
            XCTAssertTrue(kind.supports(.resume), "\(kind) must resume")
        }
    }

    /// Only Codex exposes both halves of a reversible archive. Delete is not treated as archive
    /// for Claude Code or Grok, and OpenCode's archive-only timestamp is not treated as the
    /// Archive/Restore pair: Threading must neither destroy a provider conversation nor lose Undo
    /// merely to make two lists look alike.
    func testOnlyCodexSynchronizesProviderArchiveState() {
        XCTAssertTrue(AgentKind.codex.supports(.providerArchive))
        XCTAssertFalse(AgentKind.claude.supports(.providerArchive))
        XCTAssertFalse(AgentKind.grok.supports(.providerArchive))
        XCTAssertFalse(AgentKind.openCode.supports(.providerArchive))
    }

    /// The two Fast mechanisms answer "what does unset mean" differently — off for a live
    /// control-channel flag, unknown for a service tier. A runtime holding both would make
    /// `AgentModels.effectiveFastMode` depend on which branch was written first.
    func testFastModeMechanismsAreMutuallyExclusive() {
        for kind in AgentKind.allCases {
            XCTAssertFalse(
                kind.supports(.liveFastModeControl) && kind.supports(.serviceTierFastMode),
                "\(kind) claims both Fast mechanisms; they disagree about what unset means"
            )
        }
    }

    /// A runtime whose transcript Threading reads for a title must have a transcript reader in
    /// the first place. `.transcriptTitles`, `.transcriptModelRecord` and
    /// `.transcriptPermissionModeRecord` are separate facts — a runtime could record one and not
    /// the others — but all three are readings of the same file, so none may be claimed by a
    /// runtime with no transcript to read.
    func testTranscriptCapabilitiesImplyAResumableTranscript() {
        for kind in AgentKind.allCases where kind.supports(.transcriptTitles)
            || kind.supports(.transcriptModelRecord)
            || kind.supports(.transcriptPermissionModeRecord) {
            XCTAssertTrue(
                kind.supports(.resume),
                "\(kind) reads a transcript it has no identifier for"
            )
        }
    }

    /// Usage indexing follows measured source support, not a provider allow-list. Claude and
    /// Codex expose local structured records, OpenCode exposes a supported structured export,
    /// and Grok currently exposes neither an authoritative token bill nor a structured history.
    func testTranscriptUsageCapabilityMatchesMeasuredAdapters() {
        XCTAssertTrue(AgentKind.claude.supports(.transcriptUsageIndex))
        XCTAssertTrue(AgentKind.codex.supports(.transcriptUsageIndex))
        XCTAssertTrue(AgentKind.openCode.supports(.transcriptUsageIndex))
        XCTAssertFalse(AgentKind.grok.supports(.transcriptUsageIndex))
    }

    /// Codex is the only measured runtime whose terminal interrupt is authoritative in its
    /// transcript while the corresponding `Stop` hook is absent.
    func testInterruptedTurnTranscriptCapabilityMatchesTheCodexReader() {
        for kind in AgentKind.allCases {
            XCTAssertEqual(
                kind.supports(.transcriptInterruptedTurnRecord),
                kind == .codex,
                "\(kind) claims the Codex interruption reader against expectation"
            )
        }
    }

    /// A runtime whose posture can be observed must also have a posture to observe: reading a
    /// mode back out of a transcript is only meaningful for a runtime whose modes Threading
    /// speaks in the first place. The reverse does not hold — Codex takes the vocabulary on its
    /// launch line and records nothing to read back.
    func testAnObservablePostureImpliesAPermissionVocabulary() {
        for kind in AgentKind.allCases where kind.supports(.transcriptPermissionModeRecord) {
            XCTAssertTrue(
                kind.supports(.permissionModes),
                "\(kind) records a posture it has no vocabulary for"
            )
        }
    }

    /// Threading's launch flags carry its permission vocabulary and its per-session bridge. A
    /// runtime that accepts neither has no launch contract of ours at all, which is exactly
    /// OpenCode's position — and the only position from which that is true.
    func testOnlyRuntimesWithoutALaunchContractRefuseBoth() {
        for kind in AgentKind.allCases {
            let hasLaunchContract = kind.supports(.permissionModes)
                || kind.supports(.threadingBridge)
            XCTAssertEqual(
                hasLaunchContract,
                kind != .openCode,
                "\(kind) disagrees with its launch contract"
            )
        }
    }

    // MARK: - Capability Meets Its Consumer

    /// `.forking` and `AgentSession.forkedConfiguration` are two statements of one fact, read by
    /// the menu and by the store respectively. Granting the capability without writing down what
    /// the fork *is* would leave Fork enabled on a session that silently creates nothing.
    func testForkingCapabilityAgreesWithTheConfigurationItProduces() {
        for kind in AgentKind.allCases {
            let session = AgentSession.fixture(kind: kind)
            XCTAssertEqual(
                kind.supports(.forking),
                session.forkedConfiguration != nil,
                "\(kind): the Fork menu and the store disagree"
            )
        }
    }

    /// A fork is a child of its parent on the same runtime, carrying the lineage the CLI keeps
    /// no record of.
    func testForkedConfigurationNamesItsParentOnTheSameRuntime() throws {
        let parent = AgentSession.fixture(kind: .claude)
        let configuration = try XCTUnwrap(parent.forkedConfiguration)
        let child = AgentSession(configuration: configuration, title: "", model: nil)

        XCTAssertEqual(child.kind, parent.kind)
        XCTAssertEqual(child.forkedFrom, parent.id)
        XCTAssertTrue(child.isSideChat)
    }

    /// The composer offers the conversation surface exactly when the runtime claims it, and
    /// `ConversationViewController` has a transport for exactly those runtimes. The model is the
    /// third party that has to agree — it used to clamp for some runtimes and refuse for others.
    func testNativeSurfaceSurvivesCreationWhereverItIsOffered() {
        for kind in AgentKind.allCases {
            let session = AgentSession.fixture(kind: kind, usesNativeUI: true)
            XCTAssertEqual(
                session.usesNativeUI,
                kind.supports(.nativeUI),
                "\(kind): the composer's surface offer and the stored session disagree"
            )
        }
    }

    // MARK: - Configuration Construction

    /// The regression this file was written for: Grok advertises the conversation surface, the
    /// composer offers it, and `ConversationViewController` builds an ACP transport for it —
    /// while the store refused the record, so choosing it created nothing and said nothing.
    func testEveryRuntimeOfferingTheNativeSurfaceCanBeCreatedOnIt() {
        for kind in AgentKind.allCases where kind.supports(.nativeUI) {
            XCTAssertNotNil(
                AgentSessionConfiguration.fixture(kind: kind),
                "\(kind) offers a conversation surface it cannot be created on"
            )
        }
    }

    /// A setting the runtime merely ignores is clamped by the model, never grounds for refusing
    /// the whole session — the distinction that broke the case above.
    func testAnIgnoredSurfaceChoiceIsClampedRatherThanRefused() {
        let session = AgentSession.fixture(kind: .openCode, usesNativeUI: true)
        XCTAssertFalse(session.usesNativeUI)
        XCTAssertEqual(session.kind, .openCode)
    }

    /// A setting the runtime cannot route, by contrast, is refused: silently dropping the
    /// account would run the conversation against a login the user did not pick.
    func testAnUnroutableAccountIsRefused() {
        for kind in AgentKind.allCases {
            let configuration = AgentSessionConfiguration.fixture(
                kind: kind,
                accountHandle: .named("second")
            )
            XCTAssertEqual(
                configuration != nil,
                kind.supports(.accounts),
                "\(kind) disagrees with its own account routing"
            )
        }
    }

    /// Likewise a permission mode: a runtime that owns a richer per-tool policy of its own must
    /// not be handed one of Threading's six and left looking as though it applied.
    func testAPermissionModeIsRefusedWhereItCannotBeTranslated() {
        for kind in AgentKind.allCases {
            let configuration = AgentSessionConfiguration.fixture(
                kind: kind,
                permissionMode: .acceptEdits
            )
            XCTAssertEqual(
                configuration != nil,
                kind.supports(.permissionModes),
                "\(kind) disagrees with its own permission vocabulary"
            )
        }
    }

    /// Handoff lineage is provider-neutral: every pair of distinct runtimes is representable,
    /// while a same-runtime handoff is refused because that is a native resume/move operation.
    func testEveryCrossRuntimeHandoffIsRepresentable() throws {
        for sourceKind in AgentKind.allCases {
            for targetKind in AgentKind.allCases where targetKind != sourceKind {
                let sourceID = SessionID()
                let targetID = SessionID()
                let handoff = try XCTUnwrap(ConversationHandoff(endpoints: [
                    ConversationHandoffEndpoint(
                        sessionID: sourceID,
                        kind: sourceKind,
                        model: nil,
                        title: nil
                    ),
                    ConversationHandoffEndpoint(
                        sessionID: targetID,
                        kind: targetKind,
                        model: nil,
                        title: nil
                    )
                ]))
                let configuration = try XCTUnwrap(
                    AgentSessionConfiguration.fixture(kind: targetKind)
                )
                let session = AgentSession(
                    configuration: configuration,
                    title: "",
                    handoff: handoff,
                    id: targetID
                )
                XCTAssertEqual(session.continuedFrom, sourceID)
                XCTAssertEqual(session.continuationSourceKind, sourceKind)
            }
        }

        XCTAssertNil(ConversationHandoff(endpoints: [
            ConversationHandoffEndpoint(
                sessionID: SessionID(),
                kind: .grok,
                model: nil,
                title: nil
            ),
            ConversationHandoffEndpoint(
                sessionID: SessionID(),
                kind: .grok,
                model: nil,
                title: nil
            )
        ]))
    }

    /// Reasoning effort is carried only by providers with a launch contract for it. Accepting
    /// it elsewhere would store a choice no turn could act on.
    func testReasoningEffortIsAcceptedOnlyWhereTheConfigurationCarriesIt() {
        for kind in AgentKind.allCases {
            let configuration = AgentSessionConfiguration.fixture(
                kind: kind,
                reasoningEffort: "high"
            )
            XCTAssertEqual(
                configuration != nil,
                kind == .claude || kind == .codex,
                "\(kind) disagrees about carrying a reasoning effort"
            )
        }
    }

    @MainActor
    func testSessionStoreAdmitsOnlyPublishedReasoningEffort() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-effort-admission-\(UUID().uuidString)")
        let store = ProjectStore.shared
        let project = store.addProject(folderURL: folder)
        defer { store.removeProject(id: project.id) }

        XCTAssertNotNil(store.addSession(
            to: project.id,
            kind: .claude,
            model: "opus",
            reasoningEffort: "xhigh"
        ))
        XCTAssertNil(store.addSession(
            to: project.id,
            kind: .claude,
            model: "opus",
            reasoningEffort: "ultra"
        ))
        XCTAssertNil(store.addSession(
            to: project.id,
            kind: .openCode,
            reasoningEffort: "high"
        ))
    }

    // MARK: - Fast Mode Semantics

    @MainActor
    func testStartupSpeedDefaultsToTheAgentAndPersistsSeparatelyPerRuntime() throws {
        let suite = "AgentStartupSpeed.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.startupSpeed(for: .claude), .agentSetting)
        XCTAssertEqual(settings.startupSpeed(for: .codex), .agentSetting)

        settings.setStartupSpeed(.standard, for: .claude)
        settings.setStartupSpeed(.fast, for: .codex)

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.startupSpeed(for: .claude), .standard)
        XCTAssertEqual(reloaded.startupSpeed(for: .codex), .fast)
        XCTAssertEqual(reloaded.startupSpeed(for: .grok), .agentSetting)
        XCTAssertEqual(reloaded.startupSpeed(for: .openCode), .agentSetting)
    }

    @MainActor
    func testStartupSpeedResolvesSessionThenAppThenAgent() {
        var codex = AgentSession.fixture(kind: .codex)
        XCTAssertNil(
            AgentLauncher.fastModeAtStartup(for: codex, defaultSpeed: .agentSetting)
        )
        XCTAssertEqual(
            AgentLauncher.fastModeAtStartup(for: codex, defaultSpeed: .standard),
            false
        )
        XCTAssertEqual(
            AgentLauncher.fastModeAtStartup(for: codex, defaultSpeed: .fast),
            true
        )

        codex.fastMode = false
        XCTAssertEqual(
            AgentLauncher.fastModeAtStartup(for: codex, defaultSpeed: .fast),
            false,
            "a conversation's choice must outrank the app-wide default"
        )
    }

    /// Claude's settings switch can select Opus as a side effect. A speed default may choose a
    /// tier, but it must not replace a model the user explicitly selected.
    @MainActor
    func testClaudeFastStartupDoesNotReplaceAnExplicitUnsupportedModel() {
        let opus = AgentSession(kind: .claude, title: "Opus", model: "opus")
        let sonnet = AgentSession(kind: .claude, title: "Sonnet", model: "sonnet")

        XCTAssertEqual(
            AgentLauncher.fastModeAtStartup(for: opus, defaultSpeed: .fast),
            true
        )
        XCTAssertEqual(
            AgentLauncher.fastModeAtStartup(for: sonnet, defaultSpeed: .fast),
            false
        )
    }

    func testAppStartupSpeedOutranksTheProviderDefaultInTheEffectiveReading() {
        let session = AgentSession.fixture(kind: .codex)
        XCTAssertEqual(
            AgentModels.effectiveFastMode(
                for: session,
                model: nil,
                account: nil,
                startupSpeed: .standard
            ),
            false
        )
        XCTAssertEqual(
            AgentModels.effectiveFastMode(
                for: session,
                model: nil,
                account: nil,
                startupSpeed: .fast
            ),
            true
        )
    }

    /// A live control-channel flag starts off until Threading sends it, so an unset choice is a
    /// known `false` rather than an unknown.
    func testUnsetFastModeIsOffForALiveControlChannel() {
        let session = AgentSession.fixture(kind: .claude)
        XCTAssertEqual(
            AgentModels.effectiveFastMode(for: session, model: nil, account: nil),
            false
        )
    }

    /// A service tier lives in an account's config and catalog. With no account to read, the
    /// honest answer is that Threading does not know — not that the session runs Standard.
    func testUnsetFastModeIsUnknownForAnUnreadableServiceTier() {
        let session = AgentSession.fixture(kind: .codex)
        XCTAssertNil(AgentModels.effectiveFastMode(for: session, model: nil, account: nil))
    }

    /// The conversation's own choice outranks both, on every runtime.
    func testAnExplicitFastChoiceOutranksTheRuntimeDefault() {
        for kind in AgentKind.allCases {
            var session = AgentSession.fixture(kind: kind)
            session.fastMode = true
            XCTAssertEqual(
                AgentModels.effectiveFastMode(for: session, model: nil, account: nil),
                true,
                "\(kind) ignored an explicit Fast choice"
            )
        }
    }

    /// A runtime with neither mechanism has no Fast control to show, whatever the model is.
    func testNoFastControlWithoutAFastMechanism() {
        for kind in AgentKind.allCases where !kind.supports(.liveFastModeControl)
            && !kind.supports(.serviceTierFastMode) {
            XCTAssertFalse(
                AgentModels.supportsFastMode(kind: kind, model: "anything", account: nil),
                "\(kind) offers a Fast control it has no mechanism for"
            )
        }
    }

    // MARK: - Composer Availability

    /// `Availability` makes "refused, with no reason given" unconstructible — but the bounded
    /// wire projection reaches inside it, and a reason truncated to nothing would put that state
    /// back without any producer having asked for it. A disabled row shows its reason *in place
    /// of* the description, so the result on screen is a greyed-out row explaining nothing.
    ///
    /// This holds today because the budget is 512 bytes and no single grapheme approaches that.
    /// It is asserted rather than reasoned about because the thing that would break it is
    /// someone lowering the constant, which is a one-character edit nowhere near this rule.
    func testNormalizationNeverTurnsAnExplainedRefusalIntoAnUnexplainedOne() throws {
        let capability = ComposerCapability(
            id: "probe",
            name: "probe",
            kind: .command,
            trigger: .slash,
            presentation: .command,
            availability: .unavailable(reason: String(repeating: "why not — ", count: 400))
        )

        let normalized = ComposerCapabilityCatalogPolicy.normalize([capability])
        let projected = try XCTUnwrap(normalized.capabilities.first)
        let reason = try XCTUnwrap(projected.availability.reason, "the refusal was dropped")

        XCTAssertFalse(projected.availability.isEnabled)
        XCTAssertFalse(reason.isEmpty, "the refusal survived but its reason did not")
        XCTAssertLessThanOrEqual(
            reason.utf8.count,
            ComposerCapabilityCatalogPolicy.maximumUnavailableReasonUTF8Bytes
        )
    }

    // MARK: - Permission Vocabulary

    /// `.permissionModes` and `AgentPermissionMode.launchFlags(for:)` are the claim and the
    /// delivery. They used to sit in different files — the capability here, the dispatch in
    /// `AgentLauncher` selecting among per-runtime value properties — so a runtime could claim
    /// the vocabulary and be given no flags, or be given flags it never claimed, and both
    /// compiled.
    ///
    /// Values are deliberately not asserted here: `AgentPermissionModeTests` checks those
    /// against the tokenized launch line, which is the only place that proves the CLI receives
    /// them. This checks only that the claim and the delivery agree, for every pair.
    func testEveryModeProducesFlagsExactlyWhereTheVocabularyIsClaimed() {
        for kind in AgentKind.allCases {
            for mode in AgentPermissionMode.allCases {
                XCTAssertEqual(
                    !mode.launchFlags(for: kind).isEmpty,
                    kind.supports(.permissionModes),
                    "\(kind) disagrees with itself about carrying \(mode)"
                )
            }
        }
    }

    /// A flag that is not a flag reaches the CLI as a positional argument, which some runtimes
    /// read as a prompt. `ShellCommand.append(flag:)` traps on it, so a mistyped constant here
    /// would be a crash at launch rather than a compile error.
    func testEveryProducedFlagIsWellFormed() {
        for kind in AgentKind.allCases {
            for mode in AgentPermissionMode.allCases {
                for flag in mode.launchFlags(for: kind) {
                    XCTAssertTrue(
                        flag.name.hasPrefix("-"),
                        "\(kind)/\(mode) produced \(flag.name), which is not a flag"
                    )
                    XCTAssertFalse(
                        flag.value.isEmpty,
                        "\(kind)/\(mode) produced \(flag.name) with no value"
                    )
                }
            }
        }
    }

    /// A runtime that splits the idea across independently-defaulted axes has to state all of
    /// them: setting one and leaving the other produces a posture that is neither the mode
    /// asked for nor the CLI's own. Codex is the runtime with two; the rule is written as
    /// "however many this runtime has, every mode states the same number".
    func testAMultiAxisRuntimeStatesEveryAxisForEveryMode() {
        for kind in AgentKind.allCases where kind.supports(.permissionModes) {
            let axisCounts = Set(AgentPermissionMode.allCases.map {
                $0.launchFlags(for: kind).count
            })
            XCTAssertEqual(
                axisCounts.count,
                1,
                "\(kind) states a different number of axes depending on the mode: \(axisCounts)"
            )

            let names = AgentPermissionMode.allCases.map { mode in
                mode.launchFlags(for: kind).map(\.name)
            }
            XCTAssertEqual(
                Set(names).count,
                1,
                "\(kind) states different axes depending on the mode"
            )
        }
    }

    // MARK: - Usage Windows

    /// A runtime whose window can be opened deliberately has a command that opens it, and one
    /// whose window cannot is refused.
    ///
    /// The pairing is the point. `UsageWindowPoker` gates on the capability and never on a
    /// runtime's name, so granting `.anchoredUsageWindow` to a fifth runtime with no branch in
    /// `usageWindowPokeCommand` would produce a scheduler that fires every morning and silently
    /// does nothing.
    @MainActor
    func testAPokeCommandExistsExactlyWhereTheWindowIsAnchored() {
        for kind in AgentKind.allCases {
            let account = AgentAccount(
                provider: kind,
                handle: .standard,
                configPath: "/tmp/\(kind.rawValue)"
            )
            let command = AgentLauncher.usageWindowPokeCommand(kind: kind, account: account)

            XCTAssertEqual(
                command != nil,
                kind.supports(.anchoredUsageWindow),
                "\(kind) claims .anchoredUsageWindow: \(kind.supports(.anchoredUsageWindow)), "
                    + "but a poke command \(command == nil ? "does not exist" : "exists")"
            )
        }
    }

    /// A poke reaches the login it was asked about, and carries nothing else.
    ///
    /// Both halves have cost something before. Routing is the reason the feature works at all —
    /// a window belongs to an account, so a poke on the default login buys the named one
    /// nothing. And the emptiness is what keeps it cheap: the run's reply is discarded, so any
    /// tool catalogue or MCP server it loaded would be input tokens charged to the weekly limit
    /// this feature exists to spend more carefully.
    @MainActor
    func testAPokeIsRoutedToItsAccountAndCarriesNoContext() throws {
        let kind = try XCTUnwrap(AgentKind.allCases.first { $0.supports(.anchoredUsageWindow) })

        let alternate = AgentAccount(
            provider: kind,
            handle: AccountHandle(storedName: "work"),
            configPath: "/Users/somebody/.claude-work"
        )
        let routed = try XCTUnwrap(
            AgentLauncher.usageWindowPokeCommand(kind: kind, account: alternate)
        ).source

        XCTAssertTrue(
            routed.contains("\(kind.accountEnvironmentKey)=/Users/somebody/.claude-work"),
            "a poke has to name the account whose window it is opening: \(routed)"
        )

        let standard = AgentAccount(provider: kind, handle: .standard, configPath: "/tmp/claude")
        let unset = try XCTUnwrap(
            AgentLauncher.usageWindowPokeCommand(kind: kind, account: standard)
        ).source

        XCTAssertTrue(
            unset.contains("-u") && unset.contains(kind.accountEnvironmentKey),
            "the default login is reached by unsetting the override: \(unset)"
        )
        XCTAssertFalse(
            unset.contains("\(kind.accountEnvironmentKey)="),
            "the default login is unset rather than pointed somewhere: \(unset)"
        )
        XCTAssertFalse(
            unset.contains("--mcp-config"),
            "a poke must load no MCP servers: \(unset)"
        )
    }

    /// A poke on the wrong runtime is refused rather than routed with a mismatched key.
    ///
    /// `AccountID` pairs a provider with a handle, so an account and a kind that disagree can
    /// only arrive from a caller that lost track of one of them. Building the command anyway
    /// would export Claude's environment key at a Codex config directory.
    @MainActor
    func testAPokeRefusesAnAccountFromAnotherRuntime() throws {
        let kind = try XCTUnwrap(AgentKind.allCases.first { $0.supports(.anchoredUsageWindow) })
        let other = try XCTUnwrap(AgentKind.allCases.first { $0 != kind })

        XCTAssertNil(
            AgentLauncher.usageWindowPokeCommand(
                kind: kind,
                account: AgentAccount(
                    provider: other,
                    handle: .standard,
                    configPath: "/tmp/other"
                )
            )
        )
    }
}

// MARK: - Fixtures

private extension AgentSessionConfiguration {
    /// The store's own construction path, with every parameter defaulted to the request a plain
    /// new session makes, so each test states only the one thing it is about.
    static func fixture(
        kind: AgentKind,
        reasoningEffort: String? = nil,
        accountHandle: AccountHandle = .standard,
        permissionMode: AgentPermissionMode? = nil
    ) -> AgentSessionConfiguration? {
        AgentSessionConfiguration(
            kind: kind,
            reasoningEffort: reasoningEffort,
            accountHandle: accountHandle,
            permissionMode: permissionMode
        )
    }
}

private extension AgentSession {
    static func fixture(kind: AgentKind, usesNativeUI: Bool = false) -> AgentSession {
        let configuration = AgentSessionConfiguration.fixture(kind: kind)
        return AgentSession(
            configuration: configuration ?? .openCode,
            title: "",
            model: nil,
            usesNativeUI: usesNativeUI
        )
    }
}

import XCTest
@testable import Threading

/// What a launch line is allowed to contain when the strings inside it are hostile.
///
/// Every launch is `sh -lc <one string>`, and that string is built from values the user and the
/// agents supply: a project folder chosen from a file panel, a session title an agent wrote, a
/// model identifier, a prompt, an account's config path. `ShellCommand` exists so none of those
/// can be syntax — but "it quotes" is a claim, and the roadmap has carried "plan snapshots,
/// including hostile strings" as the thing that would make it a fact.
///
/// Two ways of checking, because they fail differently:
///
/// - Against a **real shell**, which is the only authority on what its own quoting means. A
///   rule re-derived in a test is a second implementation of the bug.
/// - Against the **plan's own text**, which catches a word that reached the line without going
///   through the quoter at all — something a round-trip of `ShellCommand` cannot see.
@MainActor
final class AgentLaunchQuotingTests: XCTestCase {

    /// Strings that end a quoted word, start a command, or expand to one.
    private static let hostile = [
        "'; rm -rf ~; echo '",
        "$(touch /tmp/threading-quoting-escape)",
        "`touch /tmp/threading-quoting-escape`",
        "a\"b",
        "a'b",
        "a\\b",
        "; shutdown -h now",
        "&& echo pwned",
        "| tee /tmp/x",
        "> /tmp/x",
        "\n echo newline",
        "$HOME",
        "${IFS}",
        "*",
        "~root",
        "--flag=value with spaces",
        "- Make sure all tests are green\n- Then build the latest version"
    ]

    // MARK: - Against a real shell

    /// The quoter's output, tokenized by `/bin/sh` itself, gives back exactly the words that
    /// went in. `printf` is the whole command: it reports its arguments and does nothing else,
    /// so a quoting failure shows up as a wrong *answer* rather than as a side effect nobody
    /// was watching for.
    func testQuotedWordsSurviveARealShellUnchanged() throws {
        var command = ShellCommand(word: "/usr/bin/printf")
        command.append(word: "%s\u{1}")
        for word in Self.hostile {
            command.append(word: word)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command.source]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let received = String(decoding: data, as: UTF8.self)
            .split(separator: "\u{1}", omittingEmptySubsequences: false)
            .dropLast()
            .map(String.init)

        XCTAssertEqual(received, Self.hostile, "a word changed meaning on its way through sh")
        XCTAssertEqual(process.terminationStatus, 0)
    }

    /// The side effect none of the above may have had. `$(…)` and backticks in the corpus would
    /// create this file if the quoting let them run; the round-trip above would still pass,
    /// because printf would faithfully report the *result* of the expansion.
    func testNoSubstitutionRanWhileQuoting() throws {
        let evidence = "/tmp/threading-quoting-escape"
        try? FileManager.default.removeItem(atPath: evidence)

        try testQuotedWordsSurviveARealShellUnchanged()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: evidence),
            "a command substitution executed: the quoting is not quoting"
        )
    }

    // MARK: - Against the plan

    /// Every word in a launch line is quoted, and the *only* raw syntax is the fixed `&&`.
    ///
    /// Checked by deleting the quoted spans and looking at what is left: anything other than
    /// whitespace and `&&` is a word that reached the command line without passing through the
    /// quoter, which is the failure this design exists to prevent and the one a `ShellCommand`
    /// unit test cannot see.
    func testAHostileProjectAndSessionProduceNoRawSyntax() throws {
        for hostile in Self.hostile {
            let project = Project(
                name: hostile,
                folderURL: URL(fileURLWithPath: "/tmp/\(hostile)")
            )
            let session = AgentSession(kind: .claude, title: hostile, model: hostile)

            let plan = try AgentLauncher.plan(for: session, in: project, initialPrompt: hostile)
            let source = try? XCTUnwrap(plan.arguments.last)
            let residue = Self.strippingQuotedSpans(source ?? "")
                .replacingOccurrences(of: "&&", with: "")
                .replacingOccurrences(of: "--", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            XCTAssertTrue(
                residue.isEmpty,
                "unquoted text reached the launch line for \(hostile): \(residue)"
            )
        }
    }

    /// The launch is handed to a shell as **one argument**, so nothing after it can be read as
    /// a further command however the words inside it are shaped.
    func testTheLaunchIsASingleShellArgument() throws {
        let project = Project(name: "p", folderURL: URL(fileURLWithPath: "/tmp/p"))
        let session = AgentSession(kind: .codex, title: "t")

        let plan = try AgentLauncher.plan(for: session, in: project)

        XCTAssertEqual(
            plan.arguments.dropLast(),
            ["-l", "-c"],
            "the launch stopped being a login shell running one command"
        )
        XCTAssertEqual(plan.arguments.count, 3, "the shell was handed more than one command")
    }

    /// The pre-rename `SKALMAN_*` aliases are gone, and must not come back.
    ///
    /// They existed only to keep a Codex hook approved by the hash of its old command text
    /// runnable across the rename. Nothing reads them now, and every launch was paying for
    /// them in duplicated environment words, so this asserts their absence rather than their
    /// equivalence — the test that used to stand here.
    func testLaunchExportsNoPreRenameAliases() throws {
        let session = AgentSession(kind: .codex, title: "t")
        for brokering in [false, true] {
            let words = AgentLauncher.hookEnvironmentWords(
                for: session,
                brokersPermissions: brokering,
                port: 43210
            )
            XCTAssertFalse(
                words.contains { $0.hasPrefix("SKALMAN_") },
                "a pre-rename alias came back: \(words)"
            )
        }
    }

    /// The current routing words, which are what a hook actually reads.
    func testHookEnvironmentCarriesTheCurrentRoutingWords() throws {
        let session = AgentSession(kind: .codex, title: "t")
        let terminal = AgentLauncher.hookEnvironmentWords(
            for: session,
            brokersPermissions: false,
            port: 43210
        )

        func value(for key: String, in words: [String]) throws -> String {
            let prefix = "\(key)="
            let word = try XCTUnwrap(words.first { $0.hasPrefix(prefix) })
            return String(word.dropFirst(prefix.count))
        }

        XCTAssertEqual(try value(for: MCPDefaults.portEnvironmentKey, in: terminal), "43210")
        XCTAssertEqual(
            try value(for: MCPDefaults.socketEnvironmentKey, in: terminal),
            MCPBridgeLocation.socketPath
        )
        XCTAssertFalse(terminal.isEmpty)

        // The permission scope is what tells Codex's shared file which surface it is on, so it
        // stays absent from a terminal launch and present on a native one.
        XCTAssertFalse(terminal.contains { $0.hasPrefix("\(MCPDefaults.brokerEnvironmentKey)=") })
        let native = AgentLauncher.hookEnvironmentWords(
            for: session,
            brokersPermissions: true,
            port: 43210
        )
        XCTAssertEqual(try value(for: MCPDefaults.brokerEnvironmentKey, in: native), "1")
    }

    /// A session launched before the listener has a port still gets its routing.
    ///
    /// The rendezvous and the token are properties of the user and the session, so neither
    /// waits on a listener; only the port word does. The old code returned early on a missing
    /// port and exported nothing at all, which left the launch unaddressable for its whole life.
    func testRoutingWordsDoNotWaitForAListenerPort() throws {
        let session = AgentSession(kind: .codex, title: "t")
        let words = AgentLauncher.hookEnvironmentWords(
            for: session,
            brokersPermissions: false,
            port: nil,
            socketPath: "/tmp/threading tests/mcp.sock"
        )

        XCTAssertTrue(words.contains("\(MCPDefaults.socketEnvironmentKey)=/tmp/threading tests/mcp.sock"))
        XCTAssertTrue(words.contains {
            $0.hasPrefix("\(MCPDefaults.sessionTokenEnvironmentKey)=")
        })
        XCTAssertFalse(words.contains { $0.hasPrefix("\(MCPDefaults.portEnvironmentKey)=") })
    }

    func testHostedLaunchPlanTestsCannotMaintainTheDevelopersCodexHooks() {
        XCTAssertFalse(AgentLauncher.mayMaintainCodexHookConfiguration)
    }

    func testClaudeEffortIsPinnedOnTerminalAndNativeLaunches() throws {
        let project = Project(name: "p", folderURL: URL(fileURLWithPath: "/tmp/p"))
        let session = AgentSession(
            configuration: .claude(
                remoteControl: nil,
                fullscreenRenderer: nil,
                reasoningEffort: "xhigh",
                origin: .original
            ),
            title: "t",
            model: "opus"
        )

        let plans = [
            try AgentLauncher.plan(for: session, in: project),
            try AgentLauncher.streamPlan(for: session, in: project)
        ]

        for plan in plans {
            let words = try Self.tokenizing(XCTUnwrap(plan.arguments.last))
            let effortFlag = try XCTUnwrap(words.firstIndex(of: AgentDefaults.claudeEffortFlag))
            XCTAssertEqual(words[effortFlag + 1], "xhigh")
        }
    }

    /// Threading owns the daily release check and the visible updater receipt. Every Codex
    /// process it starts must therefore decline Codex's duplicate startup check, especially a
    /// terminal restored in the background before anyone has opened its chat.
    func testEveryThreadingCodexLaunchDisablesTheProviderStartupUpdateCheck() throws {
        let project = Project(name: "p", folderURL: URL(fileURLWithPath: "/tmp/p"))
        let session = AgentSession(kind: .codex, title: "t")
        let endpoint = "http://127.0.0.1:9/mcp/t"

        let sources = try [
            XCTUnwrap(try AgentLauncher.plan(for: session, in: project).arguments.last),
            XCTUnwrap(try AgentLauncher.streamPlan(for: session, in: project).arguments.last),
            XCTUnwrap(
                AgentLauncher.codexResearchPlan(
                    in: "/tmp/not-a-repository",
                    prompt: "find the mark"
                ).arguments.last
            ),
            ShellCommand.executing(
                XCTUnwrap(AgentLauncher.settingsResearchCommand(
                    kind: .codex,
                    prompt: "find the setting",
                    mcpConfigPath: nil,
                    binding: .http(url: endpoint)
                )),
                in: "/tmp/not-a-repository"
            ).source
        ]
        let expected = "\(AgentDefaults.codexCheckForUpdateOnStartupKey)=false"

        for source in sources {
            let words = try Self.tokenizing(source)
            XCTAssertEqual(
                words.filter { $0 == expected },
                [expected],
                "a Threading-managed Codex process may not show its own update prompt: \(words)"
            )
        }
    }

    /// Codex's alternate buffer retains only its current frame. Its DEC alternate-scroll mode
    /// turns a wheel into Up/Down keys, but Codex assigns those keys to composer history rather
    /// than transcript navigation. Threading therefore asks the supported inline surface to put
    /// the transcript in the terminal-owned scrollback that both Mac and iPhone mirror.
    func testCodexTerminalLaunchesOwnRealScrollbackWhilePipeTransportsDoNotNeedIt() throws {
        let project = Project(name: "p", folderURL: URL(fileURLWithPath: "/tmp/p"))
        let transcriptID = TranscriptID("01a00000-0000-7000-8000-000000000000")
        let fresh = AgentSession(kind: .codex, title: "fresh")
        var resumed = AgentSession(kind: .codex, title: "resumed")
        resumed.resumeState = .resumable(transcriptID)

        for session in [fresh, resumed] {
            let words = try Self.tokenizing(
                XCTUnwrap(try AgentLauncher.plan(for: session, in: project).arguments.last)
            )
            XCTAssertEqual(
                words.filter { $0 == AgentDefaults.codexNoAlternateScreenFlag },
                [AgentDefaults.codexNoAlternateScreenFlag]
            )
        }

        let nativeWords = try Self.tokenizing(
            XCTUnwrap(try AgentLauncher.streamPlan(for: fresh, in: project).arguments.last)
        )
        XCTAssertFalse(nativeWords.contains(AgentDefaults.codexNoAlternateScreenFlag))
    }

    /// Claude's is a choice rather than Codex's fixed inline launch, so the launch line has to
    /// carry the *decided* value both ways round — and carry nothing at all when the answer is
    /// "leave it to Claude", since an unset variable is what lets the CLI's own default and its
    /// machine-local auto-disable keep deciding.
    func testAClaudeTerminalStatesWhichScreenItsInterfaceDrawsOn() throws {
        let project = Project(name: "p", folderURL: URL(fileURLWithPath: "/tmp/p"))
        let key = AgentDefaults.claudeRendererEnvironmentKey
        let mainScreen = "\(key)=\(AgentDefaults.claudeMainScreenRendererValue)"
        let fullscreen = "\(key)=\(AgentDefaults.claudeFullscreenRendererValue)"

        var wantsTerminalScrollback = AgentSession(kind: .claude, title: "main screen")
        wantsTerminalScrollback.setClaudeFullscreenRenderer(false)
        var wantsFullscreen = AgentSession(kind: .claude, title: "alternate screen")
        wantsFullscreen.setClaudeFullscreenRenderer(true)

        for (session, expected) in [
            (wantsTerminalScrollback, mainScreen),
            (wantsFullscreen, fullscreen)
        ] {
            let words = try Self.tokenizing(
                XCTUnwrap(try AgentLauncher.plan(for: session, in: project).arguments.last)
            )
            XCTAssertEqual(
                words.filter { $0.hasPrefix("\(key)=") },
                [expected],
                "the launch line must state the screen exactly once: \(words)"
            )
        }

        // A native conversation draws no terminal UI at all, so stating a renderer for it would
        // be describing a screen that never exists.
        let nativeWords = try Self.tokenizing(
            XCTUnwrap(
                try AgentLauncher.streamPlan(for: wantsFullscreen, in: project).arguments.last
            )
        )
        XCTAssertTrue(nativeWords.allSatisfy { !$0.hasPrefix("\(key)=") }, "\(nativeWords)")

        // And no other runtime reads this variable, whatever it was asked for.
        for kind in AgentKind.allCases where kind != .claude && kind.supports(.terminalUI) {
            let words = try Self.tokenizing(
                XCTUnwrap(
                    try AgentLauncher.plan(
                        for: AgentSession(kind: kind, title: "other"),
                        in: project
                    ).arguments.last
                )
            )
            XCTAssertTrue(
                words.allSatisfy { !$0.hasPrefix("\(key)=") },
                "\(kind) must not be told about Claude's renderer: \(words)"
            )
        }
    }

    /// The conversation's own answer first, then the app-wide default, then nothing — and the
    /// shipped default is a stated value, so an ordinary Claude terminal launch is decided.
    func testTheRendererChoiceReadsTheConversationBeforeTheAppDefault() {
        var chose = AgentSession(kind: .claude, title: "chose")
        chose.setClaudeFullscreenRenderer(true)
        let inherits = AgentSession(kind: .claude, title: "inherits")

        XCTAssertEqual(
            AgentLauncher.terminalRendererAtStartup(for: chose, appDefault: .terminalScrollback),
            true,
            "a conversation that chose for itself outranks the app-wide default"
        )
        XCTAssertEqual(
            AgentLauncher.terminalRendererAtStartup(
                for: inherits,
                appDefault: .terminalScrollback
            ),
            false
        )
        XCTAssertEqual(
            AgentLauncher.terminalRendererAtStartup(for: inherits, appDefault: .claudeFullscreen),
            true
        )
        XCTAssertNil(
            AgentLauncher.terminalRendererAtStartup(for: inherits, appDefault: .followClaude),
            "following states nothing, which is what leaves the CLI's own record deciding"
        )
        XCTAssertEqual(
            AgentLauncher.terminalRendererAtStartup(
                for: AgentSession(kind: .codex, title: "codex"),
                appDefault: .terminalScrollback
            ),
            nil,
            "a runtime Threading pins inline already has no choice to state"
        )
        XCTAssertEqual(ClaudeTerminalRenderer.terminalScrollback.startupValue, false)
        XCTAssertTrue(
            AgentLauncher.terminalRendererEnvironmentWords(fullscreen: nil).isEmpty
        )
    }

    // MARK: - Against the CLI's own parser

    /// A prompt that begins with `-` is a prompt, not a flag.
    ///
    /// The composer's own opening — a bulleted list of things to do — killed a session a third
    /// of a second after it launched: Claude's parser read `- Make sure all tests are green` as
    /// an unknown option and exited 1, and the user was left looking at a chat that had opened
    /// with no prompt in it. Codex fails the same way (`unexpected argument '- ' found`) and
    /// says so in its own error: *to pass `- ` as a value, use `-- - `*.
    ///
    /// Checked by tokenizing the launch line with a real shell, because the property is about
    /// the *words the CLI receives*, and the shell is what decides those.
    func testAPromptBeginningWithADashSurvivesAsAPromptNotAFlag() throws {
        let opening = "- Make sure all tests are green\n- Then build the latest version"

        for kind in [AgentKind.claude, .codex] {
            let project = Project(name: "p", folderURL: URL(fileURLWithPath: "/tmp/p"))
            let session = AgentSession(kind: kind, title: "t")

            let words = try Self.tokenizing(
                XCTUnwrap(
                    try AgentLauncher.plan(
                        for: session,
                        in: project,
                        initialPrompt: opening
                    ).arguments.last
                )
            )

            XCTAssertEqual(
                words.suffix(2),
                ["--", opening],
                "\(kind) launched with the opening prompt exposed to its option parser"
            )
        }
    }

    /// OpenCode names its opening instead of accepting a positional operand. The model id is
    /// provider-qualified data: choosing Grok through OpenRouter must not turn Grok into a new
    /// app-level agent kind.
    func testOpenCodeLaunchCarriesProviderModelAndNamedPrompt() throws {
        let project = Project(name: "p", folderURL: URL(fileURLWithPath: "/tmp/p"))
        var session = AgentSession(kind: .openCode, title: "t")
        session.model = "openrouter/x-ai/grok-4"
        let opening = "- inspect this safely"

        let plan = try AgentLauncher.plan(for: session, in: project, initialPrompt: opening)
        let words = try Self.tokenizing(XCTUnwrap(plan.arguments.last))

        XCTAssertEqual(plan.resumeState, .awaitingIdentifier)
        XCTAssertEqual(words.suffix(5), [
            AgentDefaults.openCodeExecutable,
            "--model",
            "openrouter/x-ai/grok-4",
            "--prompt",
            opening
        ])
    }

    func testOpenCodeResumeUsesProviderAssignedSessionID() throws {
        let project = Project(name: "p", folderURL: URL(fileURLWithPath: "/tmp/p"))
        var session = AgentSession(kind: .openCode, title: "t")
        let transcriptID = TranscriptID("ses_test")
        session.resumeState = .resumable(transcriptID)

        let plan = try AgentLauncher.plan(
            for: session,
            in: project,
            initialPrompt: "must not be replayed"
        )
        let words = try Self.tokenizing(XCTUnwrap(plan.arguments.last))

        XCTAssertEqual(plan.resumeState, .resumable(transcriptID))
        XCTAssertEqual(words.suffix(3), [AgentDefaults.openCodeExecutable, "--session", "ses_test"])
        XCTAssertFalse(words.contains("--prompt"))
    }

    /// The standalone Grok runtime is distinct from choosing a Grok model inside OpenCode. Its
    /// TUI accepts a caller-minted UUID and a positional opening; `--` keeps a leading dash in
    /// that opening out of Grok's option parser.
    func testGrokLaunchMintsSessionIDAndCarriesModelPermissionAndPrompt() throws {
        let project = Project(name: "p", folderURL: URL(fileURLWithPath: "/tmp/p"))
        let id = SessionID()
        var session = AgentSession(kind: .grok, title: "t", model: "grok-4.5", id: id)
        session.permissionMode = .acceptEdits
        let opening = "- inspect this safely"

        let plan = try AgentLauncher.plan(for: session, in: project, initialPrompt: opening)
        let words = try Self.tokenizing(XCTUnwrap(plan.arguments.last))
        let transcriptID = TranscriptID(id.uuidString.lowercased())

        // Grok accepts this UUID immediately, but does not persist a conversation while its
        // first-login screen is open. The controller promotes it only after `sessions list`
        // confirms the record exists.
        XCTAssertEqual(plan.resumeState, .awaitingIdentifier)
        XCTAssertEqual(words.suffix(9), [
            AgentDefaults.grokExecutable,
            "--model",
            "grok-4.5",
            "--permission-mode",
            "acceptEdits",
            "--session-id",
            transcriptID.rawValue,
            "--",
            opening
        ])
    }

    func testGrokResumeUsesExistingSessionAndDoesNotReplayOpening() throws {
        let project = Project(name: "p", folderURL: URL(fileURLWithPath: "/tmp/p"))
        var session = AgentSession(kind: .grok, title: "t")
        let transcriptID = TranscriptID("01935b8d-8f29-7abc-9def-0123456789ab")
        session.resumeState = .resumable(transcriptID)

        let plan = try AgentLauncher.plan(
            for: session,
            in: project,
            initialPrompt: "must not be replayed"
        )
        let words = try Self.tokenizing(XCTUnwrap(plan.arguments.last))

        XCTAssertEqual(plan.resumeState, .resumable(transcriptID))
        XCTAssertNotNil(words.firstIndex(of: AgentDefaults.grokExecutable))
        XCTAssertEqual(words.suffix(2), ["--resume", transcriptID.rawValue])
        XCTAssertFalse(words.contains("must not be replayed"))
    }

    func testGrokNativeSessionRoundTrips() throws {
        var session = AgentSession(kind: .grok, title: "Grok", usesNativeUI: true)
        session.permissionMode = .auto
        let transcriptID = TranscriptID(session.id.uuidString.lowercased())
        session.resumeState = .resumable(transcriptID)

        let restored = try JSONDecoder().decode(
            AgentSession.self,
            from: JSONEncoder().encode(session)
        )

        XCTAssertEqual(restored.kind, .grok)
        XCTAssertEqual(restored.resumeState, .resumable(transcriptID))
        XCTAssertEqual(restored.permissionMode, .auto)
        XCTAssertTrue(restored.usesNativeUI)
        XCTAssertFalse(restored.kind.supportsAccounts)
        XCTAssertTrue(restored.kind.supportsPresetSessionID)
        XCTAssertTrue(restored.kind.supportsPermissionModes)
        XCTAssertTrue(restored.kind.supportsThreadingBridge)
    }

    /// And it is the *last* word, after every flag the launch grows on its way out.
    ///
    /// `routed` wraps the command and appends the MCP flags around it, so the prompt used to
    /// sit in the middle of the line. Terminating the options where it stood would have handed
    /// `--mcp-config` to the CLI as more prompt text — the operand has to move to the end, not
    /// just gain a `--`.
    // MARK: - Settings research one-shots

    /// `enabled_tools` is fixed for the life of a Codex process, while Manager is a role the
    /// user can confer after launch. The provider ceiling therefore keeps the exact supervision
    /// identities even when both the current session grant and the group switch hide them from
    /// `tools/list`; Threading remains the authority that makes them visible and admits calls.
    func testCodexLaunchCeilingKeepsToolsNeededByALaterManagerGrant() throws {
        let settings = AppSettings.shared
        let supervisionWasEnabled = settings.isToolGroupEnabled(MCPToolCatalog.supervision.id)
        settings.setToolGroup(MCPToolCatalog.supervision.id, enabled: false)
        defer {
            settings.setToolGroup(
                MCPToolCatalog.supervision.id,
                enabled: supervisionWasEnabled
            )
        }

        let session = AgentSession(kind: .codex, title: "ordinary chat")
        defer { MCPSessionRegistry.remove(sessionID: session.id) }

        let supervisionNames = Set(MCPTools.supervisionTools)
        XCTAssertTrue(
            Set(MCPToolCatalog.toolNames(for: session.id)).isDisjoint(with: supervisionNames),
            "a disabled group leaked into the live session catalogue"
        )

        var command = ShellCommand(word: AgentDefaults.codexExecutable)
        AgentLauncher.appendMCPFlags(
            for: session,
            to: &command,
            decision: MCPBridgeDecision(
                isEnabled: false,
                helperURL: URL(fileURLWithPath: "/missing/threading-mcp-bridge"),
                socketPath: nil,
                httpPort: 9
            )
        )
        let words = try Self.tokenizing("'cd' '/tmp' && 'exec' \(command.source)")
        let prefix = "mcp_servers.threading.enabled_tools="
        let override = try XCTUnwrap(words.first { $0.hasPrefix(prefix) })
        let array = Data(override.dropFirst(prefix.count).utf8)
        let launchNames = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: array) as? [String]
        )

        XCTAssertEqual(
            Set(launchNames).intersection(supervisionNames),
            supervisionNames,
            "the fixed provider filter would prevent a live Manager promotion"
        )
        XCTAssertTrue(words.contains(
            "mcp_servers.threading.tools.spawn_session.approval_mode=\"approve\""
        ))

        settings.setToolGroup(MCPToolCatalog.supervision.id, enabled: true)
        XCTAssertTrue(
            Set(MCPToolCatalog.toolNames(for: session.id)).isDisjoint(with: supervisionNames),
            "the provider ceiling itself conferred Manager authority"
        )
    }

    /// Projects are folders, not necessarily repositories. The helper must therefore opt out
    /// of Codex's Git preflight without weakening the read-only sandbox that bounds the run.
    func testCodexProjectResearchSupportsNonRepositoryFoldersReadOnly() throws {
        let words = try Self.tokenizing(
            XCTUnwrap(
                AgentLauncher.codexResearchPlan(
                    in: "/tmp/not-a-repository",
                    prompt: "find the mark"
                ).arguments.last
            )
        )

        XCTAssertEqual(words, [
            "env", "-u", "CODEX_HOME",
            AgentDefaults.codexExecutable,
            "--config", "check_for_update_on_startup=false",
            "--config", "model_reasoning_effort=\"low\"",
            "--sandbox", "read-only",
            "exec",
            "--json",
            "--skip-git-repo-check",
            "--", "find the mark"
        ])
    }

    /// `.headlessResearch` and the settings-research command builder are the claim and the
    /// delivery — the same pairing rule the permission vocabulary follows. A runtime claiming
    /// the capability must produce a one-shot line, and one that does not must refuse even
    /// with the MCP wiring handed to it.
    func testHeadlessResearchCapabilityAgreesWithTheCommandItProduces() {
        for kind in AgentKind.allCases {
            let command = AgentLauncher.settingsResearchCommand(
                kind: kind,
                prompt: "p",
                mcpConfigPath: "/tmp/mcp.json",
                binding: .http(url: "http://127.0.0.1:9/mcp/t")
            )
            XCTAssertEqual(
                command != nil,
                kind.supports(.headlessResearch),
                "\(kind) disagrees with its own research surface"
            )
        }
    }

    /// The Claude one-shot, word for word: default-account routing, print mode with the JSON
    /// envelope, no built-in tools, only Threading's MCP server, and only the one tool
    /// pre-approved — with the query kept last, behind `--`.
    func testClaudeSettingsResearchRunsScopedPrintModeOnTheDefaultAccount() throws {
        let command = try XCTUnwrap(AgentLauncher.settingsResearchCommand(
            kind: .claude,
            prompt: "make it stop flashing",
            mcpConfigPath: "/tmp/scope.json",
            binding: nil
        ))
        let words = try Self.tokenizing(
            ShellCommand.executing(command, in: "/tmp/scratch").source
        )

        XCTAssertEqual(words, [
            "env", "-u", "CLAUDE_CONFIG_DIR",
            AgentDefaults.claudeExecutable,
            "--model", AgentDefaults.claudeResearchModel,
            "--print",
            "--output-format", "json",
            "--tools", "",
            "--mcp-config", "/tmp/scope.json",
            "--strict-mcp-config",
            "--allowedTools", "mcp__threading__list_settings",
            "--", "make it stop flashing"
        ])
    }

    /// The Codex one-shot: `codexResearchPlan`'s posture plus the scoped MCP overrides, and
    /// `--skip-git-repo-check` because the run works in a scratch directory, not a checkout.
    func testCodexSettingsResearchRunsScopedReadOnlyExecOnTheDefaultAccount() throws {
        let command = try XCTUnwrap(AgentLauncher.settingsResearchCommand(
            kind: .codex,
            prompt: "make it stop flashing",
            mcpConfigPath: nil,
            binding: .http(url: "http://127.0.0.1:9/mcp/t")
        ))
        let words = try Self.tokenizing(
            ShellCommand.executing(command, in: "/tmp/scratch").source
        )

        XCTAssertEqual(words, [
            "env", "-u", "CODEX_HOME",
            AgentDefaults.codexExecutable,
            "--config", "check_for_update_on_startup=false",
            "--config", "model_reasoning_effort=\"low\"",
            "--sandbox", "read-only",
            "--config", "mcp_servers.threading.url=\"http://127.0.0.1:9/mcp/t\"",
            "--config", "mcp_servers.threading.enabled_tools=[\"list_settings\"]",
            "--config", "mcp_servers.threading.tools.list_settings.approval_mode=\"approve\"",
            "exec",
            "--json",
            "--skip-git-repo-check",
            "--", "make it stop flashing"
        ])
    }

    /// The same one-shot addressed through the stdio bridge: `command` and `args` where the URL
    /// was, and **no** `url` at all. Codex's `mcp_servers` table takes either address, not both,
    /// and a table carrying both would be asking it which of two places this server is.
    func testCodexSettingsResearchNamesTheBridgeCommandInsteadOfAURL() throws {
        let invocation = MCPBridgeInvocation(
            command: "/Applications/Threading.app/Contents/Helpers/threading-mcp-bridge",
            arguments: ["--socket", "/tmp/b/mcp.sock", "--token", "t0", "--cache", "/tmp/c.json"]
        )
        let command = try XCTUnwrap(AgentLauncher.settingsResearchCommand(
            kind: .codex,
            prompt: "make it stop flashing",
            mcpConfigPath: nil,
            binding: .stdio(invocation)
        ))
        let words = try Self.tokenizing(
            ShellCommand.executing(command, in: "/tmp/scratch").source
        )

        XCTAssertEqual(words, [
            "env", "-u", "CODEX_HOME",
            AgentDefaults.codexExecutable,
            "--config", "check_for_update_on_startup=false",
            "--config", "model_reasoning_effort=\"low\"",
            "--sandbox", "read-only",
            "--config", "mcp_servers.threading.command=\"\(invocation.command)\"",
            "--config", "mcp_servers.threading.args=[\"--socket\",\"/tmp/b/mcp.sock\","
                + "\"--token\",\"t0\",\"--cache\",\"/tmp/c.json\"]",
            "--config", "mcp_servers.threading.enabled_tools=[\"list_settings\"]",
            "--config", "mcp_servers.threading.tools.list_settings.approval_mode=\"approve\"",
            "exec",
            "--json",
            "--skip-git-repo-check",
            "--", "make it stop flashing"
        ])
        XCTAssertFalse(
            words.contains { $0.hasPrefix("mcp_servers.threading.url=") },
            "the stdio form must not also name a URL: \(words)"
        )
    }

    /// A research run without its MCP wiring has no catalogue to read, so it refuses to
    /// launch rather than spending a run to be told nothing.
    func testASettingsResearchRunWithoutItsEndpointRefusesToLaunch() {
        XCTAssertNil(AgentLauncher.settingsResearchCommand(
            kind: .claude,
            prompt: "p",
            mcpConfigPath: nil,
            binding: .http(url: "http://127.0.0.1:9/mcp/t")
        ))
        XCTAssertNil(AgentLauncher.settingsResearchCommand(
            kind: .codex,
            prompt: "p",
            mcpConfigPath: "/tmp/scope.json",
            binding: nil
        ))
    }

    func testTheOpeningPromptIsTheLastWordOnTheLine() throws {
        let opening = "an ordinary opening"
        let project = Project(name: "p", folderURL: URL(fileURLWithPath: "/tmp/p"))
        let session = AgentSession(kind: .claude, title: "t")

        let words = try Self.tokenizing(
            XCTUnwrap(
                try AgentLauncher.plan(
                    for: session,
                    in: project,
                    initialPrompt: opening
                ).arguments.last
            )
        )

        XCTAssertEqual(words.last, opening)
        XCTAssertEqual(
            words.firstIndex(of: opening),
            words.count - 1,
            "the prompt appears before the end of the line"
        )
    }

    /// The rule holds however the command is assembled afterwards: `ShellCommand` composition
    /// is what carries the operand to the end, so a command appended *into* another keeps it
    /// there rather than leaving it stranded mid-line.
    func testAComposedCommandKeepsItsOperandLast() {
        var inner = ShellCommand(word: "claude")
        inner.append(operand: "- do the thing")

        var outer = ShellCommand(word: "env")
        outer.append(contentsOf: inner)
        outer.append(flag: "--mcp-config", value: "/tmp/c.json")

        XCTAssertEqual(outer.source, "'env' 'claude' '--mcp-config' '/tmp/c.json' -- '- do the thing'")
    }

    /// The residue check, checked.
    ///
    /// This helper was wrong on its first outing — it read the quoter's `'\''` escape as syntax
    /// and failed a launch line that was perfectly quoted. A test whose helper can be wrong in
    /// one direction can be wrong in the other, and a residue parser that finds nothing is a
    /// test that passes for the worst possible reason.
    func testTheResidueCheckSeesUnquotedSyntax() {
        XCTAssertEqual(Self.strippingQuotedSpans("'a' && 'b'").trimmingCharacters(in: .whitespaces), "&&")
        XCTAssertEqual(Self.strippingQuotedSpans("'a'; rm -rf ~"), "; rm -rf ~")
        XCTAssertEqual(Self.strippingQuotedSpans("'a'$(id)"), "$(id)")
        XCTAssertEqual(Self.strippingQuotedSpans("'a'`id`"), "`id`")

        // And is silent on a correctly quoted word containing every one of those.
        var quoted = ShellCommand(word: "echo")
        quoted.append(word: "; $(id) `id` && it's fine")
        XCTAssertEqual(Self.strippingQuotedSpans(quoted.source).trimmingCharacters(in: .whitespaces), "")
    }

    func testTerminalOnlyRuntimeRefusesEveryNativeConversationBoundary() throws {
        let session = AgentSession(kind: .openCode, title: "Terminal only")
        let project = Project(
            name: "Terminal only",
            folderURL: URL(fileURLWithPath: "/tmp/terminal-only")
        )

        XCTAssertNil(ConversationViewController(
            agentSession: session,
            project: project,
            currentSessionProjection: CurrentSessionProjection { _ in session }
        ))
        XCTAssertThrowsError(try AgentLauncher.streamPlan(for: session, in: project)) { error in
            XCTAssertEqual(
                error as? AgentLaunchPlanningError,
                .unsupportedNativeConversation(.openCode)
            )
        }
    }

    // MARK: - Helpers

    /// The words the CLI would receive, tokenized by a shell rather than re-derived here.
    ///
    /// The launch line *starts an agent*, so it is never run: the fixed `cd … && exec ` prefix
    /// is dropped and what remains is handed to `set --`, which splits and unquotes it exactly
    /// as the shell would have before `printf` reports the words back.
    ///
    /// `exec` is an ordinary quoted word in that prefix, not raw syntax — `ShellCommand` emits
    /// only `&&` and `--` unquoted — so the marker is built from `ShellCommand` rather than
    /// written out here. A shell runs the `exec` builtin either way, but a literal `&& exec `
    /// never appears in the line and looking for one finds nothing.
    private static func tokenizing(_ launchLine: String) throws -> [String] {
        let marker = "&& \(ShellCommand(word: "exec").source) "
        let prefix = try XCTUnwrap(
            launchLine.range(of: marker),
            "the launch line stopped being 'cd … && exec …'"
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "set -- \(launchLine[prefix.upperBound...]); printf '%s\u{1}' \"$@\""
        ]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return String(decoding: data, as: UTF8.self)
            .split(separator: "\u{1}", omittingEmptySubsequences: false)
            .dropLast()
            .map(String.init)
    }

    /// Removes everything a shell would read as part of a *word*, leaving only what it would
    /// read as syntax.
    ///
    /// Two rules, and the second is the one this got wrong first: inside `'…'` nothing is
    /// special, and *outside* it a backslash makes the next character literal. The quoter emits
    /// a literal apostrophe as `'\''` — close, escaped quote, reopen — so a parser that only
    /// toggles on quotes sees the escape as syntax and reports a false positive on any string
    /// containing an apostrophe.
    private static func strippingQuotedSpans(_ source: String) -> String {
        var remainder = ""
        var isQuoted = false
        let characters = Array(source)
        var index = 0

        while index < characters.count {
            let character = characters[index]

            if isQuoted {
                isQuoted = character != "'"
                index += 1
                continue
            }

            switch character {
            case "'":
                isQuoted = true
            case "\\":
                // The escaped character belongs to the word, not to the syntax.
                index += 1
            default:
                remainder.append(character)
            }

            index += 1
        }

        return remainder
    }
}

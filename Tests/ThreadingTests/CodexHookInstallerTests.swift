import XCTest
@testable import Threading

/// Covers the rules that keep installing hooks from damaging a `hooks.json` the user owns.
final class CodexHookInstallerTests: XCTestCase {

    private var codexHome: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-codex-hooks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let codexHome { try? FileManager.default.removeItem(at: codexHome) }
        codexHome = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private var hooksFile: URL {
        CodexHookInstaller.hooksFile(inCodexHome: codexHome.path)
    }

    private func write(_ document: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: document)
        try data.write(to: hooksFile)
    }

    private func read() throws -> [String: Any] {
        let data = try Data(contentsOf: hooksFile)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func entries(forEvent event: String) throws -> [[String: Any]] {
        let hooks = try XCTUnwrap(read()["hooks"] as? [String: Any])
        return (hooks[event] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
    }

    private func commands(forEvent event: String) throws -> [String] {
        try entries(forEvent: event).flatMap { entry -> [String] in
            (entry["hooks"] as? [Any] ?? []).compactMap {
                ($0 as? [String: Any])?["command"] as? String
            }
        }
    }

    private func runShell(_ command: String, environment: [String: String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = environment
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        try process.run()
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    /// One foreign entry, shaped exactly like the file this machine already had.
    private func foreignDocument() -> [String: Any] {
        [
            "hooks": [
                "SessionStart": [
                    ["hooks": [["type": "command", "command": "/other/tool report", "timeout": 5]]]
                ]
            ]
        ]
    }

    /// The exact text written by the last pre-rename installer, spelled out in literals.
    ///
    /// Deliberately not built from `MCPDefaults`: this is a record of what is sitting in a
    /// real file on a machine that installed the old build, and it must keep saying that after
    /// the constants it was once derived from have been deleted.
    private func legacyCommand(for event: HookLifecycleEvent) -> String {
        let url = "http://\(MCPDefaults.host):$SKALMAN_MCP_PORT"
            + "\(MCPDefaults.lifecyclePathPrefix)"
            + "$SKALMAN_SESSION_TOKEN"
            + "?\(MCPDefaults.lifecycleEventParameter)=\(event.rawValue)"

        return "skalman_payload=$(cat);"
            + " [ -n \"$SKALMAN_SESSION_TOKEN\" ] &&"
            + " printf '%s' \"$skalman_payload\" |"
            + " curl -s --max-time \(Int(MCPDefaults.lifecycleTimeout))"
            + " -H 'Content-Type: application/json' --data-binary @- \"\(url)\""
            + " >/dev/null 2>&1; true # skalman-lifecycle"
    }

    private func legacyPermissionCommand() -> String {
        let url = "http://\(MCPDefaults.host):$SKALMAN_MCP_PORT"
            + "\(MCPDefaults.permissionPathPrefix)"
            + "$SKALMAN_SESSION_TOKEN"

        return "skalman_payload=$(cat);"
            + " [ -n \"$SKALMAN_BROKER_TOOLS\" ] &&"
            + " printf '%s' \"$skalman_payload\" |"
            + " curl -s --max-time \(Int(MCPDefaults.permissionTimeout))"
            + " -H 'Content-Type: application/json' --data-binary @- \"\(url)\";"
            + " true # skalman-lifecycle"
    }

    private func legacyDocument() -> [String: Any] {
        var hooks: [String: [[String: Any]]] = [:]
        for event in HookLifecycleEvent.allCases {
            let registration = event.codexRegistration
            guard registration.isSupported else { continue }
            for name in registration.eventNames {
                hooks[name, default: []].append([
                    "hooks": [[
                        "type": "command",
                        "command": legacyCommand(for: event),
                        "timeout": Int(MCPDefaults.lifecycleTimeout)
                    ]]
                ])
            }
        }
        hooks["PreToolUse", default: []].append([
            "hooks": [[
                "type": "command",
                "command": legacyPermissionCommand(),
                "timeout": Int(MCPDefaults.permissionTimeout)
            ]]
        ])
        return ["hooks": hooks]
    }

    // MARK: - Installing

    func testInstallPreservesAnUnreadableStandingHooksFile() throws {
        let standing = Data("not json\n".utf8)
        try standing.write(to: hooksFile)

        XCTAssertFalse(CodexHookInstaller.install(inCodexHome: codexHome.path))
        XCTAssertEqual(try Data(contentsOf: hooksFile), standing)
    }

    func testInstallPreservesAnOversizedStandingHooksFile() throws {
        let standing = Data(count: CodexHookInstaller.maximumHooksBytes + 1)
        try standing.write(to: hooksFile)

        XCTAssertFalse(CodexHookInstaller.install(inCodexHome: codexHome.path))
        XCTAssertEqual(
            try hooksFile.resourceValues(forKeys: [.fileSizeKey]).fileSize,
            standing.count
        )
    }

    func testInstallCreatesEntriesForEveryMappedEvent() throws {
        XCTAssertTrue(CodexHookInstaller.install(inCodexHome: codexHome.path))

        let hooks = try XCTUnwrap(read()["hooks"] as? [String: Any])

        for event in HookLifecycleEvent.allCases {
            for name in event.codexRegistration.eventNames {
                XCTAssertNotNil(hooks[name], "\(name) should have been installed")
            }
        }
    }

    /// A hook Codex cannot scope to particular tools must not be installed unscoped. An
    /// unmatched `PreToolUse` reporting a *question* would say that every command Codex runs is
    /// one the user is blocked on, which is worse than reporting nothing.
    func testInstallWritesNoToolScopedEntryWithoutItsMatcher() throws {
        CodexHookInstaller.install(inCodexHome: codexHome.path)

        let hooks = try XCTUnwrap(read()["hooks"] as? [String: Any])
        let preToolUse = try XCTUnwrap(hooks["PreToolUse"] as? [[String: Any]])

        XCTAssertEqual(
            preToolUse.count,
            1,
            "only the permission broker registers on PreToolUse for Codex today"
        )
        XCTAssertNil(preToolUse[0][HookRegistrationDefaults.matcherKey])
    }

    /// Codex has no `Notification`, so writing one would put an event into the file that the
    /// CLI never fires and cannot validate.
    func testInstallWritesNoEventCodexDoesNotHave() throws {
        CodexHookInstaller.install(inCodexHome: codexHome.path)

        let hooks = try XCTUnwrap(read()["hooks"] as? [String: Any])
        XCTAssertNil(hooks["Notification"])
    }

    /// The one that matters most: this machine's own `hooks.json` belongs to another tool.
    func testInstallKeepsAnotherToolsEntries() throws {
        try write(foreignDocument())

        CodexHookInstaller.install(inCodexHome: codexHome.path)

        let commands = try commands(forEvent: "SessionStart")
        XCTAssertTrue(commands.contains("/other/tool report"), "the other tool's hook was lost")
        XCTAssertTrue(commands.contains { $0.contains(MCPDefaults.hookMarker) })
    }

    /// Installing twice must not stack duplicates, or every launch would add another curl to
    /// every turn.
    func testInstallingTwiceDoesNotDuplicate() throws {
        CodexHookInstaller.install(inCodexHome: codexHome.path)
        let first = try commands(forEvent: "SessionStart")

        CodexHookInstaller.install(inCodexHome: codexHome.path)
        let second = try commands(forEvent: "SessionStart")

        XCTAssertEqual(first, second)
    }

    /// A command carrying our old marker is ours, and is replaced rather than left to rot.
    /// Foreign entries remain untouched. This is why the pre-rename marker is still admitted:
    /// stop recognising it and this entry would be stranded in the user's file for ever.
    func testInstallReplacesUnknownPreRenameEntriesAndKeepsForeignHooks() throws {
        let legacyCommand = "skalman_payload=$(cat); true # skalman-lifecycle"
        try write([
            "hooks": [
                "SessionStart": [
                    ["hooks": [[
                        "type": "command",
                        "command": "/other/tool report",
                        "timeout": 5
                    ]]],
                    ["hooks": [[
                        "type": "command",
                        "command": legacyCommand,
                        "timeout": 2
                    ]]]
                ]
            ]
        ])

        XCTAssertTrue(CodexHookInstaller.install(inCodexHome: codexHome.path))

        let commands = try commands(forEvent: "SessionStart")
        XCTAssertTrue(commands.contains("/other/tool report"), "the foreign hook was lost")
        XCTAssertFalse(commands.contains(legacyCommand), "the inert pre-rename hook survived")
        XCTAssertEqual(
            commands.filter { $0.contains(MCPDefaults.hookMarker) }.count,
            1,
            "the migrated lifecycle hook must be installed exactly once"
        )
    }

    /// A complete pre-rename installation is now replaced, not preserved.
    ///
    /// It used to be kept byte-for-byte, because the launch exported `SKALMAN_*` aliases that
    /// kept the old text runnable and its Codex trust hash intact. Those aliases are gone, so
    /// the old command would call an address nothing answers on — a hook that is trusted and
    /// broken is worse than one the user is asked to approve again.
    func testInstallReplacesACompletePreRenameInstallation() throws {
        try write(legacyDocument())

        XCTAssertTrue(CodexHookInstaller.install(inCodexHome: codexHome.path))

        for event in HookLifecycleEvent.allCases {
            let registration = event.codexRegistration
            guard registration.isSupported else { continue }
            for name in registration.eventNames {
                let commands = try commands(forEvent: name)
                XCTAssertFalse(
                    commands.contains(legacyCommand(for: event)),
                    "a pre-rename \(name) hook survived and now points nowhere"
                )
                XCTAssertTrue(commands.contains { $0.contains(MCPDefaults.hookMarker) })
            }
        }
        let preToolUse = try commands(forEvent: "PreToolUse")
        XCTAssertFalse(preToolUse.contains(legacyPermissionCommand()))
        XCTAssertTrue(preToolUse.contains { $0.contains(MCPDefaults.hookMarker) })
    }

    /// Codex trusts a hook by hashing its text, so an unnecessary rewrite would revoke the
    /// user's trust decision and silently stop the hooks running.
    func testSecondInstallDoesNotRewriteTheFile() {
        XCTAssertTrue(CodexHookInstaller.install(inCodexHome: codexHome.path))
        XCTAssertFalse(
            CodexHookInstaller.install(inCodexHome: codexHome.path),
            "an unchanged install must not rewrite the file"
        )
    }

    /// Every launch-specific value reaches the hook through the environment, keeping the shared
    /// reviewed command byte-stable while still admitting a loopback fallback.
    func testCommandCarriesNoLaunchSpecificValues() {
        var commands = HookLifecycleEvent.allCases.map(CodexHookInstaller.command(for:))
        commands.append(CodexHookInstaller.permissionCommand())

        for command in commands {
            XCTAssertTrue(command.contains("$\(MCPDefaults.sessionTokenEnvironmentKey)"))
            XCTAssertTrue(command.contains(MCPDefaults.hookMarker))
            XCTAssertTrue(command.contains("--unix-socket \"$\(MCPDefaults.socketEnvironmentKey)\""))
            XCTAssertTrue(command.contains("http://\(MCPDefaults.host):$\(MCPDefaults.portEnvironmentKey)"))
            XCTAssertFalse(command.contains(MCPBridgeLocation.socketPath))
        }
    }

    /// The trust-hash claim, asserted on the bytes rather than on the generator.
    ///
    /// Codex pins a trusted hook by hashing its command text, so two consecutive "launches"
    /// must leave the file byte-for-byte identical. Every launch-specific value is supplied by
    /// the child-process environment rather than baked into this file.
    func testTheFileWrittenByTwoLaunchesIsByteIdentical() throws {
        XCTAssertTrue(CodexHookInstaller.install(inCodexHome: codexHome.path))
        let first = try Data(contentsOf: hooksFile)

        XCTAssertFalse(
            CodexHookInstaller.install(inCodexHome: codexHome.path),
            "a second launch rewrote the file and revoked the user's trust decision"
        )
        XCTAssertEqual(try Data(contentsOf: hooksFile), first)
    }

    /// The file is read by every Codex run under the account, including ones the user starts
    /// themselves. Those carry no token and must not spawn a request per turn.
    func testCommandsMakeNoRequestWithoutTheirScopeVariables() throws {
        let fakeBin = codexHome.appendingPathComponent("fake-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeBin, withIntermediateDirectories: true)
        let marker = codexHome.appendingPathComponent("curl-was-called")
        let curl = fakeBin.appendingPathComponent("curl")
        try Data("#!/bin/sh\nprintf called > \"$FAKE_CURL_MARKER\"\n".utf8).write(to: curl)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: curl.path
        )
        let environment = [
            "PATH": "\(fakeBin.path):/usr/bin:/bin",
            "FAKE_CURL_MARKER": marker.path,
            MCPDefaults.socketEnvironmentKey: "/unreachable/threading.sock",
            MCPDefaults.portEnvironmentKey: "65535"
        ]

        try runShell(CodexHookInstaller.command(for: .turnStarted), environment: environment)
        try runShell(CodexHookInstaller.permissionCommand(), environment: environment)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: marker.path),
            "an out-of-scope Codex process reached a Threading transport"
        )
    }

    /// Every command reads stdin *before* its guard.
    ///
    /// Codex writes the event into the hook's stdin, so a guard that returns without reading
    /// leaves the CLI writing into a pipe nobody drains — and it is the unrouted sessions, the
    /// user's own, that would pay for it. Found by a probe whose hook posted an empty body.
    func testEveryCommandDrainsStdinBeforeGuarding() {
        var commands = HookLifecycleEvent.allCases.map(CodexHookInstaller.command(for:))
        commands.append(CodexHookInstaller.permissionCommand())

        for command in commands {
            let read = try? XCTUnwrap(command.range(of: "=$(cat)"))
            let guardCheck = command.range(of: "[ -n ")
            XCTAssertNotNil(read, "command must read stdin: \(command)")

            if let read = read, let guardCheck {
                XCTAssertTrue(
                    read.upperBound <= guardCheck.lowerBound,
                    "stdin must be read before the guard: \(command)"
                )
            }
        }
    }

    /// A lifecycle hook must never be able to speak back to the model, and under Codex it must
    /// never fail the turn either.
    func testCommandStaysSilentAndSucceeds() {
        let command = CodexHookInstaller.command(for: .turnFinished)
        XCTAssertTrue(command.contains(">/dev/null 2>&1"))
        XCTAssertTrue(command.hasSuffix("true \(MCPDefaults.hookMarker)"))
    }

    func testTurnBoundariesAllowSnapshotBarriersWhileOtherLifecycleHooksStayBrief() {
        XCTAssertGreaterThan(
            MCPDefaults.turnStartLifecycleTimeout,
            GitReviewDefaults.timeout * 4,
            "the hook must outlive every bounded git process in an unborn-repo snapshot"
        )
        XCTAssertTrue(
            CodexHookInstaller.command(for: .turnStarted)
                .contains("--max-time \(Int(MCPDefaults.turnStartLifecycleTimeout))")
        )
        XCTAssertTrue(
            CodexHookInstaller.command(for: .turnFinished)
                .contains("--max-time \(Int(MCPDefaults.turnFinishLifecycleTimeout))")
        )
        XCTAssertEqual(
            MCPDefaults.lifecycleTimeout(for: .sessionStarted),
            MCPDefaults.lifecycleTimeout
        )
    }

    // MARK: - Permission Hook

    func testInstallWritesThePermissionHook() throws {
        CodexHookInstaller.install(inCodexHome: codexHome.path)

        let commands = try commands(forEvent: "PreToolUse")
        XCTAssertEqual(commands.count, 1)
        XCTAssertTrue(commands[0].contains(MCPDefaults.permissionPathPrefix))
    }

    /// Scoped by a *second* variable, not the session token: `hooks.json` is shared by every
    /// session under the account, but only the surface Threading renders itself should be
    /// intercepted — a terminal session has Codex's own approval prompt.
    func testPermissionCommandIsGuardedByTheBrokerVariable() {
        let command = CodexHookInstaller.permissionCommand()

        XCTAssertTrue(command.contains("[ -n \"$\(MCPDefaults.brokerEnvironmentKey)\" ]"))
        XCTAssertFalse(
            command.contains("[ -n \"$\(MCPDefaults.sessionTokenEnvironmentKey)\" ]"),
            "guarding on the token would broker terminal sessions too"
        )
    }

    /// Unlike the lifecycle hooks, this one's stdout *is* the decision — silencing it would
    /// turn every answer into "no opinion".
    func testPermissionCommandSpeaksItsAnswer() {
        let command = CodexHookInstaller.permissionCommand()

        XCTAssertFalse(command.contains(">/dev/null"))
        XCTAssertTrue(command.contains("--max-time \(Int(MCPDefaults.permissionTimeout))"))
    }

    /// A brokered Codex session whose Threading is gone is refused **in words**.
    ///
    /// Measured on 0.144.6: a `deny` reply stops the tool and its reason reaches the model. The
    /// reply is the same object `MCPServer.routePermission` sends, because both providers post
    /// to one endpoint and are answered by one `PermissionDecision.hookResponse`.
    func testAnUnreachableAppDeniesInWordsWithTheAppsOwnAnswer() throws {
        let answer = try shellAnswer(
            CodexHookInstaller.permissionCommand(),
            payload: #"{"tool_name":"shell","tool_input":{"command":["ls"]}}"#,
            environment: [
                "PATH": "/usr/bin:/bin",
                MCPDefaults.brokerEnvironmentKey: "1",
                MCPDefaults.sessionTokenEnvironmentKey: "codex-fixture-token",
                MCPDefaults.socketEnvironmentKey: "/nonexistent/threading-slice2.sock",
                MCPDefaults.portEnvironmentKey: ""
            ]
        )

        XCTAssertEqual(answer.status, 0)

        let decision = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(answer.output.utf8)) as? [String: Any],
            "the hook printed something Codex cannot parse: \(answer.output)"
        )
        let output = try XCTUnwrap(decision["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(output["permissionDecision"] as? String, "deny")
        XCTAssertFalse((output["permissionDecisionReason"] as? String ?? "").isEmpty)
        XCTAssertEqual(
            decision as NSDictionary,
            PermissionDecision.deny(reason: MCPDefaults.hookDenyReason).hookResponse as NSDictionary
        )
    }

    /// And the run this file is *shared* with says nothing at all.
    ///
    /// `hooks.json` is read by every Codex under the account, including the user's own terminal
    /// sessions, which have Codex's own approval prompt. `guard && post || deny` would refuse
    /// every tool call in those; the guard and the deny therefore share one brace group.
    func testAnUnroutedCodexRunPrintsNoDecisionAtAll() throws {
        let answer = try shellAnswer(
            CodexHookInstaller.permissionCommand(),
            payload: #"{"tool_name":"shell"}"#,
            environment: [
                "PATH": "/usr/bin:/bin",
                MCPDefaults.sessionTokenEnvironmentKey: "codex-fixture-token",
                MCPDefaults.socketEnvironmentKey: "/nonexistent/threading-slice2.sock",
                MCPDefaults.portEnvironmentKey: ""
            ]
        )

        XCTAssertEqual(answer.status, 0)
        XCTAssertEqual(answer.output, "", "a session Threading does not broker was answered for")
    }

    /// The lifecycle commands are byte-identical to what they were before the permission hook
    /// gained its fallback — asserted against frozen text, since a rewrite of this file costs
    /// the user their Codex trust decision.
    func testLifecycleCommandsAreUnchangedByThePermissionFallback() {
        for event in HookLifecycleEvent.allCases where event.codexRegistration.isSupported {
            XCTAssertEqual(
                CodexHookInstaller.command(for: event),
                Self.frozenLifecycleCommand(
                    event: event,
                    timeout: Int(MCPDefaults.lifecycleTimeout(for: event))
                ),
                "the \(event.rawValue) command is no longer byte-identical"
            )
        }
    }

    /// Runs one generated hook the way Codex does, and reads back what it said.
    private func shellAnswer(
        _ command: String,
        payload: String,
        environment: [String: String]
    ) throws -> (output: String, status: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = environment

        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        try process.run()
        input.fileHandleForWriting.write(Data(payload.utf8))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return (String(decoding: data, as: UTF8.self), process.terminationStatus)
    }

    /// The lifecycle command exactly as it read before the permission hook's fallback existed.
    ///
    /// Spelled out rather than built from `MCPDefaults.hookPostCommand`, because the property is
    /// that the builder's output still reaches these commands unchanged; comparing a generator
    /// against itself would pass through any change to it.
    private static func frozenLifecycleCommand(
        event: HookLifecycleEvent,
        timeout: Int
    ) -> String {
        let suffix = "/lifecycle/$THREADING_SESSION_TOKEN?event=\(event.rawValue)"
        let common = "-s --max-time \(timeout)"
            + " -H 'Content-Type: application/json' --data-binary @-"

        return "threading_payload=$(cat);"
            + " [ -n \"$THREADING_SESSION_TOKEN\" ] &&"
            + " ( { [ -n \"$THREADING_MCP_SOCKET\" ] &&"
            + " printf '%s' \"$threading_payload\" |"
            + " curl \(common) --unix-socket \"$THREADING_MCP_SOCKET\""
            + " \"http://localhost\(suffix)\"; }"
            + " || { [ -n \"$THREADING_MCP_PORT\" ] &&"
            + " printf '%s' \"$threading_payload\" |"
            + " curl \(common) \"http://127.0.0.1:$THREADING_MCP_PORT\(suffix)\"; } )"
            + " >/dev/null 2>&1; true # threading-lifecycle"
    }

    // MARK: - Uninstalling

    func testUninstallRemovesOnlyOurEntries() throws {
        try write(foreignDocument())
        CodexHookInstaller.install(inCodexHome: codexHome.path)

        XCTAssertTrue(CodexHookInstaller.uninstall(fromCodexHome: codexHome.path))

        let commands = try commands(forEvent: "SessionStart")
        XCTAssertEqual(commands, ["/other/tool report"])
    }

    /// An event we were alone in using is dropped entirely, rather than left as an empty array
    /// that reads as configuration.
    func testUninstallDropsEventsLeftEmpty() throws {
        CodexHookInstaller.install(inCodexHome: codexHome.path)
        CodexHookInstaller.uninstall(fromCodexHome: codexHome.path)

        let hooks = try XCTUnwrap(read()["hooks"] as? [String: Any])
        XCTAssertTrue(hooks.isEmpty)
    }

    func testUninstallWithNothingInstalledChangesNothing() throws {
        try write(foreignDocument())

        XCTAssertFalse(CodexHookInstaller.uninstall(fromCodexHome: codexHome.path))
        XCTAssertEqual(try commands(forEvent: "SessionStart"), ["/other/tool report"])
    }

    func testUninstallWithNoFileIsHarmless() {
        XCTAssertFalse(CodexHookInstaller.uninstall(fromCodexHome: codexHome.path))
    }

    /// Turning the integration off after the rename removes the entry the same product wrote
    /// before the rename too; otherwise the off switch leaves a dead hook in a user-owned file.
    func testUninstallRemovesPreRenameEntries() throws {
        try write([
            "hooks": [
                "Stop": [
                    ["hooks": [[
                        "type": "command",
                        "command": "skalman_payload=$(cat); true # skalman-lifecycle",
                        "timeout": 2
                    ]]]
                ]
            ]
        ])

        XCTAssertTrue(CodexHookInstaller.uninstall(fromCodexHome: codexHome.path))
        XCTAssertTrue(try entries(forEvent: "Stop").isEmpty)
    }

    // MARK: - Pre-Rename Preference

    @MainActor
    func testHostedTestsDoNotImportTheDevelopersLegacyPreferences() {
        XCTAssertFalse(AppSettings.importsLegacyPreferencesForSharedProcess)
    }

    /// The integration was already an explicit opt-in before the bundle-id rename. Carrying
    /// that one choice is what makes the installer above run on the next Codex launch.
    @MainActor
    func testPreRenameHookOptInIsCarriedWhenTheCurrentDomainHasNoChoice() throws {
        let suite = "CodexHookPreferenceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(
            defaults: defaults,
            legacyPreferences: ["installsCodexHooks": true]
        )

        XCTAssertTrue(settings.installsCodexHooks)
        XCTAssertEqual(
            defaults.persistentDomain(forName: suite)?["installsCodexHooks"] as? Bool,
            true
        )
    }

    /// A choice made under the current name is newer and authoritative, including switching
    /// the integration off after having used it before the rename.
    @MainActor
    func testCurrentHookChoiceWinsOverThePreRenameOptIn() throws {
        let suite = "CodexHookPreferenceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "installsCodexHooks")

        let settings = AppSettings(
            defaults: defaults,
            legacyPreferences: ["installsCodexHooks": true]
        )

        XCTAssertFalse(settings.installsCodexHooks)
    }

    /// The bypass was a separate, explicit choice before the rename too. If the integration is
    /// still enabled, carrying that `true` restores the same launch posture rather than leaving
    /// hooks inert on machines that deliberately relied on the bypass.
    @MainActor
    func testPreRenameHookTrustBypassIsCarriedWithTheEnabledIntegration() throws {
        let suite = "CodexHookPreferenceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(
            defaults: defaults,
            legacyPreferences: [
                "installsCodexHooks": true,
                "bypassesCodexHookTrust": true
            ]
        )

        XCTAssertTrue(settings.installsCodexHooks)
        XCTAssertTrue(settings.bypassesCodexHookTrust)
    }

    /// A current off choice for the integration is authoritative and must not revive its
    /// security-sensitive bypass from the old domain.
    @MainActor
    func testCurrentHookOptOutDoesNotCarryThePreRenameTrustBypass() throws {
        let suite = "CodexHookPreferenceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "installsCodexHooks")

        let settings = AppSettings(
            defaults: defaults,
            legacyPreferences: [
                "installsCodexHooks": true,
                "bypassesCodexHookTrust": true
            ]
        )

        XCTAssertFalse(settings.installsCodexHooks)
        XCTAssertFalse(settings.bypassesCodexHookTrust)
    }

    /// Keys other than `hooks` belong to whoever wrote them.
    func testInstallPreservesUnrelatedTopLevelKeys() throws {
        try write(["hooks": [:], "somethingElse": ["kept": true]])

        CodexHookInstaller.install(inCodexHome: codexHome.path)

        XCTAssertNotNil(try read()["somethingElse"])
    }
}

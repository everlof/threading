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

    /// The exact text written by the last pre-rename installer. Keeping the fixture here makes
    /// the compatibility claim independent of the current generator it is testing.
    private func legacyCommand(for event: HookLifecycleEvent) -> String {
        let url = "http://\(MCPDefaults.host):$\(MCPDefaults.legacyPortEnvironmentKey)"
            + "\(MCPDefaults.lifecyclePathPrefix)"
            + "$\(MCPDefaults.legacySessionTokenEnvironmentKey)"
            + "?\(MCPDefaults.lifecycleEventParameter)=\(event.rawValue)"

        return "skalman_payload=$(cat);"
            + " [ -n \"$\(MCPDefaults.legacySessionTokenEnvironmentKey)\" ] &&"
            + " printf '%s' \"$skalman_payload\" |"
            + " curl -s --max-time \(Int(MCPDefaults.lifecycleTimeout))"
            + " -H 'Content-Type: application/json' --data-binary @- \"\(url)\""
            + " >/dev/null 2>&1; true # skalman-lifecycle"
    }

    private func legacyPermissionCommand() -> String {
        let url = "http://\(MCPDefaults.host):$\(MCPDefaults.legacyPortEnvironmentKey)"
            + "\(MCPDefaults.permissionPathPrefix)"
            + "$\(MCPDefaults.legacySessionTokenEnvironmentKey)"

        return "skalman_payload=$(cat);"
            + " [ -n \"$\(MCPDefaults.legacyBrokerEnvironmentKey)\" ] &&"
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

    /// An arbitrary command with our old marker is still ours, but it is not one of the exact
    /// commands made compatible by the launch aliases. Replace it rather than trusting a stale
    /// shape forever; foreign entries remain untouched.
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

    /// Codex trusts a hook by its exact command text. A complete installation from before the
    /// product rename remains runnable through launch aliases, so installing must leave the
    /// entire document byte-for-byte alone rather than revoking that existing trust decision.
    func testInstallPreservesKnownPreRenameHooksWithoutRewriting() throws {
        try write(legacyDocument())
        let before = try Data(contentsOf: hooksFile)

        XCTAssertFalse(CodexHookInstaller.install(inCodexHome: codexHome.path))
        XCTAssertEqual(try Data(contentsOf: hooksFile), before)

        for event in HookLifecycleEvent.allCases {
            let registration = event.codexRegistration
            guard registration.isSupported else { continue }
            for name in registration.eventNames {
                let commands = try commands(forEvent: name)
                XCTAssertTrue(commands.contains(legacyCommand(for: event)))
                XCTAssertFalse(commands.contains { $0.contains(MCPDefaults.hookMarker) })
            }
        }
        XCTAssertTrue(try commands(forEvent: "PreToolUse").contains(legacyPermissionCommand()))
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

    /// The port and token reach the hook through the environment precisely so the text can be
    /// stable. If a literal port ever appears here, trust breaks on every app launch.
    func testCommandCarriesNoLaunchSpecificValues() {
        for event in HookLifecycleEvent.allCases {
            let command = CodexHookInstaller.command(for: event)

            XCTAssertTrue(command.contains("$\(MCPDefaults.portEnvironmentKey)"))
            XCTAssertTrue(command.contains("$\(MCPDefaults.sessionTokenEnvironmentKey)"))
            XCTAssertTrue(command.contains(MCPDefaults.hookMarker))
        }
    }

    /// The file is read by every Codex run under the account, including ones the user starts
    /// themselves. Those carry no token and must not spawn a request per turn.
    func testCommandSkipsItselfWithoutASessionToken() {
        let command = CodexHookInstaller.command(for: .turnStarted)
        XCTAssertTrue(command.contains("[ -n \"$\(MCPDefaults.sessionTokenEnvironmentKey)\" ]"))
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

    func testTurnStartAllowsSnapshotBarrierWhileOtherLifecycleHooksStayBrief() {
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
                .contains("--max-time \(Int(MCPDefaults.lifecycleTimeout))")
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

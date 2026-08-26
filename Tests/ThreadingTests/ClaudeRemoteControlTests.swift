import AppKit
import XCTest
@testable import Threading

/// Claude's own Remote Control bridge, and the two places Threading can answer for it: an
/// app-wide default for new sessions and one conversation's override.
///
/// The distinction under test throughout is between *off* and *no opinion*. Claude reads
/// `remoteControlAtStartup` from the settings file ahead of its own `/config`, so writing
/// `false` where we meant "we have not decided" would quietly override a choice the user made
/// in the CLI. Only an absent key defers, which is why the resolved value is `Bool?` from the
/// setting all the way to the JSON.
@MainActor
final class ClaudeRemoteControlTests: XCTestCase {

    private var previousDefault: ClaudeRemoteControl = .followClaude
    private var previousLifecycleReporting = true

    override func setUp() {
        super.setUp()
        previousDefault = AppSettings.shared.claudeRemoteControl
        previousLifecycleReporting = AppSettings.shared.reportsClaudeLifecycleEvents
        addTeardownBlock { @MainActor [previousDefault, previousLifecycleReporting] in
            AppSettings.shared.claudeRemoteControl = previousDefault
            AppSettings.shared.reportsClaudeLifecycleEvents = previousLifecycleReporting
        }
    }

    // MARK: - Resolution

    func testFollowingClaudeDecidesNothing() {
        AppSettings.shared.claudeRemoteControl = .followClaude
        let session = AgentSession(kind: .claude, title: "Chat")

        XCTAssertNil(AgentLauncher.remoteControlAtStartup(for: session))
    }

    func testAppDefaultAppliesToASessionThatNeverChose() {
        let session = AgentSession(kind: .claude, title: "Chat")

        AppSettings.shared.claudeRemoteControl = .enabled
        XCTAssertEqual(AgentLauncher.remoteControlAtStartup(for: session), true)

        AppSettings.shared.claudeRemoteControl = .disabled
        XCTAssertEqual(AgentLauncher.remoteControlAtStartup(for: session), false)
    }

    /// The case the feature exists for: Remote Control on everywhere, off in this one chat.
    func testOneChatCanOptOutOfAnEnabledDefault() {
        AppSettings.shared.claudeRemoteControl = .enabled

        var session = AgentSession(kind: .claude, title: "Quiet")
        XCTAssertTrue(session.setClaudeRemoteControl(false))

        XCTAssertEqual(AgentLauncher.remoteControlAtStartup(for: session), false)
    }

    /// And the reverse, which is what makes the session value an override rather than a veto.
    func testOneChatCanOptInWhileTheAppDefers() {
        AppSettings.shared.claudeRemoteControl = .followClaude

        var session = AgentSession(kind: .claude, title: "Loud")
        XCTAssertTrue(session.setClaudeRemoteControl(true))

        XCTAssertEqual(AgentLauncher.remoteControlAtStartup(for: session), true)
    }

    /// Codex has no comparable bridge, so its typed state refuses Claude's setting.
    func testCodexSessionsNeverCarryTheKey() {
        AppSettings.shared.claudeRemoteControl = .enabled

        var session = AgentSession(kind: .codex, title: "Codex")
        XCTAssertFalse(session.setClaudeRemoteControl(true))

        XCTAssertNil(AgentLauncher.remoteControlAtStartup(for: session))
    }

    // MARK: - Settings File

    func testLifecycleReportingDefaultsOnAndPersistsAnOptOut() throws {
        let suite = "ClaudeLifecycleReporting.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(settings.reportsClaudeLifecycleEvents)

        settings.reportsClaudeLifecycleEvents = false
        XCTAssertFalse(AppSettings(defaults: defaults).reportsClaudeLifecycleEvents)
    }

    func testSettingsFileCarriesTheChoice() throws {
        let sessionID = SessionID()
        let path = try XCTUnwrap(MCPSessionRegistry.writeHookSettings(
            for: sessionID,
            brokersPermissions: false,
            reportsLifecycle: true,
            remoteControl: false
        ))
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }

        let settings = try settingsJSON(at: path)
        XCTAssertEqual(settings[AgentDefaults.claudeRemoteControlKey] as? Bool, false)
    }

    func testSettingsFileNamesTheKeyClaudeReads() throws {
        let sessionID = SessionID()
        let path = try XCTUnwrap(MCPSessionRegistry.writeHookSettings(
            for: sessionID,
            brokersPermissions: false,
            reportsLifecycle: true,
            remoteControl: true
        ))
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }

        // Spelled out rather than compared to the constant: this exact string is Claude's, and a
        // rename on our side would silently stop reaching it.
        let settings = try settingsJSON(at: path)
        XCTAssertEqual(settings["remoteControlAtStartup"] as? Bool, true)
    }

    func testSettingsFileCarriesFastAndStandardUsingClaudesOwnKey() throws {
        for fast in [true, false] {
            let path = try XCTUnwrap(MCPSessionRegistry.writeHookSettings(
                for: SessionID(),
                brokersPermissions: false,
                reportsLifecycle: false,
                fastMode: fast
            ))
            addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }

            let settings = try settingsJSON(at: path)
            XCTAssertEqual(settings["fastMode"] as? Bool, fast)
            XCTAssertNil(settings["hooks"], "a speed override alone needs no listener hooks")
        }
    }

    func testDeferringSpeedWritesNoFastModeKey() throws {
        let path = try XCTUnwrap(MCPSessionRegistry.writeHookSettings(
            for: SessionID(),
            brokersPermissions: false,
            reportsLifecycle: true,
            fastMode: nil
        ))
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }

        XCTAssertNil(try settingsJSON(at: path)["fastMode"])
    }

    /// Deferring writes no key at all — while the hooks the session did ask for are written
    /// regardless, because their address is a socket path rather than a bound listener.
    func testDeferringWritesNoKey() throws {
        let sessionID = SessionID()
        let path = try XCTUnwrap(MCPSessionRegistry.writeHookSettings(
            for: sessionID,
            brokersPermissions: false,
            reportsLifecycle: true,
            remoteControl: nil
        ))
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }

        let settings = try settingsJSON(at: path)
        XCTAssertNil(settings[AgentDefaults.claudeRemoteControlKey])
    }

    /// The hooks and the Remote Control key share one file, and neither may cost the other: a
    /// brokered session still gets its `PreToolUse` entry while stating a Remote Control choice.
    func testTheChoiceTravelsBesideTheHooksRatherThanInsteadOfThem() throws {
        let sessionID = SessionID()
        let path = try XCTUnwrap(MCPSessionRegistry.writeHookSettings(
            for: sessionID,
            brokersPermissions: true,
            reportsLifecycle: true,
            remoteControl: false
        ))
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }

        let settings = try settingsJSON(at: path)
        XCTAssertEqual(settings[AgentDefaults.claudeRemoteControlKey] as? Bool, false)
        XCTAssertNotNil(settings["hooks"] as? [String: Any])
    }

    /// A status-line override travels in the same file, in the one shape the CLI's schema
    /// accepts. `type: "none"` was tried during design and rejects the *whole* file — the
    /// permission hooks with it — so the exact shape written here is load-bearing.
    func testAStatusLineOverrideIsWrittenAsACommand() throws {
        let sessionID = SessionID()
        let path = try XCTUnwrap(MCPSessionRegistry.writeHookSettings(
            for: sessionID,
            brokersPermissions: false,
            reportsLifecycle: true,
            statusLineOverride: "{ bridge ; } >/dev/null 2>&1"
        ))
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }

        let settings = try settingsJSON(at: path)
        let statusLine = try XCTUnwrap(settings["statusLine"] as? [String: Any])
        XCTAssertEqual(statusLine["type"] as? String, "command")
        XCTAssertEqual(statusLine["command"] as? String, "{ bridge ; } >/dev/null 2>&1")
        XCTAssertNotNil(settings["hooks"] as? [String: Any])
    }

    /// The override alone is a reason to write the file — a terminal with hooks off and no
    /// Remote Control choice still gets its silenced line, or the setting would silently hold
    /// only on sessions that happen to carry something else.
    func testAStatusLineOverrideAloneStillWritesTheFile() throws {
        let sessionID = SessionID()
        let path = try XCTUnwrap(MCPSessionRegistry.writeHookSettings(
            for: sessionID,
            brokersPermissions: false,
            reportsLifecycle: false,
            statusLineOverride: "true"
        ))
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }

        let settings = try settingsJSON(at: path)
        XCTAssertEqual(
            (settings["statusLine"] as? [String: Any])?["command"] as? String,
            "true"
        )
        XCTAssertNil(settings["hooks"], "no listener was asked for, so no hooks may appear")
    }

    func testTerminalOptOutWritesNoSettingsFileWithoutAnotherSettingToCarry() {
        XCTAssertNil(MCPSessionRegistry.writeHookSettings(
            for: SessionID(),
            brokersPermissions: false,
            reportsLifecycle: false,
            remoteControl: nil
        ))
    }

    func testTerminalOptOutRemovesAnEarlierAppManagedSettingsFile() throws {
        let sessionID = SessionID()
        let path = try XCTUnwrap(MCPSessionRegistry.writeHookSettings(
            for: sessionID,
            brokersPermissions: false,
            reportsLifecycle: true,
            remoteControl: false
        ))
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))

        XCTAssertNil(MCPSessionRegistry.writeHookSettings(
            for: sessionID,
            brokersPermissions: false,
            reportsLifecycle: false,
            remoteControl: nil
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testTerminalOptOutCanCarryRemoteControlWithoutAnEmptyHooksSection() throws {
        let path = try XCTUnwrap(MCPSessionRegistry.writeHookSettings(
            for: SessionID(),
            brokersPermissions: false,
            reportsLifecycle: false,
            remoteControl: false
        ))
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }

        let settings = try settingsJSON(at: path)
        XCTAssertEqual(settings[AgentDefaults.claudeRemoteControlKey] as? Bool, false)
        XCTAssertNil(settings["hooks"])
    }

    func testNativePermissionHookSurvivesLifecycleOptOut() throws {
        let path = try XCTUnwrap(MCPSessionRegistry.writeHookSettings(
            for: SessionID(),
            brokersPermissions: true,
            reportsLifecycle: false,
            remoteControl: false
        ))
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }

        let settings = try settingsJSON(at: path)
        let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        XCTAssertEqual(Set(hooks.keys), ["PreToolUse"])
    }

    func testLifecycleReportingWritesEveryEventAndNothingElse() throws {
        let path = try XCTUnwrap(MCPSessionRegistry.writeHookSettings(
            for: SessionID(),
            brokersPermissions: false,
            reportsLifecycle: true,
            remoteControl: false
        ))
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }

        let settings = try settingsJSON(at: path)
        let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        XCTAssertEqual(
            Set(hooks.keys),
            Set(HookLifecycleEvent.allCases.flatMap(\.claudeRegistration.eventNames))
        )
    }

    /// Reporting registers a `PreToolUse` hook of its own — the one that says a question tool
    /// opened — and it must not be mistaken for the permission broker. The two differ in every
    /// way that matters: this one names the tools it watches, points at the lifecycle endpoint,
    /// and throws its own output away, which is what keeps it from answering a permission
    /// question a terminal session is already asking the user itself.
    func testLifecycleReportingAddsOnlyAToolScopedObservationalPreToolUseHook() throws {
        let path = try XCTUnwrap(MCPSessionRegistry.writeHookSettings(
            for: SessionID(),
            brokersPermissions: false,
            reportsLifecycle: true,
            remoteControl: false
        ))
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }

        let settings = try settingsJSON(at: path)
        let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        let preToolUse = try XCTUnwrap(hooks["PreToolUse"] as? [[String: Any]])

        XCTAssertEqual(preToolUse.count, 1)
        XCTAssertEqual(
            preToolUse[0][HookRegistrationDefaults.matcherKey] as? String,
            TurnBlockingTools.names(for: .claude).joined(separator: "|")
        )

        let command = try XCTUnwrap(commands(in: preToolUse[0]).first)
        XCTAssertTrue(command.contains(MCPDefaults.lifecyclePathPrefix))
        XCTAssertFalse(command.contains(MCPDefaults.permissionPathPrefix))
        XCTAssertTrue(command.hasSuffix(">/dev/null 2>&1 || true"))
    }

    /// A native session brokers permission on `PreToolUse` and reports asks on it too. They are
    /// separate entries under one key, and an assignment that dropped either would either lose
    /// the sidebar's blocked mark or — far worse — leave every tool unapproved.
    func testBrokeringAndAskReportingShareThePreToolUseKeyWithoutDisplacingEachOther() throws {
        let path = try XCTUnwrap(MCPSessionRegistry.writeHookSettings(
            for: SessionID(),
            brokersPermissions: true,
            reportsLifecycle: true,
            remoteControl: false
        ))
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }

        let settings = try settingsJSON(at: path)
        let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        let preToolUse = try XCTUnwrap(hooks["PreToolUse"] as? [[String: Any]])
        let commands = preToolUse.flatMap(commands(in:))

        XCTAssertEqual(preToolUse.count, 2)
        XCTAssertEqual(commands.filter { $0.contains(MCPDefaults.permissionPathPrefix) }.count, 1)
        XCTAssertEqual(commands.filter { $0.contains(MCPDefaults.lifecyclePathPrefix) }.count, 1)

        // The broker offers every tool; only the observational entry is scoped.
        XCTAssertEqual(
            preToolUse.filter { $0[HookRegistrationDefaults.matcherKey] == nil }.count,
            1
        )
    }

    /// The ask ends whether its tool returned or was interrupted, so both hooks report it.
    func testAnAskIsClosedByBothOfClaudesToolCompletionHooks() throws {
        let path = try XCTUnwrap(MCPSessionRegistry.writeHookSettings(
            for: SessionID(),
            brokersPermissions: false,
            reportsLifecycle: true,
            remoteControl: false
        ))
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }

        let settings = try settingsJSON(at: path)
        let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])

        for name in ["PostToolUse", "PostToolUseFailure"] {
            let entries = try XCTUnwrap(hooks[name] as? [[String: Any]], "\(name) is missing")
            let command = try XCTUnwrap(commands(in: entries[0]).first)
            XCTAssertNotNil(entries[0][HookRegistrationDefaults.matcherKey])
            XCTAssertTrue(
                command.contains(HookLifecycleEvent.blockingAskClosed.rawValue),
                "\(name) must report the ask closing"
            )
        }
    }

    /// Every hook prefers the unix rendezvous and carries the loopback route as a fallback.
    func testHooksShareTheSocketFirstLoopbackFallback() throws {
        let path = try XCTUnwrap(MCPSessionRegistry.writeHookSettings(
            for: SessionID(),
            brokersPermissions: true,
            reportsLifecycle: true
        ))
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }

        let hooks = try XCTUnwrap(try settingsJSON(at: path)["hooks"] as? [String: Any])
        let commands = hooks.values
            .compactMap { $0 as? [[String: Any]] }
            .flatMap { $0.flatMap(commands(in:)) }

        XCTAssertFalse(commands.isEmpty)
        for command in commands {
            let socket = try XCTUnwrap(command.range(of: "--unix-socket"))
            let fallback = try XCTUnwrap(
                command.range(of: "http://\(MCPDefaults.host):$\(MCPDefaults.portEnvironmentKey)")
            )
            XCTAssertLessThan(socket.lowerBound, fallback.lowerBound)
            XCTAssertTrue(command.contains("$\(MCPDefaults.socketEnvironmentKey)"))
        }
    }

    /// The branch this replaced: a session used to launch with **no hooks at all** when the
    /// listener had not bound a port yet, which silently cost it accurate activity and, for a
    /// rendered session, blocked its tools with no card to approve them. A socket path answers
    /// before any listener exists, so there is nothing left to be unavailable.
    func testHooksAreWrittenWithNoListenerAtAll() throws {
        // The hosted test process starts no listener of its own; another class may have left
        // one running, in which case this says nothing and skips rather than passing hollowly.
        try XCTSkipUnless(MCPServer.shared.port == nil, "an MCP listener is already bound")

        let path = try XCTUnwrap(MCPSessionRegistry.writeHookSettings(
            for: SessionID(),
            brokersPermissions: true,
            reportsLifecycle: true
        ))
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }

        let hooks = try XCTUnwrap(try settingsJSON(at: path)["hooks"] as? [String: Any])
        XCTAssertFalse(hooks.isEmpty)
        XCTAssertNotNil(hooks["PreToolUse"])
    }

    /// Writing hooks unconditionally must not turn "no hooks requested" into a file.
    func testNothingRequestedStillWritesNothing() {
        XCTAssertNil(MCPSessionRegistry.writeHookSettings(
            for: SessionID(),
            brokersPermissions: false,
            reportsLifecycle: false
        ))
    }

    /// The commands one `hooks` entry runs.
    private func commands(in group: [String: Any]) -> [String] {
        (group["hooks"] as? [[String: Any]])?.compactMap { $0["command"] as? String } ?? []
    }

    // MARK: - Persistence

    func testTheChoiceSurvivesAnEncodeDecodeRound() throws {
        for value in [true, false] {
            var session = AgentSession(kind: .claude, title: "Chat")
            XCTAssertTrue(session.setClaudeRemoteControl(value))

            let data = try JSONEncoder().encode(session)
            let decoded = try JSONDecoder().decode(AgentSession.self, from: data)

            XCTAssertEqual(decoded.remoteControl, value)
        }
    }

    /// A session recorded before this existed has no opinion, rather than an off switch it never
    /// asked for — the same rule `fastMode` follows, and the reason both are optional.
    func testARecordWrittenBeforeThisFeatureDecodesAsNoChoice() throws {
        var session = AgentSession(kind: .claude, title: "Chat")
        XCTAssertTrue(session.setClaudeRemoteControl(nil))

        let data = try JSONEncoder().encode(session)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertNil(json["remoteControl"], "An absent choice must not be encoded at all")

        let decoded = try JSONDecoder().decode(AgentSession.self, from: data)
        XCTAssertNil(decoded.remoteControl)
    }

    func testClearingASessionChoiceReturnsItToTheAppDefault() {
        AppSettings.shared.claudeRemoteControl = .disabled

        var session = AgentSession(kind: .claude, title: "Chat")
        XCTAssertTrue(session.setClaudeRemoteControl(true))
        XCTAssertEqual(AgentLauncher.remoteControlAtStartup(for: session), true)

        XCTAssertTrue(session.setClaudeRemoteControl(nil))
        XCTAssertEqual(AgentLauncher.remoteControlAtStartup(for: session), false)
    }

    // MARK: - Wording

    /// The inherit item may not claim a value Threading cannot see: when the app defers, the
    /// answer lives in the account's own config and resolves server-side when unset.
    func testDeferringIsWordedAsDeferralRatherThanAsAValue() {
        XCTAssertEqual(ClaudeRemoteControl.followClaude.inheritedMenuTitle, "Use Claude's Setting")
        XCTAssertEqual(ClaudeRemoteControl.enabled.inheritedMenuTitle, "Use Default (On)")
        XCTAssertEqual(ClaudeRemoteControl.disabled.inheritedMenuTitle, "Use Default (Off)")
    }

    func testEveryStateIsOfferedOnTheSettingsPage() {
        XCTAssertEqual(ClaudeRemoteControl.allCases.count, 3)
        for value in ClaudeRemoteControl.allCases {
            XCTAssertFalse(value.settingsTitle.isEmpty)
        }
    }

    // MARK: - Session Menu

    /// The per-chat override is only reachable from a contextual menu, which cannot be driven
    /// from a script — so without this the wiring between an item and the value it stores would
    /// be checked by clicking it and looking.
    func testASessionMenuOffersInheritAndBothOverrides() throws {
        AppSettings.shared.claudeRemoteControl = .enabled

        let submenu = try remoteControlSubmenu(for: AgentSession(kind: .claude, title: "Chat"))

        XCTAssertEqual(
            submenu.compactMap(\.item).map(\.title),
            ["Use Default (On)", "Always On", "Always Off"]
        )
    }

    func testTheInheritItemFollowsTheAppDefault() throws {
        AppSettings.shared.claudeRemoteControl = .followClaude
        var submenu = try remoteControlSubmenu(for: AgentSession(kind: .claude, title: "Chat"))
        XCTAssertEqual(submenu.compactMap(\.item).first?.title, "Use Claude's Setting")

        AppSettings.shared.claudeRemoteControl = .disabled
        submenu = try remoteControlSubmenu(for: AgentSession(kind: .claude, title: "Chat"))
        XCTAssertEqual(submenu.compactMap(\.item).first?.title, "Use Default (Off)")
    }

    /// The tick has to sit on the session's *own* state, including when that state is "no
    /// choice" — an override the user cannot see is one they cannot undo.
    func testTheTickMarksWhatTheSessionActuallyStored() throws {
        var session = AgentSession(kind: .claude, title: "Chat")

        var ticked = try tickedTitles(for: session)
        XCTAssertEqual(ticked.count, 1)
        XCTAssertEqual(ticked.first, submenuTitles.inherit)

        XCTAssertTrue(session.setClaudeRemoteControl(false))
        ticked = try tickedTitles(for: session)
        XCTAssertEqual(ticked, ["Always Off"])

        XCTAssertTrue(session.setClaudeRemoteControl(true))
        ticked = try tickedTitles(for: session)
        XCTAssertEqual(ticked, ["Always On"])
    }

    func testCodexSessionsAreNotOfferedTheItem() throws {
        let entries = ProjectSidebarViewController().sessionActionEntries(
            for: AgentSession(kind: .codex, title: "Codex")
        )

        // The item lives in the Session Options fold, so that is where its absence means
        // anything — a top-level check would pass whatever the fold held.
        let options = try XCTUnwrap(
            entries.compactMap(\.item)
                .first { $0.title == SessionActionMenuDefaults.sessionOptionsTitle }?
                .submenu
        )
        XCTAssertNil(options.compactMap(\.item).first { $0.title == "Claude Remote Control" })
    }

    // MARK: - Settings Page

    /// The page is built rather than assumed: the control reaches the user through a row on
    /// General, and a setting whose pop-up never made it onto the page is indistinguishable
    /// from one nobody set.
    func testTheGeneralPageOffersEveryStateAndShowsTheCurrentOne() throws {
        AppSettings.shared.claudeRemoteControl = .disabled

        let controller = GeneralPreferencesViewController()
        let host = laidOut(controller.view)
        let popUp = try XCTUnwrap(
            remoteControlPopUp(in: host),
            "the Claude Remote Control row is not on the General page"
        )

        XCTAssertEqual(
            (0..<popUp.numberOfItems).compactMap { popUp.item(at: $0)?.title },
            ClaudeRemoteControl.allCases.map(\.settingsTitle)
        )
        XCTAssertEqual(popUp.selectedItem?.representedValue as? ClaudeRemoteControl, .disabled)
        XCTAssertTrue(
            labels(in: host).contains("Report Claude turn and subagent activity"),
            "the Claude lifecycle opt-out is not on the General page"
        )
        XCTAssertGreaterThan(controller.view.frame.height, 200, "the page collapsed")

        write(host, named: "general-claude-remote-control")
    }

    // MARK: - Helpers

    private var submenuTitles: (inherit: String, on: String, off: String) {
        (AppSettings.shared.claudeRemoteControl.inheritedMenuTitle, "Always On", "Always Off")
    }

    private func remoteControlSubmenu(for session: AgentSession) throws -> [ThemedMenuEntry] {
        let entries = ProjectSidebarViewController().sessionActionEntries(for: session)

        let options = try XCTUnwrap(
            entries.compactMap(\.item)
                .first { $0.title == SessionActionMenuDefaults.sessionOptionsTitle }?
                .submenu,
            "the session menu has no Session Options fold"
        )
        let item = try XCTUnwrap(
            options.compactMap(\.item).first { $0.title == "Claude Remote Control" },
            "Session Options has no Claude Remote Control item"
        )
        return try XCTUnwrap(item.submenu, "the item has no submenu")
    }

    private func tickedTitles(for session: AgentSession) throws -> [String] {
        try remoteControlSubmenu(for: session)
            .compactMap(\.item)
            .filter(\.isSelected)
            .map(\.title)
    }

    private func settingsJSON(at path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// The page's own pop-up, found by the states it offers rather than by position — the row
    /// can move without this test caring, and the agent pop-up above it cannot be mistaken
    /// for it.
    private func remoteControlPopUp(in view: NSView) -> ThemedPopUp? {
        if let popUp = view as? ThemedPopUp,
           popUp.item(at: 0)?.title == ClaudeRemoteControl.followClaude.settingsTitle {
            return popUp
        }
        for subview in view.subviews {
            if let found = remoteControlPopUp(in: subview) { return found }
        }
        return nil
    }

    private func labels(in view: NSView) -> [String] {
        var result = (view as? NSTextField).map { [$0.stringValue] } ?? []
        for subview in view.subviews {
            result.append(contentsOf: labels(in: subview))
        }
        return result
    }

    private func laidOut(_ view: NSView, width: CGFloat = SettingsUIDefaults.pageWidth) -> NSView {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: Render.height))
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)

        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor)
        ])

        host.layoutSubtreeIfNeeded()
        return host
    }

    /// Writes the page out the way the other settings renders do, so the wording and the row's
    /// proportions can be reviewed in a picture rather than in assertions about constants.
    private func write(_ host: NSView, named name: String) {
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }

        // The page paints no ground of its own; without one every label draws onto transparency.
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        host.cacheDisplay(in: host.bounds, to: rep)

        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? FileManager.default.createDirectory(
            at: Render.directory,
            withIntermediateDirectories: true
        )
        try? data.write(to: Render.directory.appendingPathComponent("\(name).png"))
    }

    private enum Render {
        static let height: CGFloat = 1400

        static var directory: URL {
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"],
               !override.isEmpty {
                return URL(fileURLWithPath: override)
            }
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
        }
    }
}

import XCTest
@testable import Skalman

/// What a launch says about how much the session may do before it asks.
///
/// The mode is not a Skalman concept: each CLI has its own, and the whole value of the feature
/// is that the flags come out *right* for the agent being launched. So these assert against the
/// tokenized launch line — the words the CLI actually receives — rather than against the
/// resolver, which could agree with itself while emitting a flag neither CLI takes.
@MainActor
final class AgentPermissionModeTests: XCTestCase {

    private var defaultMode: AgentPermissionMode?

    override func setUp() {
        super.setUp()
        // The app-wide default is one of the inputs under test, and it is real user state.
        defaultMode = AppSettings.shared.defaultPermissionMode
        AppSettings.shared.defaultPermissionMode = nil
    }

    override func tearDown() {
        AppSettings.shared.defaultPermissionMode = defaultMode
        super.tearDown()
    }

    // MARK: - Claude

    /// Every mode reaches Claude as its own `--permission-mode` value.
    ///
    /// The expected strings are written out rather than derived from the enum: `claudeFlagValue`
    /// returning the wrong thing is exactly the bug this exists to catch, and a test that asks
    /// the same property is a second copy of it. These six are the values `claude --help`
    /// documents — note `manual`, which the CLI calls `default` internally.
    func testEachModeReachesClaudeAsItsOwnFlagValue() throws {
        let expected: [AgentPermissionMode: String] = [
            .manual: "manual",
            .plan: "plan",
            .acceptEdits: "acceptEdits",
            .auto: "auto",
            .dontAsk: "dontAsk",
            .bypassPermissions: "bypassPermissions"
        ]

        for (mode, value) in expected {
            let words = try Self.launchWords(kind: .claude, mode: mode)
            let flag = try XCTUnwrap(
                words.firstIndex(of: "--permission-mode"),
                "\(mode) launched without stating a mode"
            )
            XCTAssertEqual(words[flag + 1], value)
        }
    }

    /// The native surface states the mode too. A headless session cannot be Shift+Tabbed into
    /// one, so the launch is the only chance it gets.
    func testTheNativeClaudeTransportStatesTheModeAsWell() throws {
        let session = Self.session(kind: .claude, mode: .plan)
        let words = try Self.tokenizing(
            XCTUnwrap(AgentLauncher.streamPlan(for: session, in: Self.project).arguments.last)
        )

        XCTAssertEqual(Self.value(after: "--permission-mode", in: words), "plan")
    }

    // MARK: - Codex

    /// Codex has no mode flag, so each mode becomes an approval policy *and* a sandbox — and the
    /// six land on six distinct pairs. That distinctness is the claim worth testing: a mapping
    /// where two modes collapse would give the menu two items that do the same thing.
    func testEachModeReachesCodexAsADistinctApprovalAndSandboxPair() throws {
        var seen: Set<String> = []

        for mode in AgentPermissionMode.allCases {
            let words = try Self.launchWords(kind: .codex, mode: mode)

            let approval = try XCTUnwrap(Self.value(after: "--ask-for-approval", in: words))
            let sandbox = try XCTUnwrap(Self.value(after: "--sandbox", in: words))

            XCTAssertTrue(
                ["untrusted", "on-request", "never"].contains(approval),
                "\(mode) asked Codex for an approval policy it does not have: \(approval)"
            )
            XCTAssertTrue(
                ["read-only", "workspace-write", "danger-full-access"].contains(sandbox),
                "\(mode) asked Codex for a sandbox it does not have: \(sandbox)"
            )
            XCTAssertTrue(
                seen.insert("\(approval)/\(sandbox)").inserted,
                "\(mode) produces the same Codex launch as another mode: \(approval)/\(sandbox)"
            )
        }
    }

    /// Manual and Accept edits share an approval policy and differ only in the sandbox, which is
    /// the half of the mapping that carries the meaning: read-only has to ask before changing
    /// anything, workspace-write may edit in place.
    func testManualAndAcceptEditsDifferOnlyInWhatCodexMayWrite() throws {
        let manual = try Self.launchWords(kind: .codex, mode: .manual)
        let accept = try Self.launchWords(kind: .codex, mode: .acceptEdits)

        XCTAssertEqual(
            Self.value(after: "--ask-for-approval", in: manual),
            Self.value(after: "--ask-for-approval", in: accept)
        )
        XCTAssertEqual(Self.value(after: "--sandbox", in: manual), "read-only")
        XCTAssertEqual(Self.value(after: "--sandbox", in: accept), "workspace-write")
    }

    /// The native Codex transport fixes `--sandbox workspace-write` when no mode is stated,
    /// because a natively rendered session that inherited a read-only `config.toml` would stop
    /// being able to edit and would say so only through failing tools. A stated mode *replaces*
    /// that value — it must not arrive as a second `--sandbox`, where the last one silently wins.
    func testTheNativeCodexTransportCarriesExactlyOneSandbox() throws {
        for mode in [nil] + AgentPermissionMode.allCases.map(Optional.init) {
            let session = Self.session(kind: .codex, mode: mode)
            let words = try Self.tokenizing(
                XCTUnwrap(AgentLauncher.streamPlan(for: session, in: Self.project).arguments.last)
            )

            XCTAssertEqual(
                words.filter { $0 == "--sandbox" }.count,
                1,
                "\(String(describing: mode)) left the native launch with two sandboxes"
            )
            XCTAssertEqual(
                Self.value(after: "--sandbox", in: words),
                mode?.codexSandboxMode ?? "workspace-write"
            )
        }
    }

    // MARK: - Resolution

    /// No choice anywhere means **no flag** — not a mode Skalman picked. Naming one would
    /// override a `permissions.defaultMode` or `config.toml` the user set themselves, which is
    /// the whole reason the value is optional rather than defaulted.
    func testNoChoiceAnywhereStatesNothing() throws {
        for kind in AgentKind.allCases {
            let words = try Self.launchWords(kind: kind, mode: nil)

            XCTAssertFalse(words.contains("--permission-mode"), "\(kind) invented a Claude mode")
            XCTAssertFalse(words.contains("--ask-for-approval"), "\(kind) invented an approval policy")
            XCTAssertFalse(words.contains("--sandbox"), "\(kind) invented a sandbox")
        }
    }

    /// The app-wide default applies to a session that has not chosen.
    func testTheAppDefaultAppliesToASessionThatHasNotChosen() throws {
        AppSettings.shared.defaultPermissionMode = .acceptEdits

        let words = try Self.launchWords(kind: .claude, mode: nil)

        XCTAssertEqual(Self.value(after: "--permission-mode", in: words), "acceptEdits")
    }

    /// And the session's own choice beats it, including when the two disagree about safety —
    /// a conversation deliberately left in Plan is not dragged along by a permissive default.
    func testASessionsOwnChoiceBeatsTheAppDefault() throws {
        AppSettings.shared.defaultPermissionMode = .bypassPermissions

        let words = try Self.launchWords(kind: .claude, mode: .plan)

        XCTAssertEqual(Self.value(after: "--permission-mode", in: words), "plan")
    }

    // MARK: - Persistence

    /// The mode survives a round-trip, and a record written before this existed decodes to nil
    /// rather than to a mode nobody chose.
    func testTheModeSurvivesARoundTripAndOlderRecordsDecodeToNil() throws {
        var session = AgentSession(kind: .claude, title: "t")
        session.permissionMode = .dontAsk

        let encoded = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(AgentSession.self, from: encoded)
        XCTAssertEqual(decoded.permissionMode, .dontAsk)

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "permissionMode")
        let older = try JSONDecoder().decode(
            AgentSession.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertNil(older.permissionMode)
    }

    /// Nil is a value the store can go back to, not merely the state before a first choice —
    /// otherwise "Use Agent's Setting" would be a one-way door once any mode had been picked.
    func testClearingASessionsModeReturnsItToInheriting() throws {
        let store = ProjectStore.shared
        // A path of its own: `addProject` returns the existing project for a folder it already
        // knows, so a shared temp directory would hand this test a sibling's project and then
        // delete it on the way out.
        let project = store.addProject(
            folderURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("skalman-permission-mode-\(UUID().uuidString)")
        )
        let session = try XCTUnwrap(store.addSession(to: project.id, kind: .claude))
        defer { store.removeProject(id: project.id) }

        store.setPermissionMode(.auto, for: session.id)
        XCTAssertEqual(store.session(withID: session.id)?.permissionMode, .auto)

        store.setPermissionMode(nil, for: session.id)
        XCTAssertNil(store.session(withID: session.id)?.permissionMode)
    }

    // MARK: - The broker

    /// Skalman's own permission sheet honours the mode, because the CLI does not honour it for
    /// us: measured against 2.1.220, `PreToolUse` fires under `bypassPermissions` and `dontAsk`
    /// exactly as it does under `manual`. A native session in Bypass that still got stopped by
    /// Skalman's sheet would be the app contradicting the mode chosen inside it.
    func testBypassAllowsAndDontAskDeniesWithoutAsking() {
        for tool in [ToolIdentity.bash, .write, .edit] {
            switch PermissionPolicy.standingDecision(for: tool, in: .bypassPermissions) {
            case .allow: break
            default: XCTFail("Bypass Permissions still asked about \(tool)")
            }

            switch PermissionPolicy.standingDecision(for: tool, in: .dontAsk) {
            case .deny: break
            default: XCTFail("Don't Ask did not refuse \(tool)")
            }
        }
    }

    /// Accept Edits is about *edits*. A command is not an edit, and that distinction is the
    /// whole difference between this mode and the ones either side of it.
    func testAcceptEditsAllowsFileChangesAndStillAsksAboutCommands() {
        for tool in [ToolIdentity.write, .edit, .multiEdit, .notebookEdit] {
            switch PermissionPolicy.standingDecision(for: tool, in: .acceptEdits) {
            case .allow: break
            default: XCTFail("Accept Edits asked about \(tool)")
            }
        }

        XCTAssertNil(
            PermissionPolicy.standingDecision(for: .bash, in: .acceptEdits),
            "Accept Edits waved a command through as though it were an edit"
        )
    }

    /// The modes that promise nothing about the sheet still raise it. Being wrong here should
    /// cost an extra question, never an unasked-for action.
    func testTheRemainingModesStillAsk() {
        for mode in [AgentPermissionMode.manual, .plan, .auto] {
            XCTAssertNil(
                PermissionPolicy.standingDecision(for: .bash, in: mode),
                "\(mode) stopped asking"
            )
        }
    }

    // MARK: - Helpers

    private static let project = Project(
        name: "p",
        folderURL: URL(fileURLWithPath: "/tmp/p")
    )

    private static func session(kind: AgentKind, mode: AgentPermissionMode?) -> AgentSession {
        var session = AgentSession(kind: kind, title: "t")
        session.permissionMode = mode
        return session
    }

    /// The words a terminal launch hands the CLI.
    private static func launchWords(
        kind: AgentKind,
        mode: AgentPermissionMode?
    ) throws -> [String] {
        try tokenizing(
            XCTUnwrap(
                AgentLauncher.plan(for: session(kind: kind, mode: mode), in: project).arguments.last
            )
        )
    }

    private static func value(after flag: String, in words: [String]) -> String? {
        guard let index = words.firstIndex(of: flag), index + 1 < words.count else { return nil }
        return words[index + 1]
    }

    /// Splits a launch line into the words a shell would pass on, without running it. The same
    /// approach as `AgentLaunchQuotingTests`: the fixed `cd … && exec ` prefix is dropped and the
    /// rest goes through `set --`, which is the shell's own tokenizer.
    private static func tokenizing(_ launchLine: String) throws -> [String] {
        let marker = "&& \(ShellCommand(word: "exec").source) "
        let prefix = try XCTUnwrap(
            launchLine.range(of: marker),
            "the launch line stopped being 'cd' … && 'exec' …"
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
}

import XCTest
@testable import Threading

/// What a chat created *for* somebody comes up as.
///
/// The rule is shared by the development build's report chat and by a report sent to this Mac
/// from a paired phone, so it is tested here on its own rather than twice through its callers.
/// `DeveloperReportChatTests` keeps asserting the parts that are that route's own decisions —
/// which project, and never a workspace or a branch.
final class InheritedLaunchConfigurationTests: XCTestCase {

    // MARK: - Which Chat Is Copied

    func testEveryChoiceComesFromTheMostRecentlyUsedChat() {
        var older = AgentSession(kind: .codex, title: "Older")
        older.lastActiveAt = Date(timeIntervalSince1970: 1_000)

        var newer = AgentSession(
            configuration: .claude(
                remoteControl: nil,
                reasoningEffort: "high",
                origin: .original
            ),
            title: "Newer",
            accountHandle: .named("work"),
            model: "claude-opus-5",
            usesNativeUI: true
        )
        newer.lastActiveAt = Date(timeIntervalSince1970: 2_000)
        newer.permissionMode = .acceptEdits
        newer.fastMode = true

        let inherited = InheritedLaunchConfiguration.resolve(
            sessions: [older, newer],
            defaultKind: .codex
        )

        XCTAssertEqual(inherited.kind, .claude)
        XCTAssertEqual(inherited.accountHandle, .named("work"))
        XCTAssertEqual(inherited.model, "claude-opus-5")
        XCTAssertEqual(inherited.permissionMode, .acceptEdits)
        XCTAssertTrue(inherited.usesNativeUI)
        // Neither of these is carried by the report chat's own tests, and both reach the phone
        // over the wire, where the Mac refuses a level the model does not offer.
        XCTAssertEqual(inherited.reasoningEffort, "high")
        XCTAssertEqual(inherited.fastMode, true)
    }

    /// `lastTurnAt` is when the chat was last *used*; `lastActiveAt` is when the runtime last
    /// touched it, which a background relaunch does to every session at once.
    func testTheMostRecentChatIsTheOneLastUsedRatherThanLastTouched() {
        var relaunched = AgentSession(kind: .codex, title: "Relaunched this morning")
        relaunched.lastActiveAt = Date(timeIntervalSince1970: 9_000)
        relaunched.lastTurnAt = Date(timeIntervalSince1970: 1_000)

        var worked = AgentSession(kind: .claude, title: "Worked in last night")
        worked.lastActiveAt = Date(timeIntervalSince1970: 8_000)
        worked.lastTurnAt = Date(timeIntervalSince1970: 5_000)

        XCTAssertEqual(
            InheritedLaunchConfiguration.resolve(
                sessions: [relaunched, worked],
                defaultKind: .codex
            ).kind,
            .claude,
            "the new chat copied a session nobody had used"
        )
    }

    func testAnArchivedChatIsNotCopied() {
        var archived = AgentSession(kind: .claude, title: "Put away")
        archived.lastActiveAt = Date(timeIntervalSince1970: 9_000)
        archived.isArchived = true

        var live = AgentSession(kind: .codex, title: "Still here")
        live.lastActiveAt = Date(timeIntervalSince1970: 1_000)

        XCTAssertEqual(
            InheritedLaunchConfiguration.resolve(
                sessions: [archived, live],
                defaultKind: .claude
            ).kind,
            .codex,
            "a deliberately archived chat decided the new one"
        )
    }

    // MARK: - A Project With Nothing To Copy

    func testAnEmptyProjectFallsBackToTheDefaultAgentOnItsOwnSurface() {
        let inherited = InheritedLaunchConfiguration.resolve(
            sessions: [],
            defaultKind: .claude
        )

        XCTAssertEqual(inherited.kind, .claude)
        XCTAssertEqual(inherited.accountHandle, .standard)
        XCTAssertNil(inherited.model)
        XCTAssertNil(inherited.reasoningEffort)
        XCTAssertNil(inherited.fastMode)
        XCTAssertNil(inherited.permissionMode)
        XCTAssertEqual(
            inherited.usesNativeUI,
            AgentKind.claude.supportsNativeUI,
            "a runtime with no terminal surface would have been asked for one"
        )
    }

    // MARK: - The Clamps

    /// `AgentSessionConfiguration` refuses a login for a runtime that has none, and the refusal
    /// arrives as a nil session two steps later. The clamp belongs where the value is chosen.
    func testALoginIsNotCarriedToARuntimeThatHasNone() throws {
        try XCTSkipIf(AgentKind.grok.supportsAccounts, "Grok has grown account routing")

        var session = AgentSession(kind: .grok, title: "Grok")
        session.accountHandle = .named("work")

        XCTAssertEqual(
            InheritedLaunchConfiguration.resolve(sessions: [session], defaultKind: .claude)
                .accountHandle,
            .standard,
            "a login was carried to a runtime with none"
        )
    }

    func testAPermissionModeIsNotCarriedToARuntimeThatHasNone() throws {
        let kind = try XCTUnwrap(
            AgentKind.allCases.first { !$0.supportsPermissionModes },
            "every runtime now supports permission modes"
        )

        var session = AgentSession(kind: kind, title: "No modes here")
        session.permissionMode = .plan

        XCTAssertNil(
            InheritedLaunchConfiguration.resolve(sessions: [session], defaultKind: kind)
                .permissionMode,
            "a mode was carried to a runtime that cannot be launched with one"
        )
    }
}

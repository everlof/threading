import XCTest
@testable import Threading

/// The choices a manager's spawned child launches with when its plan leaves them out.
///
/// The regression these pin: a manager on one runtime spawning a child on another handed the
/// child its own model, effort, fast mode and login, so a Codex child launched with
/// `--model` set to a Claude model id.
@MainActor
final class SpawnChildChoicesTests: XCTestCase {

    // MARK: - Same runtime

    func testChildOnTheManagersRuntimeInheritsItsChoices() throws {
        let choices = try resolve(nil)

        XCTAssertEqual(choices, SpawnChildChoices(
            kind: .codex,
            account: .named("work"),
            model: "gpt-5.5-codex",
            reasoningEffort: "xhigh",
            fastMode: true,
            usesNativeUI: true,
            permissionMode: .acceptEdits
        ))
    }

    func testTheSameRuntimeNeverAsksForAnotherRuntimesDefaultLogin() throws {
        _ = try resolve(#"{"kind":"codex"}"#) { kind in
            XCTFail("Asked for \(kind)'s default login although the child shares the manager's.")
            return "unused"
        }
    }

    // MARK: - Another runtime

    func testChildOnAnotherRuntimeStartsOnThatRuntimesDefaults() throws {
        var asked: [AgentKind] = []
        let choices = try resolve(#"{"kind":"claude"}"#) { kind in
            asked.append(kind)
            return "claude-team"
        }

        XCTAssertEqual(asked, [.claude])
        XCTAssertEqual(choices, SpawnChildChoices(
            kind: .claude,
            account: .named("claude-team"),
            model: nil,
            reasoningEffort: nil,
            fastMode: nil,
            usesNativeUI: true,
            permissionMode: .acceptEdits
        ))
    }

    func testChoicesThePlanNamesWinOnAnotherRuntime() throws {
        let choices = try resolve(
            #"{"kind":"claude","account":"best","model":"opus","reasoning_effort":"high","fast_mode":false,"permission_mode":"plan"}"#
        )

        XCTAssertEqual(choices.account, .named("best"))
        XCTAssertEqual(choices.model, "opus")
        XCTAssertEqual(choices.reasoningEffort, "high")
        XCTAssertEqual(choices.fastMode, false)
        XCTAssertEqual(choices.permissionMode, .plan)
    }

    // MARK: - Runtimes without logins or surfaces

    func testRuntimeWithoutLoginsStartsOnItsStandardOne() throws {
        let choices = try resolve(#"{"kind":"grok"}"#)

        XCTAssertEqual(choices.account, .standard)
        XCTAssertTrue(choices.usesNativeUI)
        XCTAssertEqual(choices.permissionMode, .acceptEdits)
    }

    func testNamingALoginForARuntimeWithoutLoginsIsRefused() {
        XCTAssertEqual(
            refusal(#"{"kind":"grok","account":"work"}"#),
            "Grok has no separate logins in Threading; omit account."
        )
    }

    func testRuntimeWithoutANativeChatDefaultsToItsTerminal() throws {
        let choices = try resolve(#"{"kind":"opencode"}"#)

        XCTAssertFalse(choices.usesNativeUI)
        XCTAssertEqual(choices.account, .standard)
        XCTAssertNil(choices.permissionMode, "OpenCode has no permission modes to carry.")
    }

    func testAskingForASurfaceTheRuntimeLacksIsRefused() {
        XCTAssertNotNil(refusal(#"{"kind":"opencode","uses_native_ui":true}"#))
        XCTAssertNotNil(refusal(#"{"kind":"cursor","uses_native_ui":false}"#))
    }

    // MARK: - Private Methods

    private func manager() -> AgentSession {
        var session = AgentSession(
            configuration: .codex(reasoningEffort: "xhigh"),
            title: "Manager",
            accountHandle: AccountHandle(storedName: "work"),
            model: "gpt-5.5-codex",
            usesNativeUI: true
        )
        session.fastMode = true
        session.permissionMode = .acceptEdits
        return session
    }

    private func plan(_ json: String?) throws -> SpawnSessionPlanArguments? {
        try json.map { try JSONDecoder().decode(SpawnSessionPlanArguments.self, from: Data($0.utf8)) }
    }

    private func resolve(
        _ json: String?,
        defaultAccountName: (AgentKind) -> String = { _ in "default-login" }
    ) throws -> SpawnChildChoices {
        try SpawnChildChoices.resolve(
            plan: plan(json),
            manager: manager(),
            defaultAccountName: defaultAccountName
        ).get()
    }

    private func refusal(_ json: String) -> String? {
        guard let plan = try? plan(json) else { return "undecodable" }
        guard case .failure(let failure) = SpawnChildChoices.resolve(
            plan: plan,
            manager: manager(),
            defaultAccountName: { _ in "default-login" }
        ) else { return nil }
        return failure.words
    }
}

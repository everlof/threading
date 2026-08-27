import XCTest
@testable import Threading

/// The defaults that decide whether an agent's tool call runs without being asked about.
///
/// `PermissionBroker.decide` is the whole of that decision, and its safety is in what it does
/// when it is *unsure*: an unrecognised tool prompts, a shell command it cannot read prompts,
/// and a request arriving with no window to ask in is **denied**. Those are the answers that
/// stay right as tools are added — and none of them was pinned, so a refactor could invert any
/// one of them and every existing test would still pass.
@MainActor
final class PermissionBrokerTests: XCTestCase {

    private let session = SessionID()

    override func tearDown() {
        PermissionBroker.present = nil
        PermissionBroker.discard(sessionID: session)
        super.tearDown()
    }

    // MARK: - Helpers

    private func decision(
        tool: String,
        input: [String: JSONValue] = [:],
        session: SessionID? = nil
    ) -> PermissionDecision {
        var result: PermissionDecision?
        PermissionBroker.decide(
            PermissionRequest(
                sessionID: session ?? self.session,
                toolName: tool,
                input: input
            )
        ) { result = $0 }

        guard let result else {
            XCTFail("the broker never answered for \(tool)")
            return .deny(reason: "no answer")
        }
        return result
    }

    private func isAllowed(_ decision: PermissionDecision) -> Bool {
        if case .allow = decision { return true }
        return false
    }

    /// Stands in for the approval card. A request that reaches it is one the *user* is being
    /// asked about, which is the outcome these tests care about — not what they then choose.
    private func recordingPresenter(_ asked: @escaping (PermissionRequest) -> Void) {
        PermissionBroker.present = { request, completion in
            asked(request)
            completion(.deny(reason: "test"))
        }
    }

    // MARK: - The default when nothing can ask

    /// No window, no decision. Denying is the only answer that cannot be wrong: the alternative
    /// is a tool call running because the app had nowhere to put the question.
    func testARequestWithNoWindowIsDenied() {
        PermissionBroker.present = nil

        let answer = decision(tool: "Write", input: ["file_path": "/tmp/x"])

        XCTAssertFalse(isAllowed(answer), "a write ran with nobody to approve it")
    }

    /// Read-only tools are still allowed with no window — they never needed the question.
    func testAReadOnlyToolStillAnswersWithNoWindow() {
        PermissionBroker.present = nil
        XCTAssertTrue(isAllowed(decision(tool: "Read", input: ["file_path": "/tmp/x"])))
    }

    // MARK: - What prompts

    /// A tool nobody has classified is consequential until proven otherwise. This is the rule
    /// that keeps the allowlist safe as CLIs add tools: a name this app has never seen reaches
    /// the user rather than the filesystem.
    func testAnUnknownToolIsPutToTheUser() {
        var asked: [String] = []
        recordingPresenter { asked.append($0.toolName) }

        _ = decision(tool: "SomeToolInventedNextYear")

        XCTAssertEqual(asked, ["SomeToolInventedNextYear"])
    }

    /// The auto-allow set, stated. `PermissionPolicy`'s own `switch` is exhaustive, so a new
    /// identity cannot be added without choosing a side — this pins which side each *existing*
    /// one is on, which is the thing a refactor can quietly move.
    func testTheAutoAllowSetIsTheReadOnlyHandful() {
        let allowed: [ToolIdentity] = [
            .read, .glob, .grep, .notebookRead,
            .todoWrite, .todoRead, .taskCreate, .taskUpdate, .taskList, .taskGet,
            .task, .toolSearch
        ]
        let prompts: [ToolIdentity] = [
            .bash, .write, .edit, .multiEdit, .notebookEdit, .webFetch, .webSearch, .plan,
            .unknown("anything")
        ]

        for identity in allowed {
            XCTAssertTrue(
                PermissionPolicy.isAutoAllowed(identity),
                "\(identity) stopped being allowed and now interrupts for a read"
            )
        }
        for identity in prompts {
            XCTAssertFalse(
                PermissionPolicy.isAutoAllowed(identity),
                "\(identity) became allowed without being asked about"
            )
        }
    }

    /// Only Threading's closed built-in catalogue is pre-approved. A server name may contain
    /// `__`, so neither a server-name prefix nor a parsed first segment identifies this server;
    /// the complete qualified tool identity has to be one the built-in registry advertised.
    func testOnlyThisAppsMCPToolsArePreApproved() {
        for tool in MCPBuiltInTool.allCases {
            let qualified = MCPDefaults.allowedToolName(tool.rawValue)
            XCTAssertTrue(
                PermissionPolicy.isAutoAllowed(ToolIdentity(qualified)),
                "\(qualified) was omitted from the built-in preapproval set"
            )
        }

        let lookalikes = [
            "mcp__someone_else__delete_everything",
            "mcp__\(MCPDefaults.serverName)_evil__delete_everything",
            "mcp__\(MCPDefaults.serverName)__x__delete_everything",
            "mcp__\(MCPDefaults.serverName)__invented_future_tool",
        ]
        for name in lookalikes {
            XCTAssertFalse(
                PermissionPolicy.isAutoAllowed(ToolIdentity(name)),
                "unadvertised MCP identity \(name) was pre-approved"
            )
        }
    }

    /// Claude receives the same exact identities instead of a server wildcard. Keeping these in
    /// one comma-separated argument is Claude's documented multi-tool form; contribution IDs are
    /// validated separately and cannot introduce a comma or whitespace into a qualified name.
    func testClaudeLaunchPreapprovalListsExactToolIdentities() {
        let argument = MCPDefaults.allowedToolsArgument(["display_image", "video_frames"])

        XCTAssertEqual(
            argument,
            "mcp__threading__display_image,mcp__threading__video_frames"
        )
        XCTAssertFalse(argument.contains("*"))
    }

    /// A shell call is judged by what it runs, and anything the policy cannot vouch for prompts.
    func testAShellCallIsJudgedByItsCommand() {
        var asked: [String] = []
        recordingPresenter { asked.append($0.summary) }

        XCTAssertTrue(
            isAllowed(decision(tool: "Bash", input: ["command": "git status"])),
            "a read-only command was not recognised"
        )
        XCTAssertFalse(
            isAllowed(decision(tool: "Bash", input: ["command": "rm -rf /"])),
            "a destructive command was allowed without asking"
        )
        XCTAssertFalse(
            isAllowed(decision(tool: "Bash", input: [:])),
            "a shell call with no command to read was allowed"
        )

        XCTAssertEqual(asked, ["rm -rf /", ""])
    }

    // MARK: - Standing approvals

    /// "Always allow" is a decision about *this conversation*. Leaking it into another session
    /// would let a tool the user approved once run unasked in a conversation they never saw.
    func testAStandingApprovalDoesNotCrossSessions() {
        let other = SessionID()
        defer { PermissionBroker.discard(sessionID: other) }

        PermissionBroker.allowAlways(toolName: "Write", for: session)
        PermissionBroker.present = nil

        XCTAssertTrue(isAllowed(decision(tool: "Write", session: session)))
        XCTAssertFalse(
            isAllowed(decision(tool: "Write", session: other)),
            "one session's standing approval answered for another"
        )
    }

    /// A request can wait behind another card while the first decision changes session policy.
    /// The queue uses this pure re-check rather than presenting its stale earlier classification.
    func testAutomaticDecisionSeesAStandingApprovalAddedWhileQueued() {
        let request = PermissionRequest(
            sessionID: session,
            toolName: "Write",
            input: ["file_path": "/tmp/x", "content": "done"]
        )

        XCTAssertNil(PermissionBroker.automaticDecision(for: request))
        PermissionBroker.allowAlways(toolName: "Write", for: session)

        guard case .allow = PermissionBroker.automaticDecision(for: request) else {
            return XCTFail("the queued request ignored the new session approval")
        }
    }

    /// A resumed conversation starts asking again: the approvals belonged to the run that is
    /// over, and a session id outlives the process that earned them.
    func testDiscardingASessionForgetsItsApprovals() {
        PermissionBroker.allowAlways(toolName: "Write", for: session)
        PermissionBroker.discard(sessionID: session)
        PermissionBroker.present = nil

        XCTAssertFalse(isAllowed(decision(tool: "Write")))
    }
}

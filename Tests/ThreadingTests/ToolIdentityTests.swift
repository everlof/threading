import XCTest
@testable import Threading

/// Covers the provider spellings `ToolIdentity` unifies, and — more importantly — the ones it
/// deliberately does not.
///
/// The Codex names here are not invented: they are the tools actually called across 1008
/// rollouts on the machine this was built for, which is how the long tail was found.
final class ToolIdentityTests: XCTestCase {

    // MARK: - Codex Spellings

    func testCodexShellToolsAreBash() {
        for name in ["exec", "exec_command", "shell_command", "shell", "local_shell"] {
            XCTAssertEqual(ToolIdentity(name), .bash, "\(name) should read as a shell call")
        }
    }

    /// Writing into a running process is part of the same shell interaction, and no less
    /// consequential than the command that opened it.
    func testWritingToStdinIsBash() {
        XCTAssertEqual(ToolIdentity("write_stdin"), .bash)
    }

    /// A patch carries old *and* new text, so it is an edit rather than a whole-file write —
    /// which is what lets `CodexPatch` feed the same `DiffView` an `Edit` does.
    func testApplyPatchIsAnEdit() {
        XCTAssertEqual(ToolIdentity("apply_patch"), .edit)
    }

    func testCodexReadAndPlanTools() {
        XCTAssertEqual(ToolIdentity("view_image"), .read)
        XCTAssertEqual(ToolIdentity("update_plan"), .plan)
        XCTAssertEqual(ToolIdentity("web_search"), .webSearch)
    }

    // MARK: - What Stays Unknown

    /// Mapping a tool onto an identity hands it that identity's *permissions*, so anything with
    /// no behavioural twin here must stay unknown and keep prompting. Every name below is one
    /// Codex really calls.
    func testCodexSpecificToolsStayUnknown() {
        let names = [
            "spawn_agent", "wait_agent", "list_agents", "close_agent", "interrupt_agent",
            "followup_task", "send_message",
            "create_goal", "update_goal", "get_goal",
            "js", "screenshot", "snapshot_ui", "launch_app_sim",
            "session_set_defaults", "session_show_defaults", "discover_projs", "wait"
        ]

        for name in names {
            XCTAssertEqual(
                ToolIdentity(name), .unknown(name),
                "\(name) has no behavioural twin and must keep prompting"
            )
        }
    }

    /// None of the newly mapped Codex tools may become auto-allowed by accident. Only the
    /// genuinely read-only one may skip the prompt.
    func testOnlyTheReadOnlyCodexToolIsAutoAllowed() {
        XCTAssertTrue(PermissionPolicy.isAutoAllowed(ToolIdentity("view_image")))

        for name in ["exec", "exec_command", "shell_command", "write_stdin",
                     "apply_patch", "update_plan", "js", "spawn_agent"] {
            XCTAssertFalse(
                PermissionPolicy.isAutoAllowed(ToolIdentity(name)),
                "\(name) must not be auto-allowed"
            )
        }
    }

    // MARK: - Subjects Survive The Mapping

    private func summary(toolName: String, input: [String: JSONValue]) -> String {
        PermissionRequest(sessionID: SessionID(), toolName: toolName, input: input).summary
    }

    /// The regression this mapping caused, and the reason every rule now falls back.
    ///
    /// Recognising a tool must never make a row say *less* than not recognising it did. As
    /// `.unknown`, a Codex `exec` found its subject through the generic search, which knows
    /// `cmd` as well as `command`; the moment it became `.bash` it read only `command` and
    /// rendered as a bare `$ Bash` with nothing beside it.
    func testCodexShellCallKeepsItsSubjectUnderEitherArgumentName() {
        XCTAssertEqual(summary(toolName: "exec", input: ["command": "ls -la"]), "ls -la")
        XCTAssertEqual(summary(toolName: "exec", input: ["cmd": "ls -la"]), "ls -la")
        XCTAssertEqual(summary(toolName: "exec_command", input: ["cmd": "git status"]), "git status")
    }

    /// Same rule for the file-shaped tools: `apply_patch` is an `.edit`, but it does not carry
    /// a `file_path` the way Claude's `Edit` does.
    func testMappedFileToolsFallBackToADescriptiveArgument() {
        let summary = summary(
            toolName: "apply_patch",
            input: ["command": "*** Begin Patch\n*** Add File: a.txt\n+hi\n*** End Patch"]
        )
        XCTAssertFalse(summary.isEmpty, "an apply_patch row must say something")
    }

    /// Recognising a tool must not lose a subject the generic path would have found — this is
    /// the general form of the bug above, across every newly mapped name.
    func testNoMappedToolRendersAnonymouslyWhenItCarriesASubject() {
        for name in ["exec", "exec_command", "shell_command", "write_stdin",
                     "apply_patch", "view_image", "web_search"] {
            XCTAssertFalse(
                summary(toolName: name, input: ["cmd": "something descriptive"]).isEmpty,
                "\(name) rendered with no subject"
            )
        }
    }

    // MARK: - Claude Spellings

    func testClaudeSpellingsAreUnchanged() {
        XCTAssertEqual(ToolIdentity("Bash"), .bash)
        XCTAssertEqual(ToolIdentity("Read"), .read)
        XCTAssertEqual(ToolIdentity("Edit"), .edit)
        XCTAssertEqual(ToolIdentity("Grep"), .grep)
    }

    func testClaudeTaskBookkeepingHasExplicitSafeIdentities() {
        XCTAssertEqual(ToolIdentity("TaskCreate"), .taskCreate)
        XCTAssertEqual(ToolIdentity("TaskUpdate"), .taskUpdate)
        XCTAssertEqual(ToolIdentity("TaskList"), .taskList)
        XCTAssertEqual(ToolIdentity("TaskGet"), .taskGet)

        for name in ["TaskCreate", "TaskUpdate", "TaskList", "TaskGet"] {
            XCTAssertTrue(
                PermissionPolicy.isAutoAllowed(ToolIdentity(name)),
                "\(name) only updates Claude's session checklist"
            )
        }
    }

    /// Codex's names are lowercase and Claude's are PascalCase, so the two vocabularies cannot
    /// collide — but a future rename could, and this is what would catch it.
    func testTheTwoVocabulariesDoNotCollide() {
        XCTAssertEqual(ToolIdentity("Task"), .task)
        XCTAssertNotEqual(ToolIdentity("task"), .task)
    }

    func testMCPToolsKeepTheirName() {
        let name = "mcp__threading__display_image"
        XCTAssertEqual(ToolIdentity(name), .mcp(name))
    }

    /// `rawName` is what the sidebar and the permission card display, so an unmapped tool must
    /// still say what it was rather than becoming an empty row.
    func testUnknownToolsKeepTheirRawName() {
        XCTAssertEqual(ToolIdentity("spawn_agent").rawName, "spawn_agent")
    }
}

import Foundation

// MARK: - Subagent Tool Arguments

/// A subagent to start: the brief it opens on, and the same frozen launch choices a manager's
/// `spawn_session` takes, so one rule (`SpawnChildChoices`) decides what an omitted choice means.
struct StartSubagentArguments: Codable, Sendable {
  let brief: String?
  let plan: SpawnSessionPlanArguments?

  init(brief: String?, plan: SpawnSessionPlanArguments? = nil) {
    self.brief = brief
    self.plan = plan
  }
}

// MARK: - Subagent Tool Declarations

extension MCPTools {
  /// `start_subagent`, alone in the "Subagents" group so the user's switch for delegation is not
  /// the same switch as messaging. Every rule — depth, bounds, the parent's ceiling — lives in
  /// `WorkspaceControlPlane.admitSubagent`; this declaration owns only the wire contract.
  static let subagentDeclarations: [MCPToolDefinition] = [
    MCPToolDefinition(
      tool: .startSubagent,
      name: "start_subagent",
      groupID: "subagents",
      family: .subagents,
      annotations: MCPToolAnnotations(
        readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: true
      ),
      title: "Start subagent",
      detail: "Hand part of this task to another agent, on any provider, as a chat nested here.",
      symbol: "arrow.turn.down.right",
      decodeArguments: { container in
        try container.decodeIfPresent(StartSubagentArguments.self, forKey: .arguments)
          ?? StartSubagentArguments(brief: nil)
      },
      observesPanel: false,
      executeArguments: { handler, arguments, sessionID, completion in
        handler.startSubagent(arguments, for: sessionID, completion: completion)
      },
      description: """
        Start a subagent: a chat of your own, on any provider, working on a brief you write. It \
        is not your provider's built-in subagent but a real chat, nested under this one in the \
        user's sidebar, that the user can open and steer; it runs on its own login's usage. \
        Use it to hand part of your task to another agent — a second opinion from another \
        model, a piece of work to run beside yours.

        Its final reply to each turn you started comes back to you as mail: you are told mail \
        is waiting and read it with mail_inbox. Keep working meanwhile; watch_session waits for \
        its turn to settle without polling, and reports a usage limit or an exit, which send no \
        mail. Send it follow-ups with mail_send. When you are done with it and it is settled, \
        archive it with archive_session and its session_id.

        plan.kind is claude, codex, grok or cursor. On this chat's own runtime the subagent \
        inherits its login, model, effort and fast mode; on another it starts on that \
        runtime's defaults unless plan names them. permission_mode may not exceed this chat's \
        own. At most 4 live subagents, 6 starts per 10 minutes, and a subagent cannot start \
        subagents of its own.
        """,
      inputSchema: MCPInputSchema(properties: [
        "brief": MCPPropertySchema(
          type: .string,
          description: "The task, written for an agent that has none of your context."
        ),
        "plan": MCPPropertySchema(
          type: .object,
          description: "Optional launch choices.",
          properties: [
            "kind": MCPPropertySchema(
              type: .string,
              description: "claude, codex, grok or cursor; defaults to this chat's runtime."
            ),
            "account": MCPPropertySchema(
              type: .string,
              description: "Login id or best; omit for the default. Not accepted for grok or cursor."
            ),
            "model": MCPPropertySchema(type: .string, description: "Optional model identifier."),
            "reasoning_effort": MCPPropertySchema(type: .string, description: "Optional reasoning effort."),
            "fast_mode": MCPPropertySchema(type: .boolean, description: "Optional fast-mode choice."),
            "branch": MCPPropertySchema(type: .string, description: "Optional existing checkout branch."),
            "uses_native_ui": MCPPropertySchema(
              type: .boolean,
              description: "Use Threading's native chat surface; defaults to it where the runtime has one."
            ),
            "permission_mode": MCPPropertySchema(
              type: .string,
              description: "At most this chat's own permission mode; defaults to it."
            ),
            "managed_workspace_plan": MCPPropertySchema(
              type: .object,
              description: "Optional isolated worktree; its work is kept for the user to review.",
              properties: [
                "delivery": MCPPropertySchema(type: .string, description: "keepForReview.")
              ],
              required: ["delivery"]
            ),
          ],
          required: []
        ),
      ], required: ["brief"])
    ),
  ]
}

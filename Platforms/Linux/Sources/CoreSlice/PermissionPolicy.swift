import Foundation

// MARK: - Permission Policy

/// Which tools are worth interrupting the user for.
///
/// The hook fires for *every* tool, including ones the terminal never prompts about. Deciding
/// here rather than in the hook's matcher keeps the generated settings file static and puts
/// the policy somewhere it can be reasoned about.
///
/// Foundation-only, so every host that presents native permission requests answers them with
/// the same rules. Threading's own MCP tools are the one host-owned input: a host passes the
/// inventory it actually serves, and the Mac's convenience overloads beside `PermissionBroker`
/// pass its built-in registry.
enum PermissionPolicy {

    /// What a request is already decided as, or nil to ask the user.
    ///
    /// `allowedForSession` holds the tools the user chose to stop being asked about in this
    /// session; `mode` is the session's permission mode, nil for a runtime without modes.
    static func automaticDecision(
        for request: PermissionRequest,
        allowedForSession: Set<ToolIdentity>,
        mode: AgentPermissionMode?,
        kind: AgentKind? = nil,
        builtInMCPTool: (String) -> Bool
    ) -> PermissionDecision? {
        if isAutoAllowed(request.tool, builtInMCPTool: builtInMCPTool) {
            return .allow(reason: "Read-only tool, allowed automatically by Threading.")
        }

        // A shell call is judged by what it runs, because one tool name covers both reading and
        // writing — and under Codex it is how files are read at all.
        if request.tool == .bash,
           let command = request.shellCommand,
           ShellCommandPolicy.isReadOnly(command) {
            return .allow(reason: "Read-only command, allowed automatically by Threading.")
        }

        if allowedForSession.contains(request.tool) {
            return .allow(reason: "Allowed for this session by the user.")
        }

        if let kind, let deferral = agentDecision(for: request.origin, kind: kind) {
            return deferral
        }

        // The session's permission mode, honoured here because the CLI does not honour it *for*
        // us: measured against 2.1.220, `PreToolUse` fires under `bypassPermissions` and
        // `dontAsk` exactly as it does under `manual`. Without this, a natively rendered session
        // in Bypass would still be stopped by Threading's own sheet — the app contradicting the
        // mode the user picked in it.
        if let mode, let standing = standingDecision(for: request.tool, in: mode) {
            return standing
        }
        return nil
    }

    /// Whether the runtime's own permission flow decides this call, so Threading should neither
    /// allow nor ask. Nil means the call is Threading's to decide.
    ///
    /// Only a `toolHook` request can be left to the runtime: the hook fires before that flow on
    /// every tool call, while a runtime's own request means the flow already ran and asked for a
    /// person. Two cases, both measured:
    ///
    /// - **The process reports Auto.** Auto means the runtime decides for itself when to ask, and
    ///   a card per tool call overruled exactly that. On Claude 2.1.296 a headless
    ///   `--permission-mode auto` stream whose `PreToolUse` hook printed nothing ran a `Write` and
    ///   a `Bash` with no denials, decided by its own classifier; the same run under `manual`
    ///   denied both. The payload's `permission_mode` decides, never the session's record: a chat
    ///   still running in Manual whose chip now says Auto would have its calls blocked, not
    ///   decided, by a hook that fell silent.
    /// - **Every mode, where the runtime owns its approvals** (`AgentCapabilities
    ///   .runtimeOwnedApprovals`). Codex honours only a hook's `deny`, so a hook's allow granted
    ///   nothing and its card either repeated the question Codex then asked over app-server or
    ///   asked one Codex's configured posture would never have asked.
    ///
    /// Threading's own refusals are not affected: an unattended automation run and the macOS
    /// grant briefing are both decided in `PermissionBroker.decide` before this is reached.
    static func agentDecision(
        for origin: PermissionRequest.Origin,
        kind: AgentKind
    ) -> PermissionDecision? {
        guard case .toolHook(let reportedMode) = origin else { return nil }

        if kind.supports(.runtimeOwnedApprovals) {
            return .deferToAgent(
                reason: "Left to \(kind.displayName)'s own approval policy, which asks if it needs to."
            )
        }
        if let reportedMode, AgentPermissionMode(externalValue: reportedMode, for: kind) == .auto {
            return .deferToAgent(reason: "Auto: left to \(kind.displayName)'s own permission check.")
        }
        return nil
    }

    /// What the session's mode already decides, or nil to ask.
    ///
    /// Only the modes that *promise* something are answered here. `manual` asks by definition;
    /// `plan` and `auto` are enforced inside the CLI — plan by refusing to act, auto by its own
    /// classifier — and neither promises Threading's sheet will stay down, so asking remains both
    /// honest and the conservative side to be wrong on. A hook's question under Auto never gets
    /// this far: `agentDecision(for:kind:)` leaves it to the runtime first.
    ///
    /// `dontAsk` denies rather than allows. That is the mode's actual meaning in the CLI, whose
    /// fallback table reads `dontAsk → deny`: it promises never to interrupt, and keeps the
    /// promise by refusing and telling the model — not by waving the call through.
    static func standingDecision(
        for tool: ToolIdentity,
        in mode: AgentPermissionMode
    ) -> PermissionDecision? {
        switch mode {
        case .bypassPermissions:
            return .allow(reason: "Bypass Permissions: this chat runs without permission checks.")

        case .dontAsk:
            return .deny(reason: "Don't Ask: this chat refuses anything that would need approval.")

        case .acceptEdits:
            // The edit half of the mode's name. A command is not an edit, and this is the whole
            // distinction between Accept Edits and the modes either side of it.
            return isFileEdit(tool)
                ? .allow(reason: "Accept Edits: file changes are allowed without asking.")
                : nil

        case .manual, .plan, .auto:
            return nil
        }
    }

    /// Whether the tool changes files, as opposed to running something.
    private static func isFileEdit(_ tool: ToolIdentity) -> Bool {
        switch tool {
        case .write, .edit, .multiEdit, .notebookEdit:
            return true
        default:
            return false
        }
    }

    /// Deliberately exhaustive rather than a denylist: adding a known identity forces an
    /// explicit policy choice, while `.unknown` remains consequential and prompts.
    static func isAutoAllowed(_ tool: ToolIdentity, builtInMCPTool: (String) -> Bool) -> Bool {
        switch tool {
        case .read, .glob, .grep, .notebookRead,
             .todoWrite, .todoRead, .taskCreate, .taskUpdate, .taskList, .taskGet,
             .task, .toolSearch:
            return true

        case .mcp(let name):
            // Threading's own display tools draw in a panel the user is already looking at, and
            // are allowlisted for terminal sessions for the same reason. Compare the complete
            // built-in identity: MCP server names may themselves contain the `__` delimiter, so
            // the server-name prefix is not an identity boundary.
            return builtInMCPTool(name)

        case .bash, .write, .edit, .multiEdit, .notebookEdit,
             .webFetch, .webSearch, .plan, .unknown:
            return false
        }
    }
}

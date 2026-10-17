import Foundation

/// The native launch lines of the providers that speak the Agent Client Protocol. Account
/// routing, the MCP bridge and the mode a session falls back to belong to the host that
/// resolves them; these lines are the part every host shares.
enum ACPLaunchCommand {

    /// Grok exposes ACP over newline-delimited JSON-RPC. The stream wrapper owns the
    /// initialize/session handshake; the line selects the stdio transport and any model the
    /// conversation already pinned.
    ///
    /// The mode is stated here because the ACP handshake carries none. Without it, choosing Plan
    /// or Bypass Permissions on a natively rendered Grok session recorded the choice and redrew
    /// the chip while the process ran under whatever `grok` defaults to.
    static func grok(
        executable: String = AgentDefaults.grokExecutable,
        model: String?,
        permissionMode: AgentPermissionMode?
    ) -> ShellCommand {
        var command = ShellCommand(word: executable)
        // Grok parses the mode before its `agent` subcommand.
        for launchFlag in permissionMode?.launchFlags(for: .grok) ?? [] {
            command.append(flag: launchFlag.name, value: launchFlag.value)
        }
        command.append(word: "agent")
        if let model, !model.isEmpty {
            command.append(flag: AgentDefaults.grokModelFlag, value: model)
        }
        command.append(word: "stdio")
        return command
    }

    /// Cursor exposes the same protocol over `cursor-agent acp`, a hidden subcommand that takes
    /// no options of its own: the ACP session carries its cwd, MCP servers, modes and model over
    /// the wire. A launch also sets `AgentDefaults.cursorLaunchEnvironment`, which keeps the
    /// CLI's login from opening a browser from a native app.
    static func cursor(executable: String = AgentDefaults.cursorExecutable) -> ShellCommand {
        var command = ShellCommand(word: executable)
        command.append(word: AgentDefaults.cursorACPSubcommand)
        return command
    }
}

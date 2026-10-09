import Foundation

// MARK: - MCP Bridge Invocation

/// The command line that spawns one session's stdio bridge.
///
/// A value rather than a formatted string because three transports render it three ways — a
/// JSON `command`/`args` pair for Claude, TOML overrides for Codex, and an ACP server object —
/// and a string would have to be re-split by each of them.
struct MCPBridgeInvocation: Equatable, Sendable {
    let command: String
    let arguments: [String]
    /// Entries the bridge's own environment needs — the session token. Never rendered into an
    /// argument: each client states it in its config file or forwards it from its own
    /// environment (Codex's `env_vars`), because arguments are readable by every user.
    var environment: [String: String] = [:]
}

// MARK: - MCP Server Binding

/// How one launch reaches Threading's MCP server.
///
/// The two cases differ in *when* the address is resolved, which is the whole point of the
/// bridge. An HTTP URL is resolved by the CLI once, at startup, so a session that starts while
/// Threading is closed spends the rest of its life with no Threading tools. A stdio server is
/// resolved by spawning it, which moves the address inside a process we own, where it is
/// retried.
enum MCPServerBinding: Equatable, Sendable {
    case http(url: String)
    case stdio(MCPBridgeInvocation)

    /// One entry of Claude's `--mcp-config` `mcpServers` object.
    var claudeServerObject: [String: Any] {
        switch self {
        case .http(let url):
            return ["type": "http", "url": url]
        case .stdio(let invocation):
            var object: [String: Any] = [
                "type": "stdio",
                "command": invocation.command,
                "args": invocation.arguments
            ]
            if !invocation.environment.isEmpty { object["env"] = invocation.environment }
            return object
        }
    }

    /// One entry of ACP's `mcpServers` array on `session/new` and `session/load`.
    ///
    /// The stdio variant carries **no** `type`: ACP's `McpServer` union tags only the extra
    /// transports (`http`, `sse`) and stdio is the unconditional baseline, required to be
    /// exactly `name`, `command`, `args` and `env`. Cursor's own `initialize` says as much —
    /// it advertises `mcpCapabilities: {http: true, sse: true}` and does not mention stdio,
    /// which reads as "http and sse *as well*"
    /// (`docs/archive/research/CURSOR_ACP_FINDINGS.md` §3).
    func acpServerObject(named name: String) -> [String: Any] {
        switch self {
        case .http(let url):
            return ["type": "http", "name": name, "url": url, "headers": []]
        case .stdio(let invocation):
            return [
                "name": name,
                "command": invocation.command,
                "args": invocation.arguments,
                "env": invocation.environment.keys.sorted().map { key in
                    ["name": key, "value": invocation.environment[key] ?? ""]
                }
            ]
        }
    }
}

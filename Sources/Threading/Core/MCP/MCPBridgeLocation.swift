import Foundation

// MARK: - MCP Bridge Defaults

/// Names, permissions and bounds for the two files that address a session's bridge to this app.
///
/// A hook needs exactly two things to find its way back: somewhere to knock that is the same
/// address it was the last time, and a token that is the same token it was the last time. A
/// loopback port is neither — it is minted per launch — which is why a session's whole bridge
/// used to die with the app that started it.
///
/// Both are per-user secrets, so they share one directory. **The directory's permissions are
/// the boundary, not the endpoint's**: a `127.0.0.1` port is reachable by every process on this
/// machine that can guess a token, while a socket inside a `0700` directory is reachable only
/// by processes running as this user.
enum MCPBridgeDefaults {

    /// The directory holding the rendezvous socket and the durable token file, created `0700`.
    static let directoryName = "bridge"

    /// Owner-only. See the type's note: this is the tighter boundary a unix socket buys.
    static let directoryPermissions = 0o700

    /// Owner-only as well. Defence in depth rather than the boundary itself — the enclosing
    /// directory already excludes everyone else, which also covers the temporary file an atomic
    /// write creates before the rename.
    static let filePermissions = 0o600

    /// The rendezvous. One per user, byte-identical across launches. Codex receives it through
    /// the launch environment so its shared `hooks.json` stays byte-stable while retaining the
    /// loopback route as a per-launch fallback.
    static let socketFileName = "mcp.sock"

    /// The durable per-session tokens.
    static let tokenFileName = "session-tokens.json"

    /// The stdio shim shipped in `Contents/Helpers`, spawned per session by the CLI itself.
    static let helperName = "threading-mcp-bridge"

    /// Where the app bundle keeps its `product-type.tool` helpers, this one included.
    static let helpersDirectoryPath = "Contents/Helpers"

    /// The bridge's command line. All three are required and it exits `64` without them: every
    /// path on that line is the app's decision, so a bridge pointed at nothing would look to
    /// the user exactly like an app that was closed.
    static let socketArgument = "--socket"
    static let tokenArgument = "--token"
    static let cacheArgument = "--cache"

    /// `sockaddr_un.sun_path` is a 104-byte array on Darwin and the path inside it is
    /// NUL-terminated, so 103 bytes is the most a bound path may carry.
    ///
    /// A home directory long enough to pass that must cost the socket and nothing else: the TCP
    /// listener still comes up and every hook still routes through it. An app broken by a long
    /// user name would be a worse bug than the one this whole file exists to fix.
    static let maximumSocketPathBytes = 103

    /// Refusal boundary for reading the token file, not an expected size.
    ///
    /// One entry is about ninety bytes, so this admits far more sessions than a project store
    /// plausibly holds while refusing a file that has been replaced by something else. The real
    /// bound on the file is `MCPSessionRegistry.retainOnly`, which rewrites it from the live
    /// session set every time a session is deleted.
    static let maximumTokenFileBytes = 1_024 * 1_024

    /// The token file's schema version, so a future format change is recognised rather than
    /// read as corruption.
    static let tokenFileVersion = 1

    static let tokenWriteQueueLabel = "codes.threading.mcp.tokens"
}

// MARK: - MCP Bridge Location

/// Where the socket and the durable tokens live, and whether the socket can live there at all.
///
/// Resolved through the same hosted-test redirect the rest of the app's state uses. That is not
/// tidiness: a hosted test bundle runs *inside* the shipping app, so without the redirect a test
/// that revoked a fixture session would rewrite the developer's own token file with its fixture
/// list, and a test that started the server would bind the socket the developer's running app is
/// listening on.
enum MCPBridgeLocation {

    // MARK: - Public Methods

    /// `~/Library/Application Support/Threading`, or this test process's scratch root.
    static var supportRoot: URL {
        StateManager.isHostedTest
            ? StateManager.hostedTestDirectory()
            : AppDataLocations.supportDirectory
    }

    /// The `0700` directory holding the socket and the token file.
    static var directory: URL {
        supportRoot.appendingPathComponent(
            MCPBridgeDefaults.directoryName,
            isDirectory: true
        )
    }

    /// The rendezvous path, knowable before any listener exists — which is what lets
    /// `writeHookSettings` write hooks for a session launched before the server is up.
    static var socketPath: String {
        directory.appendingPathComponent(MCPBridgeDefaults.socketFileName).path
    }

    /// The durable per-session token file.
    static var tokenFile: URL {
        directory.appendingPathComponent(MCPBridgeDefaults.tokenFileName)
    }

    /// Creates the directory if it is missing and tightens it to `0700` either way.
    ///
    /// The permissions are re-applied rather than only set at creation, because the directory
    /// may already exist from a build that created it with the default mask.
    @discardableResult
    static func prepareDirectory(_ directory: URL = MCPBridgeLocation.directory) -> Bool {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: MCPBridgeDefaults.directoryPermissions]
            )
            try fileManager.setAttributes(
                [.posixPermissions: MCPBridgeDefaults.directoryPermissions],
                ofItemAtPath: directory.path
            )
            return true
        } catch {
            ThreadingLogger.mcp.error(
                "Could not prepare the MCP bridge directory: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            return false
        }
    }

    /// The path if a unix socket can be bound at it, or nil having said why.
    ///
    /// Nil is a degradation, never a failure: the caller skips the socket listener and the TCP
    /// one carries everything, exactly as it did before the socket existed.
    static func addressableSocketPath(_ path: String) -> String? {
        guard path.utf8.count <= MCPBridgeDefaults.maximumSocketPathBytes else {
            ThreadingLogger.mcp.error(
                """
                MCP socket path is \(path.utf8.count, privacy: .public) bytes, over the \
                \(MCPBridgeDefaults.maximumSocketPathBytes, privacy: .public)-byte limit; \
                the unix listener is skipped and hooks fall back to the loopback port
                """
            )
            return nil
        }
        return path
    }

    /// One shell word, so a path containing `Application Support` survives being pasted into a
    /// hook command.
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Where the stdio shim would be, whether or not it is there.
    ///
    /// Deliberately a *candidate*: existence and executability are checked by whoever is about
    /// to build a command line, so one place decides the whole "can this launch use the bridge"
    /// question rather than two that can disagree. `bundle` is injectable so a test can point at
    /// a directory holding no helper and prove the launch falls back to HTTP.
    static func helperURL(in bundle: Bundle = .main) -> URL {
        bundle.bundleURL
            .appendingPathComponent(MCPBridgeDefaults.helpersDirectoryPath, isDirectory: true)
            .appendingPathComponent(MCPBridgeDefaults.helperName, isDirectory: false)
    }
}

// MARK: - MCP Bridge Invocation

/// The command line that spawns one session's stdio bridge.
///
/// A value rather than a formatted string because three transports render it three ways — a
/// JSON `command`/`args` pair for Claude, TOML overrides for Codex, and an ACP server object —
/// and a string would have to be re-split by each of them.
struct MCPBridgeInvocation: Equatable, Sendable {
    let command: String
    let arguments: [String]
}

// MARK: - MCP Bridge Decision

/// The complete transport snapshot for one launch.
///
/// Gathered into one value so every renderer sees the same answer and the registry remains pure:
/// a test can force the setting on, name a helper that is not there, name a socket path too long
/// to bind, or remove the HTTP listener without touching process defaults, the bundle, or the
/// shared server.
struct MCPBridgeDecision: Sendable {

    /// The hidden opt-in. Off ships HTTP, exactly as before the bridge existed.
    let isEnabled: Bool

    /// Where the helper would be. Executability is checked at use, not here.
    let helperURL: URL

    /// The rendezvous, already through `addressableSocketPath` — nil when it cannot be bound.
    let socketPath: String?

    /// The loopback fallback available to this same launch.
    let httpPort: UInt16?

    init(
        isEnabled: Bool,
        helperURL: URL,
        socketPath: String?,
        httpPort: UInt16? = nil
    ) {
        self.isEnabled = isEnabled
        self.helperURL = helperURL
        self.socketPath = socketPath
        self.httpPort = httpPort
    }

    /// Production composition. Every dependency is named by the caller; reusable registry code
    /// never recovers settings, bundle state, or a server singleton on demand.
    @MainActor
    static func live(
        settings: AppSettings,
        server: MCPServer,
        bundle: Bundle
    ) -> MCPBridgeDecision {
        MCPBridgeDecision(
            isEnabled: settings.usesMCPStdioBridge,
            helperURL: MCPBridgeLocation.helperURL(in: bundle),
            // Startup does not release session restoration until both listener outcomes are
            // known. A path that merely *could* bind is not a route; only the listener's
            // published path may select the durable bridge.
            socketPath: server.socketPath,
            httpPort: server.port
        )
    }
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
            return [
                "type": "stdio",
                "command": invocation.command,
                "args": invocation.arguments
            ]
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
                "env": []
            ]
        }
    }
}

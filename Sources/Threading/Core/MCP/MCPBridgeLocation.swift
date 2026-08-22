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

    /// The rendezvous. One per user, byte-identical across launches, which is the entire point:
    /// a literal that never changes can be written into Codex's shared `hooks.json` without
    /// invalidating the trust hash the user approved it under.
    static let socketFileName = "mcp.sock"

    /// The durable per-session tokens.
    static let tokenFileName = "session-tokens.json"

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
}

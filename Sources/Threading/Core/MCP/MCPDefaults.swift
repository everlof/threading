import Foundation

// MARK: - MCP Defaults

/// Settings for the MCP server Threading exposes to the agents it launches.
///
/// The server gives an agent a way to reach the GUI it is running inside — showing an image
/// in the side panel rather than naming a file path the terminal cannot render.
enum MCPDefaults {
    /// The server name agents see. Tool names derive from it: `mcp__threading__display_image`.
    static let serverName = "threading"
    static let serverVersion = "0.1.0"

    /// Spoken when a client offers no version of its own.
    static let protocolVersion = "2025-06-18"

    /// Loopback only. The endpoint is unauthenticated apart from its per-session token, so it
    /// must never be reachable off this machine.
    static let host = "127.0.0.1"

    /// Path prefix for session endpoints, completed by the session's token.
    static let pathPrefix = "/mcp/"

    /// Path prefix for `PreToolUse` permission requests, completed by the same token.
    static let permissionPathPrefix = "/permission/"

    /// Path prefix for lifecycle hook reports, completed by the same token.
    ///
    /// Separate from the permission prefix because the two have opposite blocking rules: a
    /// permission request holds the agent until a person answers, while a lifecycle report is
    /// told and forgotten.
    static let lifecyclePathPrefix = "/lifecycle/"

    /// The query parameter naming which lifecycle event a report describes.
    ///
    /// The event is carried in the URL rather than read from the payload so that one endpoint
    /// per session still distinguishes the events, and so nothing depends on the payload's own
    /// event field — Claude and Codex spell it differently.
    static let lifecycleEventParameter = "event"

    /// The authority a `--unix-socket` request carries.
    ///
    /// curl still needs a URL to build a request line and a `Host:` header from, but with
    /// `--unix-socket` it never resolves the authority — the connection is the socket. The name
    /// is therefore arbitrary and deliberately not `host` above, which is a real address.
    static let socketURLBase = "http://localhost"

    /// Environment variables carrying the session's token, and the endpoints, into a hook.
    ///
    /// Codex reads one `hooks.json` per account, shared by every session, and refuses to run a
    /// hook whose text has not been reviewed. The token has to reach the hook through the
    /// environment for that reason: one static file routes every session correctly, and its
    /// text never changes — so a trust decision survives the next launch, which a file carrying
    /// a per-session token would not.
    ///
    /// The *rendezvous* no longer needs the same treatment. A unix socket path is fixed per
    /// user, so `hooks.json` now carries it as a literal and the port variable is exported only
    /// for hooks the user wrote themselves against the loopback endpoint.
    static let portEnvironmentKey = "THREADING_MCP_PORT"
    static let socketEnvironmentKey = "THREADING_MCP_SOCKET"
    static let sessionTokenEnvironmentKey = "THREADING_SESSION_TOKEN"

    /// Pre-rename aliases exported beside the current routing variables.
    ///
    /// Existing Codex hooks were approved by the hash of their exact command text. Rewriting
    /// `SKALMAN_*` to `THREADING_*` would invalidate that approval, so launches with the
    /// integration enabled keep the old vocabulary alive while the installer recognises the
    /// known-compatible old commands. These names carry the same per-process values and do not
    /// broaden the endpoint's reach.
    static let legacyPortEnvironmentKey = "SKALMAN_MCP_PORT"
    static let legacySessionTokenEnvironmentKey = "SKALMAN_SESSION_TOKEN"

    /// Set only for sessions Threading renders itself, and read by Codex's `PreToolUse` hook.
    ///
    /// Codex has one `hooks.json` per account, shared by every session, so a surface-specific
    /// behaviour cannot be expressed in the file. This variable is how a shared file is scoped
    /// to one surface: a terminal session raises Codex's own approval prompt and must not be
    /// intercepted, so it simply does not export this.
    static let brokerEnvironmentKey = "THREADING_BROKER_TOOLS"
    static let legacyBrokerEnvironmentKey = "SKALMAN_BROKER_TOOLS"

    /// Marks the entries in a shared `hooks.json` that belong to Threading.
    ///
    /// A shell comment, so it is inert where it sits, and the only way to tell our entries from
    /// another tool's when updating a file we do not own.
    static let hookMarker = "# threading-lifecycle"

    /// Where per-session hook settings files are written, under Application Support.
    static let settingsDirectoryName = "settings"

    /// How long the permission hook waits for a decision. Long, because what it is waiting
    /// for is a person reading a dialog, not a machine.
    static let permissionTimeout: TimeInterval = 600

    /// How long an observational lifecycle hook waits before giving up.
    ///
    /// Deliberately tiny for observational boundaries. An unreachable app must cost a moment,
    /// not a turn. Turn start has its own timeout below because that reply is an admission
    /// barrier and therefore does carry correctness.
    static let lifecycleTimeout: TimeInterval = 2
    /// UserPromptSubmit is an admission barrier. A snapshot can run `rev-parse`, `read-tree`,
    /// `add`, and `write-tree`; each has GitReviewDefaults' 15-second process bound. Keep the
    /// hook alive for that full worst case plus transport overhead, or curl could release the
    /// agent while the baseline was still moving. Other observational hooks stay at 2s.
    static let turnStartLifecycleTimeout: TimeInterval = 62

    /// Stop is the other checkpoint barrier. Releasing it early would let the next queued turn
    /// alter the checkout before the authoritative final tree had been published.
    static let turnFinishLifecycleTimeout: TimeInterval = 62

    static func lifecycleTimeout(for event: HookLifecycleEvent) -> TimeInterval {
        switch event {
        case .turnStarted: return turnStartLifecycleTimeout
        case .turnFinished: return turnFinishLifecycleTimeout
        default: return lifecycleTimeout
        }
    }

    /// Also cleaned up when a session is deleted. Kept alongside the retained tokens so a
    /// revoked endpoint leaves no settings file pointing at it.
    static let cleanupDirectories = [configDirectoryName, settingsDirectoryName]

    /// Where per-session Claude `--mcp-config` files are written, under Application Support.
    static let configDirectoryName = "mcp"
    static let configFileExtension = "json"

    /// Claude tools are allowlisted wholesale, or every image would raise a permission prompt.
    static let allowedToolsPattern = "mcp__\(serverName)__*"

    /// The full Claude-side name of one tool, for launches that pre-approve a single tool
    /// rather than the wholesale pattern above — the scoped research runs.
    static func allowedToolName(_ tool: String) -> String {
        "mcp__\(serverName)__\(tool)"
    }

    /// Refused rather than read into memory, since the panel shows one image at a time.
    static let maximumImageBytes = 64 * 1024 * 1024
    /// Compressed bytes do not bound decoded memory. These still admit unusually long browser
    /// screenshots while refusing dimensions that would allocate hundreds of megabytes or
    /// overflow a decoder's row arithmetic.
    static let maximumImagePixelDimension = 32_768
    static let maximumImagePixelCount = 80_000_000

    /// Well under `maximumRequestBytes`, so an oversized document is refused with an
    /// explanation the agent can act on rather than a transport-level error it cannot.
    static let maximumHTMLBytes = 2 * 1024 * 1024

    /// Ceiling on a single HTTP request, so a malformed client cannot grow the buffer forever.
    static let maximumRequestBytes = 8 * 1024 * 1024
}

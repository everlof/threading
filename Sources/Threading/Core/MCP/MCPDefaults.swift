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
    /// Both endpoint values travel through the environment. The socket path is stable, while the
    /// port is the fallback for the exact launch whose unix listener did not bind. Keeping both
    /// out of Codex's shared `hooks.json` makes its reviewed command byte-stable across launches.
    static let portEnvironmentKey = "THREADING_MCP_PORT"
    static let socketEnvironmentKey = "THREADING_MCP_SOCKET"
    static let sessionTokenEnvironmentKey = "THREADING_SESSION_TOKEN"

    /// A shell fragment that posts the payload already stored in `payloadVariable` over the
    /// stable unix rendezvous, then retries the same bytes over this launch's loopback listener
    /// only when the socket could not be reached.
    ///
    /// The endpoint suffix may contain the session-token environment expansion used by Codex.
    /// Every other component is authored here, so Claude and Codex cannot drift into different
    /// fallback behavior again.
    static func hookPostCommand(
        payloadVariable: String,
        endpointSuffix: String,
        timeout: TimeInterval
    ) -> String {
        let socket = "$\(socketEnvironmentKey)"
        let port = "$\(portEnvironmentKey)"
        let socketURL = "\(socketURLBase)\(endpointSuffix)"
        let loopbackURL = "http://\(host):\(port)\(endpointSuffix)"
        let common = "-s --max-time \(Int(timeout))"
            + " -H 'Content-Type: application/json' --data-binary @-"

        return "( { [ -n \"\(socket)\" ] &&"
            + " printf '%s' \"$\(payloadVariable)\" |"
            + " curl \(common) --unix-socket \"\(socket)\" \"\(socketURL)\"; }"
            + " || { [ -n \"\(port)\" ] &&"
            + " printf '%s' \"$\(payloadVariable)\" |"
            + " curl \(common) \"\(loopbackURL)\"; } )"
    }

    // MARK: - The Broker Hook

    /// The whole `PreToolUse` broker command: post the request, and refuse in words when there
    /// was nothing to post it to.
    ///
    /// Both providers run this. Claude gets it in a per-session `--settings` file and Codex in
    /// the shared `hooks.json`, but the endpoint and the answer are one — `MCPServer`
    /// `routePermission` replies to both with `PermissionDecision.hookResponse` — so the
    /// fallback for an absent app is one fragment too.
    ///
    /// **`||` is the whole contract.** The deny runs only where the POST could not be made, so
    /// an app that answered is never followed by a second object on stdout; the CLI reads the
    /// first one it is given. **The pair is braced** because a call site may guard it: Codex's
    /// is `[ -n "$THREADING_BROKER_TOOLS" ] && …`, and `guard && post || deny` prints a refusal
    /// for every *unrouted* Codex run — the user's own terminal sessions, which have Codex's own
    /// approval prompt and must be left alone. Braced here rather than at the call site so the
    /// precedence is settled once.
    ///
    /// The timeout is the permission one by construction: this fragment builds nothing else.
    static func hookBrokerCommand(payloadVariable: String, endpointSuffix: String) -> String {
        "{ " + hookPostCommand(
            payloadVariable: payloadVariable,
            endpointSuffix: endpointSuffix,
            timeout: permissionTimeout
        ) + " || " + hookDenyFallback + "; }"
    }

    /// What a broker hook prints when the app could not be reached at all.
    ///
    /// A hook that says nothing is *also* a refusal, but a mute one: the CLI falls back to its
    /// own headless behaviour — `PermissionDecision.hookResponse` records what that means — and
    /// the model learns only that a tool did not run, so the turn stalls on something it can
    /// neither explain nor work around. `printf` exits 0, which matters as much as the bytes do:
    /// these CLIs read a `PreToolUse` hook's exit status as a decision of its own.
    static let hookDenyFallback = "printf '%s' " + singleQuoted(hookDenyResponseJSON)

    /// The reason that reaches the model when Threading is not there to be asked.
    ///
    /// Written for the model rather than for a person — it is carried in a tool result, never
    /// into the interface, so it is deliberately not an `L10n` key — and in the same voice the
    /// stdio bridge uses for a tool call with no app behind it (`BridgeDefaults`
    /// `unavailableToolText`): name the condition, say it is temporary, say what to do instead.
    /// An agent told only "denied" retries the same call until the turn ends.
    ///
    /// Plain ASCII, deliberately: this sentence is the one part of the fragment that is prose,
    /// and the fragment is shell text embedded in two provider files, one of which the user
    /// approves by the hash of its bytes.
    static let hookDenyReason = """
        Threading is not running, so it could not ask whether this tool may run, and the tool \
        was not run. This is temporary and needs no restart of this session: permission can be \
        asked again as soon as the app is open. Tell the user Threading is closed and continue \
        without this tool.
        """

    /// The exact bytes a running app would have answered with, for the launch where there is no
    /// app to answer at all.
    ///
    /// Built *from* `PermissionDecision.hookResponse` rather than transcribed, so the shape the
    /// server returns and the shape an absent server falls back to cannot drift apart. Sorted
    /// keys only make it deterministic, which a fragment written into two provider files and
    /// compared byte-for-byte has to be.
    static let hookDenyResponseJSON: String = {
        let response = PermissionDecision.deny(reason: hookDenyReason).hookResponse
        guard let data = try? JSONSerialization.data(
            withJSONObject: response,
            options: [.sortedKeys]
        ), let json = String(data: data, encoding: .utf8) else {
            // `hookResponse` is strings all the way down; serialising it cannot fail for any
            // input this type can hold. Failing loudly beats emitting an empty `printf`, which
            // would be exactly the silence this fragment exists to remove.
            preconditionFailure("A permission decision must serialise as JSON")
        }
        return json
    }()

    /// Quotes a literal for a POSIX shell, so it survives both the Claude settings file and the
    /// shared `hooks.json` it is embedded in as JSON.
    ///
    /// A single quote cannot be escaped inside single quotes — the sequence closes the string,
    /// contributes one escaped quote and opens a new one. Spelled out rather than left to the
    /// current text happening to contain none, because that text is a sentence somebody will
    /// reword.
    private static func singleQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Set only for sessions Threading renders itself, and read by Codex's `PreToolUse` hook.
    ///
    /// Codex has one `hooks.json` per account, shared by every session, so a surface-specific
    /// behaviour cannot be expressed in the file. This variable is how a shared file is scoped
    /// to one surface: a terminal session raises Codex's own approval prompt and must not be
    /// intercepted, so it simply does not export this.
    static let brokerEnvironmentKey = "THREADING_BROKER_TOOLS"

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
    static let cleanupDirectories = [
        configDirectoryName, settingsDirectoryName, bridgeCacheDirectoryName
    ]

    /// Where per-session Claude `--mcp-config` files are written, under Application Support.
    static let configDirectoryName = "mcp"
    static let configFileExtension = "json"

    /// Where each session's stdio bridge caches the catalogue it last fetched.
    ///
    /// Its own directory rather than a second file under `mcp`, because the writer is different:
    /// the config file is ours and the cache is the helper's, written `0600` through a temporary
    /// file and a rename. Being in `cleanupDirectories` is what makes it a per-session file
    /// rather than a leak — every sweep that revokes a session (`retainOnly`, `remove`,
    /// `endAdHoc`) already removes one file per directory named here.
    static let bridgeCacheDirectoryName = "bridge-catalogues"

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

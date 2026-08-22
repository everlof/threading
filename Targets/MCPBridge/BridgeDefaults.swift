import Foundation

// MARK: - Bridge Defaults

/// Every constant `threading-mcp-bridge` has, in one namespace.
///
/// Deliberately *not* shared with the app's `MCPDefaults`. This binary links Foundation and
/// nothing else so that it can run when the app is not, and importing the app's module to reach
/// four strings would trade that independence for nothing. The values that must agree with the
/// app are marked as such, each with the reason it has to agree; the rest are the bridge's own.
enum BridgeDefaults {

    // MARK: - Identity shared with the app

    /// The MCP server name Threading advertises. Must equal `MCPDefaults.serverName`, because a
    /// cache-served `initialize` answers *as* that server and the CLI derives `mcp__threading__*`
    /// tool names from it.
    static let serverName = "threading"

    /// Must equal `MCPDefaults.serverVersion`, for the same reason.
    static let serverVersion = "0.1.0"

    /// Spoken when the client offers no version of its own. Matches `MCPDefaults.protocolVersion`.
    ///
    /// A live `initialize` never reaches this: the app answers and the bridge forwards its reply
    /// untouched. It is only the floor for a handshake answered with no app behind it.
    static let protocolVersion = "2025-06-18"

    /// Matches `MCPDefaults.pathPrefix`; the session token completes it.
    static let pathPrefix = "/mcp/"

    /// The ceiling on one message in either direction, matching `MCPDefaults.maximumRequestBytes`.
    ///
    /// Stated here rather than read from the app for the independence reason above; the number
    /// exists so that a client which never sends a newline, or a server which never finishes a
    /// response, costs a bounded buffer instead of the machine's memory.
    static let maximumMessageBytes = 8 * 1024 * 1024

    // MARK: - HTTP

    /// The authority a unix-socket request carries. There is no name to resolve — the connection
    /// *is* the socket — but HTTP/1.1 requires the header, and the app's parser ignores it.
    static let hostHeader = "localhost"

    /// What a POST of a JSON-RPC message declares it will accept back. Both are named because
    /// MCP's streamable transport permits a server to answer either way; Threading answers JSON.
    static let requestAccept = "application/json, text/event-stream"
    static let eventStreamAccept = "text/event-stream"
    static let jsonContentType = "application/json"
    static let eventStreamContentType = "text/event-stream"

    /// One socket read. Matches `MCPConnection.chunkSize`, so neither side is the one that
    /// decides how much of a large tool result crosses at a time.
    static let socketReadChunk = 65_536

    // MARK: - Timing

    /// How long a connect may take before the socket is called unreachable.
    ///
    /// Short on purpose, and the only timeout in the bridge. A unix socket either has a listener
    /// or it does not; there is no network in the path to be slow. Everything *after* the connect
    /// is unbounded, because a `tools/call` can legitimately sit for minutes behind a permission
    /// prompt a person has not answered yet.
    static let connectTimeout: TimeInterval = 2

    /// The first pause after the event stream drops, and the ceiling it doubles towards.
    ///
    /// The stream is how the bridge learns the app came back, so a long ceiling would leave a
    /// live app looking dead for as long as it. Five seconds is a bounded cost against an app
    /// that stays closed for hours and an unnoticeable one against a relaunch.
    static let reconnectInitialDelay: TimeInterval = 0.5
    static let reconnectMaximumDelay: TimeInterval = 5
    static let reconnectBackoffFactor: Double = 2

    // MARK: - Bounds

    /// How many requests may be in flight at once.
    ///
    /// Each costs one thread and one socket, and the ceiling is deliberate backpressure: at the
    /// limit the bridge stops reading stdin rather than growing a queue. A conforming MCP client
    /// keeps a handful of requests open, so reaching this is a client fault, and stalling the one
    /// that caused it is the honest answer.
    static let maximumConcurrentRequests = 32

    /// How long a shutdown waits for requests already in flight.
    ///
    /// End of file on stdin means the client is gone, so an unanswered request has nowhere left
    /// to go and abandoning it is correct. The wait exists for the narrow case where an answer
    /// is a microsecond away — a local refusal, a reply already read off the socket — because
    /// exiting through it would drop a reply the client could still have used. Bounded, because
    /// a `tools/call` behind an unanswered permission prompt must not hold the process open.
    static let shutdownDrainTimeout: TimeInterval = 2

    /// Diagnostics are for a person reading a log, not for a counter. A socket that flaps for an
    /// hour must not write a gigabyte of identical lines, so the stream is capped and says so
    /// once when it stops.
    static let maximumDiagnosticLines = 200

    // MARK: - Text the bridge speaks for itself

    /// The tool-call refusal, returned as a *result* rather than an error so the model reads it.
    ///
    /// Phrased for the model rather than for the user: it names the condition, says it is not
    /// permanent, and says what to do instead — which is the difference between an agent that
    /// mentions the app is closed and one that retries the same call until the turn ends.
    static let unavailableToolText = """
        Threading is not running, so its tools are unavailable. This is temporary and needs no \
        restart of this session — the tools work again as soon as the app is open. Tell the user \
        Threading is closed and continue without this tool.
        """

    /// The `instructions` of an `initialize` answered with no app behind it and no cache to
    /// answer from. It is the only thing the CLI will read about this server for the whole
    /// session, so it says why the tool list is empty rather than leaving that unexplained.
    static let unavailableInstructions = """
        Threading is not running, so its tools are not listed. They become available without \
        restarting this session once the app is open.
        """

    /// Named in a JSON-RPC error for a request that is neither the handshake nor a tool call.
    static func unavailableMethodMessage(_ method: String) -> String {
        "Threading is not running, so ‘\(method)’ cannot be answered."
    }
}

// MARK: - Methods

/// The MCP method names the bridge has to recognise.
///
/// This is the whole of the bridge's protocol knowledge, and it stops here on purpose: no tool
/// name appears in this binary. A catalogue compiled in would be a second copy of
/// `MCPToolCatalog` that drifts from it silently, so the catalogue is *fetched* on the first
/// successful connect and cached, and a bridge that has never reached the app admits to an
/// empty list rather than inventing one.
enum BridgeMethod {
    static let initialize = "initialize"
    static let toolsList = "tools/list"
    static let toolsCall = "tools/call"
    static let ping = "ping"

    /// Written to stdout after a reconnect so the client re-lists tools it may have been told
    /// about while the app was closed.
    static let toolsListChangedNotification = Data(
        #"{"jsonrpc":"2.0","method":"notifications/tools/list_changed"}"#.utf8
    )
}

// MARK: - JSON-RPC codes

enum BridgeErrorCode {
    static let parse = -32700
    static let invalidRequest = -32600

    /// The implementation-defined range. Used for a request the bridge can neither forward nor
    /// answer, so the client learns *why* rather than seeing a hang.
    static let unavailable = -32000
}

// MARK: - Exit codes

enum BridgeExitCode {
    /// `EX_USAGE`. The app builds this command line, so a malformed one is a bug in the app and
    /// must be loud rather than degrade into a bridge pointed at nothing.
    static let usage: Int32 = 64
    static let success: Int32 = 0
}

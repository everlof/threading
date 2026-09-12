import Darwin
import Foundation

// MARK: - MCP Bridge

/// The stdio MCP server a Claude or Codex session talks to, in front of Threading's own server.
///
/// **What it is for.** `--mcp-config` names an endpoint that the CLI resolves once, at startup.
/// A session launched while Threading is closed therefore fails its handshake and spends the
/// rest of its life with no Threading tools, and a session whose app restarts mid-turn is left
/// holding an address that no longer exists. A stdio server is resolved by *spawning* it, so the
/// address moves inside the bridge, where it can be retried.
///
/// **Three behaviours, and nothing else.** Everything the client sends is forwarded verbatim to
/// `POST /mcp/<token>` and everything the app answers is written back verbatim; on top of that
/// the bridge (1) answers `initialize`, `tools/list` and `ping` from a cache when the socket is
/// unreachable, (2) refuses a `tools/call` in that window with a *result* the model reads rather
/// than a hang it cannot, and (3) re-announces `notifications/tools/list_changed` after the app
/// comes back, so the client re-lists tools it was told nothing about.
///
/// **No tool name appears in this binary.** The catalogue is fetched on the first successful
/// connect and cached; a bridge that has never reached the app admits to an empty list. That is
/// the drift rule: a compiled-in catalogue would be a second copy of `MCPToolCatalog` that
/// nothing would notice going stale.
final class MCPBridge: @unchecked Sendable {

    // MARK: - Properties

    private let arguments: BridgeArguments
    private let output: BridgeOutput
    private let cache: CatalogueCache

    /// Requests run concurrently because they genuinely overlap: the app may hold a `tools/call`
    /// for minutes behind a permission prompt while the client goes on pinging, and a bridge that
    /// answered one at a time would make the CLI declare the server dead. One connection each,
    /// bounded by `maximumConcurrentRequests`.
    private let requests = DispatchQueue(
        label: "codes.threading.mcp-bridge.requests",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private let inFlight = DispatchSemaphore(value: BridgeDefaults.maximumConcurrentRequests)
    /// Counts the same requests, so shutdown can wait for the ones about to answer.
    private let scheduled = DispatchGroup()

    private let stateLock = NSLock()
    private var snapshot = CatalogueSnapshot()
    /// What is actually on disk, so an unchanged catalogue is not written again.
    ///
    /// The comparison cannot be made on the raw reply — every reply carries a different JSON-RPC
    /// `id`, so the bytes differ on every call even when the catalogue has not moved. It is made
    /// on the `result` alone, canonicalised with sorted keys so that two encodings of the same
    /// catalogue compare equal. A *failed* store leaves this unchanged, so the next reply retries
    /// rather than remembering a write that never landed.
    private var storedSnapshot = CatalogueSnapshot()
    /// Set whenever the app could not be reached, and read-and-cleared by the next successful
    /// event-stream connect. It is what turns "the app came back" into a `tools/list_changed`.
    private var announceOnNextConnect = false
    private var isStopping = false
    private var eventStream: UnixSocketConnection?

    // MARK: - Initialization

    init(arguments: BridgeArguments, output: BridgeOutput = BridgeOutput()) {
        self.arguments = arguments
        self.output = output
        cache = CatalogueCache(path: arguments.cachePath)
    }

    // MARK: - Public Methods

    /// Runs until stdin reaches end of file, then exits.
    ///
    /// The stdin pump owns the calling thread deliberately: EOF on stdin is the client going
    /// away, and it is the only thing that ends this process. Returning from `run` therefore
    /// means "shut down", and there is no other exit path to keep in step with it.
    func run() -> Never {
        snapshot = cache.load()
        storedSnapshot = snapshot

        let stream = Thread { [weak self] in self?.runEventStream() }
        stream.name = "codes.threading.mcp-bridge.events"
        stream.start()

        pumpStandardInput()

        stop()
        exit(BridgeExitCode.success)
    }

    // MARK: - Private Methods — stdin

    /// Reads stdin, splits it on newlines, and hands each line on.
    ///
    /// Bounded by construction: a client that never sends a newline costs
    /// `BridgeDefaults.maximumMessageBytes` and then one parse error, after which its bytes are
    /// discarded to the next newline rather than accumulated.
    private func pumpStandardInput() {
        var buffer = Data()
        var isDiscardingOverlongLine = false
        var chunk = [UInt8](repeating: 0, count: BridgeDefaults.socketReadChunk)

        while true {
            let count = chunk.withUnsafeMutableBytes { raw -> Int in
                Darwin.read(Self.standardInput, raw.baseAddress, raw.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                output.diagnose("stdin failed: \(String(cString: strerror(errno)))")
                return
            }
            guard count > 0 else { return }  // End of file: the client is gone.

            buffer.append(contentsOf: chunk[0..<count])

            while let newline = buffer.firstIndex(of: Self.lineFeed) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer = Data(buffer[buffer.index(after: newline)...])
                if isDiscardingOverlongLine {
                    isDiscardingOverlongLine = false
                    continue
                }
                handle(line: line)
            }

            if isDiscardingOverlongLine {
                buffer = Data()
            } else if buffer.count > BridgeDefaults.maximumMessageBytes {
                output.writeLine(JSONRPCLine.failure(
                    id: nil,
                    code: BridgeErrorCode.parse,
                    message: "Parse error: a message longer than "
                        + "\(BridgeDefaults.maximumMessageBytes) bytes was discarded."
                ))
                isDiscardingOverlongLine = true
                buffer = Data()
            }
        }
    }

    /// Decodes one line and schedules it. A line that cannot be decoded is answered here and the
    /// pump carries on — a malformed message is the client's problem, not a reason to stop.
    private func handle(line: Data) {
        guard !Self.isBlank(line) else { return }

        let message: DecodedJSONRPCMessage
        do {
            message = try JSONRPCLine.decode(line)
        } catch JSONRPCLine.DecodeFailure.invalidRequest {
            output.writeLine(JSONRPCLine.failure(
                id: nil,
                code: BridgeErrorCode.invalidRequest,
                message: "Invalid Request"
            ))
            return
        } catch {
            output.writeLine(JSONRPCLine.failure(
                id: nil,
                code: BridgeErrorCode.parse,
                message: "Parse error"
            ))
            return
        }

        // Backpressure rather than a queue: at the ceiling the pump stops reading stdin. A
        // conforming client keeps a handful of requests open, so arriving here at all is a
        // client fault, and stalling the client that caused it is the honest answer.
        inFlight.wait()
        scheduled.enter()
        // Retained deliberately rather than captured weakly: an unbalanced `leave` would be an
        // unbalanced group, and the bridge lives for the process's life anyway.
        requests.async { [self] in
            defer {
                inFlight.signal()
                scheduled.leave()
            }
            forward(message, line: line)
        }
    }

    // MARK: - Private Methods — forwarding

    /// POSTs one message and writes back whatever the app answered.
    private func forward(_ message: DecodedJSONRPCMessage, line: Data) {
        do {
            let connection = try UnixSocketConnection(path: arguments.socketPath)
            defer { connection.close() }

            try connection.send(UnixHTTPRequest.post(path: arguments.endpointPath, body: line))
            let head = try connection.readHead()

            // Anything else — a 404 for a revoked token most of all — means this endpoint no
            // longer answers for this session, which the client should hear about the same way
            // it hears about a closed app.
            guard head.status == Self.okStatus || head.status == Self.acceptedStatus else {
                throw UnixHTTPError.unexpectedStatus(head.status)
            }

            let body = try connection.readBody(length: head.contentLength ?? 0)
            guard !message.isNotification, !body.isEmpty else { return }

            remember(replyTo: message.method, body: body)
            output.writeLine(body)
        } catch {
            answerLocally(message, because: error)
        }
    }

    /// Caches the two answers a handshake needs, so the next launch has them with no app running.
    ///
    /// **Only when the catalogue changed.** A catalogue is answered identically every time it is
    /// asked for — the app announces `notifications/tools/list_changed` when it genuinely moves —
    /// so writing on every reply meant rewriting a quarter-megabyte file with the bytes already
    /// in it, once per `tools/list`, for the life of the session.
    ///
    /// The `result` is canonicalised with sorted keys before it is compared or stored, because
    /// `JSONSerialization` does not promise a key order and an unstable encoding would make every
    /// catalogue look new. The comparison is against what was last successfully *stored*, so a
    /// write that failed is retried by the next reply instead of being remembered as done.
    private func remember(replyTo method: String, body: Data) {
        guard method == BridgeMethod.initialize || method == BridgeMethod.toolsList else { return }
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let result = object["result"] as? [String: Any],
              let data = try? JSONSerialization.data(
                  withJSONObject: result,
                  options: [.sortedKeys]
              ) else { return }

        let updated: CatalogueSnapshot? = stateLock.withLock {
            if method == BridgeMethod.initialize {
                snapshot.initializeResult = data
            } else {
                snapshot.toolsListResult = data
            }
            return snapshot == storedSnapshot ? nil : snapshot
        }
        guard let updated else { return }

        guard cache.store(updated) else { return }
        stateLock.withLock { storedSnapshot = updated }
    }

    // MARK: - Private Methods — answering without the app

    /// Answers a message the app could not be asked about.
    ///
    /// The split is the point of the whole helper. A handshake is answered from what the app said
    /// last time, so the session starts with a working server; a tool call is refused with a
    /// *result*, so the model reads a sentence and moves on; anything else gets a JSON-RPC error
    /// naming the condition. Nothing waits.
    private func answerLocally(_ message: DecodedJSONRPCMessage, because error: Error) {
        markUnreachable()
        output.diagnose("the app could not be reached: \(error)")

        guard let id = message.encodedID else { return }

        switch message.method {
        case BridgeMethod.initialize:
            output.writeLine(JSONRPCLine.result(
                id: id,
                body: initializeResult(protocolVersion: message.requestedProtocolVersion)
            ))

        case BridgeMethod.toolsList:
            output.writeLine(JSONRPCLine.result(id: id, body: toolsListResult()))

        case BridgeMethod.ping:
            // Ping carries no information the app owns, so answering it locally is not a
            // degradation: a client pings to learn the server is alive, and it is.
            output.writeLine(JSONRPCLine.result(id: id, body: Data("{}".utf8)))

        case BridgeMethod.toolsCall:
            output.writeLine(JSONRPCLine.result(
                id: id,
                body: JSONRPCLine.toolErrorResult(text: BridgeDefaults.unavailableToolText)
            ))

        default:
            output.writeLine(JSONRPCLine.failure(
                id: id,
                code: BridgeErrorCode.unavailable,
                message: BridgeDefaults.unavailableMethodMessage(message.method)
            ))
        }
    }

    /// The cached `initialize` result with the client's protocol version substituted, or a
    /// synthesised one saying why the tool list will be empty.
    ///
    /// The version is echoed rather than repeated from the cache because it is a negotiation
    /// between *these two* peers: replaying what some earlier client agreed to would answer a
    /// question this client did not ask.
    private func initializeResult(protocolVersion requested: String?) -> Data {
        let version = requested ?? BridgeDefaults.protocolVersion

        if let cached = stateLock.withLock({ snapshot.initializeResult }),
           var object = try? JSONSerialization.jsonObject(with: cached) as? [String: Any] {
            object["protocolVersion"] = version
            // Version-one caches may predate the server's listChanged declaration. The bridge
            // itself already forwards and synthesises that notification, so advertise the
            // capability even when the last cached handshake did not.
            var capabilities = object["capabilities"] as? [String: Any] ?? [:]
            var tools = capabilities["tools"] as? [String: Any] ?? [:]
            tools["listChanged"] = true
            capabilities["tools"] = tools
            object["capabilities"] = capabilities
            if let data = JSONRPCLine.encode(object: object) { return data }
        }

        let synthesised: [String: Any] = [
            "protocolVersion": version,
            "capabilities": ["tools": ["listChanged": true]],
            "serverInfo": ["name": BridgeDefaults.serverName, "version": BridgeDefaults.serverVersion],
            "instructions": BridgeDefaults.unavailableInstructions
        ]
        return JSONRPCLine.encode(object: synthesised) ?? Data("{}".utf8)
    }

    /// The cached tool list, or an empty one. Empty rather than invented: see the drift rule.
    private func toolsListResult() -> Data {
        stateLock.withLock { snapshot.toolsListResult } ?? Data(#"{"tools":[]}"#.utf8)
    }

    // MARK: - Private Methods — the event stream

    /// Holds `GET /mcp/<token>` open, writes every pushed event to stdout, and reconnects.
    ///
    /// The stream is what carries the app's own `notifications/tools/list_changed` — a grant
    /// changing a running session's tool list — and it is also how the bridge learns the app came
    /// back. Both are the same connection, so there is one thing to keep alive rather than two.
    private func runEventStream() {
        var delay = BridgeDefaults.reconnectInitialDelay

        while !stateLock.withLock({ isStopping }) {
            do {
                let connection = try UnixSocketConnection(path: arguments.socketPath)
                defer {
                    connection.close()
                    stateLock.withLock { eventStream = nil }
                }
                stateLock.withLock { eventStream = connection }

                try connection.send(UnixHTTPRequest.get(
                    path: arguments.endpointPath,
                    accept: BridgeDefaults.eventStreamAccept
                ))
                let head = try connection.readHead()
                guard head.status == Self.okStatus, head.isEventStream else {
                    throw UnixHTTPError.unexpectedStatus(head.status)
                }

                delay = BridgeDefaults.reconnectInitialDelay
                announceToolsListChangedIfNeeded()

                var reader = ServerSentEventReader()
                while let bytes = try connection.nextBytes() {
                    reader.consume(
                        bytes,
                        emit: { [output] payload in output.writeLine(payload) },
                        report: { [output] reason in output.diagnose(reason) }
                    )
                }
                // A clean end of stream is the app going away, and is a loss like any other.
                markUnreachable()
                output.diagnose("the event stream ended")
            } catch {
                markUnreachable()
                output.diagnose("the event stream could not be held open: \(error)")
            }

            guard !stateLock.withLock({ isStopping }) else { return }
            Thread.sleep(forTimeInterval: delay)
            delay = min(
                delay * BridgeDefaults.reconnectBackoffFactor,
                BridgeDefaults.reconnectMaximumDelay
            )
        }
    }

    /// Records that the app was unreachable, so the next connect tells the client to re-list.
    private func markUnreachable() {
        stateLock.withLock { announceOnNextConnect = true }
    }

    /// Writes `notifications/tools/list_changed` if anything was missed while the app was away.
    ///
    /// Not written on the *first* connect of a bridge that never lost contact: the client has
    /// just listed tools, and telling it to list them again would be noise. It is written on
    /// every connect that follows a failure — a dropped stream, a connect that did not land, or
    /// a request answered locally — because in all three the client's list may be wrong.
    private func announceToolsListChangedIfNeeded() {
        let shouldAnnounce: Bool = stateLock.withLock {
            defer { announceOnNextConnect = false }
            return announceOnNextConnect
        }
        guard shouldAnnounce else { return }
        output.writeLine(BridgeMethod.toolsListChangedNotification)
    }

    // MARK: - Private Methods — shutdown

    /// Ends the event stream so the app sees the disconnect now rather than at process exit.
    ///
    /// `shutdownReads` rather than `close`: the stream thread may be blocked in `read` on that
    /// descriptor, and closing a descriptor number another thread is using is how a socket ends
    /// up being read by the wrong owner.
    private func stop() {
        let connection: UnixSocketConnection? = stateLock.withLock {
            isStopping = true
            return eventStream
        }
        connection?.shutdownReads()
        _ = scheduled.wait(timeout: .now() + BridgeDefaults.shutdownDrainTimeout)
    }

    // MARK: - Constants

    private static let standardInput: Int32 = 0
    private static let lineFeed: UInt8 = 0x0A
    private static let okStatus = 200
    private static let acceptedStatus = 202

    private static func isBlank(_ line: Data) -> Bool {
        line.allSatisfy { $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }
    }
}

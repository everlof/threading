import Foundation
import Network

/// An MCP server exposing Skalman's own UI to the agents it launches.
///
/// Agents run in a terminal, which can only render text. This server is the way back out of
/// that constraint: an agent calls a tool, and the app it is running inside draws the result
/// natively. The terminal stays the input surface; the panel becomes the output surface for
/// anything the terminal renders badly.
///
/// Every session gets its own endpoint URL (see `MCPSessionRegistry`), so a call arrives
/// already attributed to the session that made it.
final class MCPServer {

    // MARK: - Singleton

    static let shared = MCPServer()
    private init() {}

    // MARK: - Properties

    /// Handles tool calls. Set by the app delegate once the window exists.
    weak var handler: MCPToolHandling?

    /// The listening port, or nil until the listener is ready. Launches read this to decide
    /// whether to register the server at all.
    private(set) var port: UInt16?

    private var listener: NWListener?
    private var connectionsByID: [ObjectIdentifier: MCPConnection] = [:]

    private let queue = DispatchQueue(label: "com.skalman.mcp", qos: .userInitiated)

    // MARK: - Public Methods

    /// Binds a loopback port and starts listening.
    ///
    /// `completion` runs once the outcome is known, ready or failed, so startup can proceed
    /// either way — a session launched without a port simply gets no MCP server, rather than
    /// not launching.
    func start(completion: @escaping () -> Void) {
        guard listener == nil else {
            completion()
            return
        }

        var hasCompleted = false
        let finish = {
            guard !hasCompleted else { return }
            hasCompleted = true
            DispatchQueue.main.async(execute: completion)
        }

        do {
            // Bound to loopback specifically, not `.any`: the endpoint is guarded only by its
            // per-session token and must not be reachable from the network.
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(
                host: NWEndpoint.Host(MCPDefaults.host),
                port: .any
            )
            parameters.allowLocalEndpointReuse = true

            let listener = try NWListener(using: parameters)
            self.listener = listener

            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.port = listener.port?.rawValue
                    SkalmanLogger.mcp.info("MCP server listening on port \(listener.port?.rawValue ?? 0)")
                    finish()

                case .failed(let error):
                    SkalmanLogger.mcp.error("MCP server failed: \(error.localizedDescription)")
                    self?.port = nil
                    finish()

                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }

            listener.start(queue: queue)
        } catch {
            SkalmanLogger.mcp.error("MCP server could not start: \(error.localizedDescription)")
            finish()
        }
    }

    func stop() {
        for connection in connectionsByID.values {
            connection.cancel()
        }
        connectionsByID.removeAll()

        listener?.cancel()
        listener = nil
        port = nil
    }

    // MARK: - Private Methods

    private func accept(_ nwConnection: NWConnection) {
        let connection = MCPConnection(
            connection: nwConnection,
            queue: queue,
            handler: { [weak self] request, respond in
                self?.route(request, respond: respond)
            },
            onClose: { [weak self] closed in
                self?.connectionsByID.removeValue(forKey: ObjectIdentifier(closed))
            }
        )

        connectionsByID[ObjectIdentifier(connection)] = connection
        connection.start()
    }

    /// Resolves the request's session and hands the JSON-RPC message on.
    private func route(_ request: HTTPRequest, respond: @escaping (HTTPResponse) -> Void) {
        guard request.method == "POST" else {
            // GET opens the optional server-to-client SSE stream, which this server does not
            // offer. The spec allows refusing it outright.
            respond(.status(405, "Method Not Allowed"))
            return
        }

        // Permission requests share the listener and the session tokens, but not the
        // protocol: they come from a `PreToolUse` hook, which speaks plain JSON.
        if request.path.hasPrefix(MCPDefaults.permissionPathPrefix) {
            let token = String(request.path.dropFirst(MCPDefaults.permissionPathPrefix.count))
            routePermission(request, token: token, respond: respond)
            return
        }

        guard request.path.hasPrefix(MCPDefaults.pathPrefix) else {
            respond(.status(404, "Not Found"))
            return
        }

        let token = String(request.path.dropFirst(MCPDefaults.pathPrefix.count))
        guard let sessionID = MCPSessionRegistry.session(forToken: token) else {
            respond(.status(404, "Not Found"))
            return
        }

        guard let message = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
            respond(.json(Self.errorResponse(id: nil, code: -32700, message: "Parse error")))
            return
        }

        handle(message, for: sessionID) { reply in
            guard let reply else {
                respond(.accepted)
                return
            }

            guard let data = try? JSONSerialization.data(withJSONObject: reply) else {
                respond(.status(500, "Internal Server Error"))
                return
            }

            respond(.json(data))
        }
    }

    // MARK: - Permissions

    /// Answers a `PreToolUse` hook asking whether a tool may run.
    ///
    /// The hook blocks on this response, so the connection is deliberately held open while
    /// the user decides — that pause *is* the permission prompt. Anything that cannot be
    /// resolved is denied rather than left hanging, since a hook waiting forever would wedge
    /// the session with no visible cause.
    private func routePermission(
        _ request: HTTPRequest,
        token: String,
        respond: @escaping (HTTPResponse) -> Void
    ) {
        func reply(_ decision: PermissionDecision) {
            let data = (try? JSONSerialization.data(withJSONObject: decision.hookResponse)) ?? Data()
            respond(.json(data))
        }

        guard let sessionID = MCPSessionRegistry.session(forToken: token) else {
            respond(.status(404, "Not Found"))
            return
        }

        guard let hook = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let toolName = hook["tool_name"] as? String else {
            reply(.deny(reason: "Skalman could not read the permission request."))
            return
        }

        let permissionRequest = PermissionRequest(
            sessionID: sessionID,
            toolName: toolName,
            input: hook["tool_input"] as? [String: Any] ?? [:]
        )

        DispatchQueue.main.async {
            PermissionBroker.decide(permissionRequest) { decision in
                SkalmanLogger.mcp.info("permission \(toolName) for \(sessionID): \(String(describing: decision))")
                reply(decision)
            }
        }
    }

    // MARK: - JSON-RPC

    /// Dispatches one JSON-RPC message, calling back with the reply, or nil for notifications.
    private func handle(
        _ message: [String: Any],
        for sessionID: UUID,
        completion: @escaping ([String: Any]?) -> Void
    ) {
        let method = message["method"] as? String ?? ""
        let id = message["id"]

        // No id means a notification: acknowledged at the transport level, never answered.
        guard let id else {
            completion(nil)
            return
        }

        switch method {
        case "initialize":
            let params = message["params"] as? [String: Any]
            let clientVersion = params?["protocolVersion"] as? String
            let base = MCPToolCatalog.instructions

            // The panel-state addendum reads the display store through the handler, which is
            // main-queue bound; everything else in the response is static. The connection is held
            // until the hop returns, which the client already expects for `initialize`.
            DispatchQueue.main.async { [weak self] in
                let addendum = self?.handler?.panelState(for: sessionID) ?? ""

                completion(Self.result(id: id, [
                    // Echoed back when the client names one, so a client on an older revision is
                    // not refused over a difference this server does not actually depend on.
                    "protocolVersion": clientVersion ?? MCPDefaults.protocolVersion,
                    "capabilities": ["tools": [:] as [String: Any]],
                    "serverInfo": [
                        "name": MCPDefaults.serverName,
                        "version": MCPDefaults.serverVersion
                    ],
                    "instructions": base + addendum
                ]))
            }

        case "ping":
            completion(Self.result(id: id, [:]))

        case "tools/list":
            completion(Self.result(id: id, ["tools": MCPToolCatalog.enabledDefinitions]))

        case "tools/call":
            callTool(message, id: id, for: sessionID, completion: completion)

        default:
            completion(Self.error(id: id, code: -32601, message: "Method not found: \(method)"))
        }
    }

    private func callTool(
        _ message: [String: Any],
        id: Any,
        for sessionID: UUID,
        completion: @escaping ([String: Any]?) -> Void
    ) {
        guard let params = message["params"] as? [String: Any],
              let name = params["name"] as? String else {
            completion(Self.error(id: id, code: -32602, message: "Invalid params"))
            return
        }

        let call = MCPToolCall(
            name: name,
            arguments: params["arguments"] as? [String: Any] ?? [:]
        )

        // The handler touches AppKit and the model layer, neither of which is thread-safe.
        DispatchQueue.main.async { [weak self] in
            guard let handler = self?.handler else {
                completion(Self.result(
                    id: id,
                    MCPToolResult.failure("Skalman is not ready to display content.").payload
                ))
                return
            }

            // Completion-based, since some tools (a page load, a DOM query) finish asynchronously.
            handler.handle(call, for: sessionID) { result in
                SkalmanLogger.mcp.info("tools/call \(name) for \(sessionID): isError=\(result.isError)")

                // A failing tool reports through `isError` in the result, not a protocol error:
                // the call itself succeeded, and the agent should see why it did not work.
                completion(Self.result(id: id, result.payload))
            }
        }
    }

    // MARK: - Message Construction

    private static func result(id: Any, _ value: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": value]
    }

    private static func error(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    private static func errorResponse(id: Any?, code: Int, message: String) -> Data {
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id ?? NSNull(),
            "error": ["code": code, "message": message]
        ]
        return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
    }
}

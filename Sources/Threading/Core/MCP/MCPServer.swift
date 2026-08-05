import Foundation
import Network
import os

// MARK: - JSON-RPC Wire Types

/// JSON-RPC permits integer, string, and explicit null identifiers. A missing identifier is
/// represented separately by `JSONRPCRequest.id == nil`, because it marks a notification.
enum RequestID: Codable, Equatable, Sendable {
    case integer(Int64)
    case string(String)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let integer = try? container.decode(Int64.self) {
            self = .integer(integer)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .integer(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var auditValue: String {
        switch self {
        case .integer(let value): return String(value)
        case .string(let value): return value
        case .null: return "null"
        }
    }
}

struct JSONRPCRequest: Decodable, Sendable {
    enum Parameters: Sendable {
        case initialize(InitializeParameters)
        case toolCall(MCPToolCall)
        case invalid
        case none
    }

    let jsonrpc: String
    let id: RequestID?
    let method: String
    let parameters: Parameters
    let rawParameters: JSONValue?

    private enum CodingKeys: String, CodingKey {
        case jsonrpc, id, method, params
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        jsonrpc = try container.decodeIfPresent(String.self, forKey: .jsonrpc) ?? "2.0"
        method = try container.decode(String.self, forKey: .method)
        id = container.contains(.id)
            ? try container.decode(RequestID.self, forKey: .id)
            : nil
        rawParameters = try? container.decode(JSONValue.self, forKey: .params)

        switch method {
        case "initialize":
            let value = try? container.decode(InitializeParameters.self, forKey: .params)
            parameters = .initialize(value ?? InitializeParameters(protocolVersion: nil))
        case "tools/call":
            do {
                let value = try container.decode(MCPToolCallParameters.self, forKey: .params)
                parameters = .toolCall(value.call)
            } catch {
                parameters = .invalid
            }
        default:
            parameters = .none
        }
    }
}

struct InitializeParameters: Decodable, Sendable {
    let protocolVersion: String?
}

struct EmptyJSONObject: Encodable, Sendable {}

struct InitializeResult: Encodable, Sendable {
    struct Capabilities: Encodable, Sendable {
        let tools = EmptyJSONObject()
    }

    struct ServerInfo: Encodable, Sendable {
        let name: String
        let version: String
    }

    let protocolVersion: String
    let capabilities = Capabilities()
    let serverInfo: ServerInfo
    let instructions: String
}

struct ToolsListResult: Encodable, Sendable {
    let tools: [MCPToolDefinition]
}

struct JSONRPCError: Encodable, Equatable, Sendable {
    let code: Int
    let message: String
}

enum JSONRPCResult: Encodable, Sendable {
    case initialize(InitializeResult)
    case empty(EmptyJSONObject)
    case toolsList(ToolsListResult)
    case tool(MCPToolResult)

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .initialize(let value): try container.encode(value)
        case .empty(let value): try container.encode(value)
        case .toolsList(let value): try container.encode(value)
        case .tool(let value): try container.encode(value)
        }
    }
}

struct JSONRPCResponse: Encodable, Sendable {
    let jsonrpc = "2.0"
    let id: RequestID
    let result: JSONRPCResult?
    let error: JSONRPCError?

    static func success(id: RequestID, result: JSONRPCResult) -> JSONRPCResponse {
        JSONRPCResponse(id: id, result: result, error: nil)
    }

    static func failure(id: RequestID, code: Int, message: String) -> JSONRPCResponse {
        JSONRPCResponse(
            id: id,
            result: nil,
            error: JSONRPCError(code: code, message: message)
        )
    }
}

/// An MCP server exposing Threading's own UI to the agents it launches.
///
/// Agents run in a terminal, which can only render text. This server is the way back out of
/// that constraint: an agent calls a tool, and the app it is running inside draws the result
/// natively. The terminal stays the input surface; the panel becomes the output surface for
/// anything the terminal renders badly.
///
/// Every session gets its own endpoint URL (see `MCPSessionRegistry`), so a call arrives
/// already attributed to the session that made it.
/// `listener` and `connectionsByID` are confined to `queue`; the handler is touched only after
/// hopping to main, and the one cross-queue value (`port`) has its own lock.
final class MCPServer: @unchecked Sendable {

    // MARK: - Singleton

    static let shared = MCPServer()
    private init() {}

    // MARK: - Properties

    /// Handles tool calls. Set by the app delegate once the window exists.
    @MainActor weak var handler: AgentCommandHandling?

    /// The listening port, or nil until the listener is ready. Launches read this to decide
    /// whether to register the server at all.
    var port: UInt16? {
        portStorage.withLock { $0 }
    }

    private let portStorage = OSAllocatedUnfairLock<UInt16?>(initialState: nil)

    private var listener: NWListener?
    private var connectionsByID: [ObjectIdentifier: MCPConnection] = [:]

    private let queue = DispatchQueue(label: "codes.threading.mcp", qos: .userInitiated)

    // MARK: - Public Methods

    /// Binds a loopback port and starts listening.
    ///
    /// `completion` runs once the outcome is known, ready or failed, so startup can proceed
    /// either way — a session launched without a port simply gets no MCP server, rather than
    /// not launching.
    @MainActor
    func start(completion: @escaping @MainActor @Sendable () -> Void) {
        guard listener == nil else {
            completion()
            return
        }

        let completionState = OSAllocatedUnfairLock<Bool>(initialState: false)
        let finish: @Sendable () -> Void = {
            let shouldFinish = completionState.withLock { hasCompleted in
                guard !hasCompleted else { return false }
                hasCompleted = true
                return true
            }
            guard shouldFinish else { return }
            Task { @MainActor in completion() }
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
                    self?.portStorage.withLock { $0 = listener.port?.rawValue }
                    ThreadingLogger.mcp.info("MCP server listening on port \(listener.port?.rawValue ?? 0)")
                    finish()

                case .failed(let error):
                    ThreadingLogger.mcp.error("MCP server failed: \(error.localizedDescription)")
                    self?.portStorage.withLock { $0 = nil }
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
            ThreadingLogger.mcp.error("MCP server could not start: \(error.localizedDescription)")
            finish()
        }
    }

    @MainActor
    func stop() {
        // Connections are accepted and removed on `queue`; perform shutdown there as well.
        // Synchronous dispatch preserves the app-termination contract: when this returns, the
        // listener and every tracked connection have received cancellation.
        queue.sync {
            for connection in connectionsByID.values {
                connection.cancel()
            }
            connectionsByID.removeAll()

            listener?.cancel()
            listener = nil
            portStorage.withLock { $0 = nil }
        }
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
    private func route(
        _ request: HTTPRequest,
        respond: @escaping @Sendable (HTTPResponse) -> Void
    ) {
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

        if request.path.hasPrefix(MCPDefaults.lifecyclePathPrefix) {
            routeLifecycle(request, respond: respond)
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

        let message: JSONRPCRequest
        do {
            message = try JSONDecoder().decode(JSONRPCRequest.self, from: request.body)
        } catch DecodingError.dataCorrupted {
            respond(.json(Self.errorResponse(id: nil, code: -32700, message: "Parse error")))
            return
        } catch {
            respond(.json(Self.errorResponse(id: nil, code: -32600, message: "Invalid Request")))
            return
        }

        handle(message, for: sessionID) { reply in
            guard let reply else {
                respond(.accepted)
                return
            }

            guard let data = try? JSONEncoder().encode(reply) else {
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
        respond: @escaping @Sendable (HTTPResponse) -> Void
    ) {
        @Sendable func reply(_ decision: PermissionDecision) {
            let data = (try? JSONSerialization.data(withJSONObject: decision.hookResponse)) ?? Data()
            respond(.json(data))
        }

        guard let sessionID = MCPSessionRegistry.session(forToken: token) else {
            respond(.status(404, "Not Found"))
            return
        }

        guard let hook = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let toolName = hook["tool_name"] as? String else {
            reply(.deny(reason: "Threading could not read the permission request."))
            return
        }

        let rawInput = hook["tool_input"] ?? [String: Any]()
        guard let foundationInput = rawInput as? [String: Any],
              let input = JSONValue.object(from: foundationInput) else {
            reply(.deny(reason: "Threading refused malformed tool arguments."))
            return
        }

        let permissionRequest = PermissionRequest(
            sessionID: sessionID,
            toolName: toolName,
            input: input
        )

        DispatchQueue.main.async {
            PermissionBroker.decide(permissionRequest) { decision in
                ThreadingLogger.mcp.info("permission \(toolName) for \(sessionID): \(String(describing: decision))")
                reply(decision)
            }
        }
    }

    // MARK: - JSON-RPC

    /// Dispatches one JSON-RPC message, calling back with the reply, or nil for notifications.
    private func handle(
        _ message: JSONRPCRequest,
        for sessionID: SessionID,
        completion: @escaping @Sendable (JSONRPCResponse?) -> Void
    ) {
        // No id means a notification: acknowledged at the transport level, never answered.
        guard let id = message.id else {
            completion(nil)
            return
        }

        switch message.method {
        case "initialize":
            guard case .initialize(let params) = message.parameters else {
                completion(Self.error(id: id, code: -32602, message: "Invalid params"))
                return
            }

            // The panel-state addendum reads the display store through the handler, which is
            // main-queue bound; enabled-tool settings share that isolation. The connection is
            // held until the hop returns, which the client already expects for `initialize`.
            // A scoped ad-hoc endpoint gets its scope's instructions and no panel addendum —
            // a helper run has no panel for the addendum to describe.
            DispatchQueue.main.async { [weak self] in
                let scope = MCPSessionRegistry.adHocScope(for: sessionID)
                let base = scope.map(MCPToolCatalog.scopedInstructions)
                    ?? MCPToolCatalog.instructions
                let addendum = scope == nil
                    ? (self?.handler?.panelState(for: sessionID) ?? "")
                    : ""

                completion(Self.result(
                    id: id,
                    .initialize(InitializeResult(
                        // Echoed back when the client names one, so a client on an older revision
                        // is not refused over a difference this server does not depend on.
                        protocolVersion: params.protocolVersion ?? MCPDefaults.protocolVersion,
                        serverInfo: InitializeResult.ServerInfo(
                            name: MCPDefaults.serverName,
                            version: MCPDefaults.serverVersion
                        ),
                        instructions: base + addendum
                    ))
                ))
            }

        case "ping":
            completion(Self.result(id: id, .empty(EmptyJSONObject())))

        case "tools/list":
            DispatchQueue.main.async {
                let tools = MCPSessionRegistry.adHocScope(for: sessionID)
                    .map(MCPToolCatalog.scopedDefinitions)
                    ?? MCPToolCatalog.enabledDefinitions
                completion(Self.result(
                    id: id,
                    .toolsList(ToolsListResult(tools: tools))
                ))
            }

        case "tools/call":
            guard case .toolCall(let call) = message.parameters else {
                completion(Self.error(id: id, code: -32602, message: "Invalid params"))
                return
            }
            let input = message.rawParameters?.objectValue?["arguments"] ?? .object([:])
            ExecutionAuditStore.shared.recordToolRequest(
                sessionID: sessionID,
                source: .threadingMCP,
                provider: nil,
                operation: call.name,
                callID: id.auditValue,
                input: input,
                fidelity: .exact
            )
            callTool(call, id: id, for: sessionID, completion: completion)

        default:
            completion(Self.error(
                id: id,
                code: -32601,
                message: "Method not found: \(message.method)"
            ))
        }
    }

    private func callTool(
        _ call: AgentCommand,
        id: RequestID,
        for sessionID: SessionID,
        completion: @escaping @Sendable (JSONRPCResponse?) -> Void
    ) {
        // The handler touches AppKit and the model layer, neither of which is thread-safe.
        DispatchQueue.main.async { [weak self] in
            let finish: @MainActor (MCPToolResult) -> Void = { result in
                let encoded = (try? JSONEncoder().encode(result))
                    .flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
                    ?? .object(["isError": .bool(result.isError), "content": .string(result.text)])
                ExecutionAuditStore.shared.recordToolResult(
                    sessionID: sessionID,
                    source: .threadingMCP,
                    provider: nil,
                    operation: call.name,
                    callID: id.auditValue,
                    output: encoded,
                    isError: result.isError,
                    fidelity: .exact
                )
                completion(Self.result(id: id, .tool(result)))
            }
            // Inside a scope, `tools/list` and admission must agree exactly as they do
            // globally, so both derive from the same scoped definitions.
            let admitted: Bool
            if let scope = MCPSessionRegistry.adHocScope(for: sessionID) {
                admitted = MCPToolCatalog.scopedAdmits(call, allowedTools: scope)
            } else {
                admitted = MCPToolCatalog.admits(call)
            }
            guard admitted else {
                finish(.failure("Tool \(call.name) is unavailable or disabled in Threading."))
                return
            }
            guard let handler = self?.handler else {
                finish(.failure("Threading is not ready to display content."))
                return
            }

            // Completion-based, since some tools (a page load, a DOM query) finish asynchronously.
            handler.handle(call, for: sessionID) { result in
                ThreadingLogger.mcp.info("tools/call \(call.name) for \(sessionID): isError=\(result.isError)")

                // A failing tool reports through `isError` in the result, not a protocol error:
                // the call itself succeeded, and the agent should see why it did not work.
                finish(result)
            }
        }
    }

    // MARK: - Message Construction

    private static func result(id: RequestID, _ value: JSONRPCResult) -> JSONRPCResponse {
        .success(id: id, result: value)
    }

    private static func error(id: RequestID, code: Int, message: String) -> JSONRPCResponse {
        .failure(id: id, code: code, message: message)
    }

    private static func errorResponse(id: RequestID?, code: Int, message: String) -> Data {
        let response = JSONRPCResponse.failure(
            id: id ?? .null,
            code: code,
            message: message
        )
        return (try? JSONEncoder().encode(response)) ?? Data()
    }
}

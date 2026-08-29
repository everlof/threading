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

        var toolCall: MCPToolCall? {
            guard case .toolCall(let command) = self else { return nil }
            return command
        }
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
/// hopping to main, and the cross-queue values (`port`, `socketPath`) have their own locks.
///
/// **Two endpoints, one handler.** A loopback TCP port carries `--mcp-config`, because a CLI
/// resolves that URL itself and cannot be handed a socket. Hooks prefer a unix socket in an
/// owner-only directory, because a hook command is *ours* and a socket path is the one address
/// that survives a restart; they retry TCP when it is unavailable. Both accept requests through the same
/// `MCPConnection`, which speaks HTTP over an `NWConnection` and neither knows nor cares which
/// transport carried it. The TCP endpoint retires once the stdio shim replaces `--mcp-config`.
final class MCPServer: @unchecked Sendable {

    static let toolsListChangedEvent = Data("""
        event: message
        data: {"jsonrpc":"2.0","method":"notifications/tools/list_changed"}


        """.utf8)

    // MARK: - Singleton

    static let shared = MCPServer()

    /// `configuredSocketPath` overrides the per-user rendezvous, which is how a test binds a
    /// socket of its own — including one deliberately too long to bind, to prove that the TCP
    /// listener still comes up beside it.
    init(socketPath: String? = nil) {
        configuredSocketPath = socketPath
        grantObserver = NotificationCenter.default.addObserver(
            forName: ControlGrantsDidChange.name,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let event = notification.object as? ControlGrantsDidChange else { return }
            self?.queue.async { [weak self] in
                self?.sendToolsListChanged(to: event.sessionID)
            }
        }
    }

    deinit {
        if let grantObserver {
            NotificationCenter.default.removeObserver(grantObserver)
        }
    }

    // MARK: - Properties

    /// Handles tool calls. Set by the app delegate once the window exists.
    @MainActor weak var handler: AgentCommandHandling?

    /// Lifecycle endpoints resolve their checkpoint store lazily so unit and process fixtures
    /// can use isolated persistence without opening or mutating the user's Application Support
    /// file. Production keeps the app-wide durable store.
    @MainActor var gitTurnCheckpointStoreProvider: @MainActor () -> GitTurnBaselineStore = {
        .shared
    }

    /// The listening port, or nil until the listener is ready. Launches read this to decide
    /// whether to register the server at all.
    var port: UInt16? {
        portStorage.withLock { $0 }
    }

    private let portStorage = OSAllocatedUnfairLock<UInt16?>(initialState: nil)

    /// The unix rendezvous this server is bound to, or nil when it is not listening on one.
    ///
    /// Deliberately not the address hooks receive as their preferred route — that is
    /// `MCPBridgeLocation.socketPath`, which answers before anything binds. This says what the
    /// listener actually got, and is the only value allowed to select the stdio bridge.
    var socketPath: String? {
        socketPathStorage.withLock { $0 }
    }

    private let socketPathStorage = OSAllocatedUnfairLock<String?>(initialState: nil)

    /// The path this server was asked to bind, or nil for the per-user default.
    private let configuredSocketPath: String?

    private var listener: NWListener?
    private var socketListener: NWListener?
    private var connectionsByID: [ObjectIdentifier: MCPConnection] = [:]
    private var eventStreamSessionByConnection: [ObjectIdentifier: SessionID] = [:]
    private var grantObserver: NSObjectProtocol? = nil

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

        struct StartupState {
            var tcpSettled = false
            var socketSettled = false
            var completionDelivered = false
        }
        let completionState = OSAllocatedUnfairLock(initialState: StartupState())
        let settle: @Sendable (_ tcp: Bool) -> Void = { tcp in
            let shouldFinish = completionState.withLock { state in
                if tcp { state.tcpSettled = true } else { state.socketSettled = true }
                guard state.tcpSettled, state.socketSettled, !state.completionDelivered else {
                    return false
                }
                state.completionDelivered = true
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
            ThreadingLogger.mcp.info(
                "MCP server listening on port \(listener.port?.rawValue ?? 0, privacy: .public)"
            )
                    settle(true)

                case .failed(let error):
            ThreadingLogger.mcp.error(
                "MCP server failed: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
                    self?.portStorage.withLock { $0 = nil }
                    settle(true)

                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }

            listener.start(queue: queue)
        } catch {
            ThreadingLogger.mcp.error(
                "MCP server could not start: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            settle(true)
        }

        // A launch chooses stdio only from the path this listener actually published. Waiting for
        // the outcome, not for success, keeps failure non-blocking while making the transport
        // decision truthful.
        startSocketListener { settle(false) }
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
            eventStreamSessionByConnection.removeAll()

            listener?.cancel()
            listener = nil
            portStorage.withLock { $0 = nil }

            socketListener?.cancel()
            socketListener = nil
            // The file outlives the listener, so it is removed here rather than left for the
            // next launch to trip over. A launch unlinks it again anyway, because a crash never
            // reaches this line.
            let boundPath = socketPathStorage.withLock { path -> String? in
                let bound = path
                path = nil
                return bound
            }
            if let boundPath { unlinkStaleSocket(at: boundPath) }
        }
    }

    // MARK: - Unix Rendezvous

    /// Binds the stable per-user socket beside the loopback port.
    ///
    /// Everything here degrades rather than fails. A path too long for `sun_path`, a directory
    /// that cannot be created, a bind that is refused — each logs and returns, leaving the TCP
    /// listener carrying the whole surface exactly as it did before this endpoint existed.
    @MainActor
    private func startSocketListener(settled: @escaping @Sendable () -> Void) {
        guard socketListener == nil else {
            settled()
            return
        }

        let settledState = OSAllocatedUnfairLock<Bool>(initialState: false)
        let finish: @Sendable () -> Void = {
            let shouldFinish = settledState.withLock { delivered in
                guard !delivered else { return false }
                delivered = true
                return true
            }
            if shouldFinish { settled() }
        }

        let requested = configuredSocketPath ?? MCPBridgeLocation.socketPath
        guard let path = MCPBridgeLocation.addressableSocketPath(requested) else {
            finish()
            return
        }

        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        guard MCPBridgeLocation.prepareDirectory(directory) else {
            finish()
            return
        }

        // A bind fails outright against a leftover file, and after a crash there is always one.
        // Removing it is safe because `SingleInstanceLock` means the only process that could be
        // listening on this path is this one.
        unlinkStaleSocket(at: path)

        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .unix(path: path)
            parameters.allowLocalEndpointReuse = true

            let listener = try NWListener(using: parameters)
            socketListener = listener

            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.socketPathStorage.withLock { $0 = path }
                    ThreadingLogger.mcp.info("MCP server listening on its unix rendezvous")
                    finish()

                case .failed(let error):
                    ThreadingLogger.mcp.error(
                        "MCP unix listener failed: \(error.localizedDescription, privacy: .private(mask: .hash))"
                    )
                    self?.socketPathStorage.withLock { $0 = nil }
                    finish()

                case .cancelled:
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
            ThreadingLogger.mcp.error(
                "MCP unix listener could not start: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            socketListener = nil
            finish()
        }
    }

    private func unlinkStaleSocket(at path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        try? FileManager.default.removeItem(atPath: path)
    }

    // MARK: - Private Methods

    private func accept(_ nwConnection: NWConnection) {
        let connection = MCPConnection(
            connection: nwConnection,
            queue: queue,
            handler: { [weak self] connection, request, respond in
                self?.route(request, connection: connection, respond: respond)
            },
            onClose: { [weak self] closed in
                let identifier = ObjectIdentifier(closed)
                self?.connectionsByID.removeValue(forKey: identifier)
                self?.eventStreamSessionByConnection.removeValue(forKey: identifier)
            }
        )

        connectionsByID[ObjectIdentifier(connection)] = connection
        connection.start()
    }

    /// Resolves the request's session and hands the JSON-RPC message on.
    private func route(
        _ request: HTTPRequest,
        connection: MCPConnection,
        respond: @escaping @Sendable (HTTPResponse) -> Void
    ) {
        if request.method == "GET" {
            guard request.path.hasPrefix(MCPDefaults.pathPrefix) else {
                respond(.status(404, "Not Found"))
                return
            }
            let token = String(request.path.dropFirst(MCPDefaults.pathPrefix.count))
            guard let sessionID = MCPSessionRegistry.session(forToken: token),
                  request.header("accept")?.contains("text/event-stream") == true else {
                respond(.status(404, "Not Found"))
                return
            }
            eventStreamSessionByConnection[ObjectIdentifier(connection)] = sessionID
            respond(.eventStream)
            return
        }
        guard request.method == "POST" else {
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

        if request.path.hasPrefix(MCPDefaults.runProgressPathPrefix) {
            routeRunProgress(request, respond: respond)
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

    private func sendToolsListChanged(to sessionID: SessionID) {
        for (identifier, owner) in eventStreamSessionByConnection where owner == sessionID {
            connectionsByID[identifier]?.sendServerEvent(Self.toolsListChangedEvent)
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

        // Deliberately all-or-nothing, for the same reason as Codex's approval request: the
        // arguments below are what the broker shows the user, and what the user's answer then
        // permits. Approving a partially decoded `Bash` call is worse than refusing it, so a
        // container that will not convert is denied whole — visibly, with a reason the hook
        // reports — rather than repaired into a request nobody actually consented to.
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
        ThreadingLogger.mcp.info(
            "permission \(toolName, privacy: .public) for \(sessionID, privacy: .public): \(String(describing: decision), privacy: .public)"
        )
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
                    ?? MCPToolCatalog.instructions(for: sessionID)
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
                    ?? MCPToolCatalog.definitions(for: sessionID)
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
                admitted = MCPToolCatalog.admits(call, for: sessionID)
            }
            guard admitted else {
                finish(.failure("Tool \(call.name) is unavailable or disabled in Threading."))
                return
            }
            guard let handler = self?.handler else {
                finish(.failure("Threading is not ready to display content."))
                return
            }

            let complete: @MainActor @Sendable (MCPToolResult) -> Void = { result in
        ThreadingLogger.mcp.info(
            "tools/call \(call.name, privacy: .public) for \(sessionID, privacy: .public): isError=\(result.isError, privacy: .public)"
        )

                // A failing tool reports through `isError` in the result, not a protocol error:
                // the call itself succeeded, and the agent should see why it did not work.
                finish(result)
            }

            // Built-ins execute through the same descriptor that decoded and advertised them.
            // External tools remain open-ended and retain their JSON value at the provider edge.
            if let tool = call.builtInTool {
                guard let descriptor = MCPBuiltInToolRegistry.descriptor(for: tool) else {
                    finish(.failure("Tool \(call.name) has no complete built-in descriptor."))
                    return
                }
                descriptor.execution.execute(
                    call,
                    with: handler,
                    for: sessionID,
                    completion: complete
                )
            } else {
                guard let arguments = call.externalArguments else {
                    finish(.failure("External tool \(call.name) has no arguments payload."))
                    return
                }
                handler.handleExternalTool(
                    named: call.name,
                    arguments: arguments,
                    for: sessionID,
                    completion: complete
                )
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

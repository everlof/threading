import Foundation
import ThreadingController
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// MARK: - Wire

/// One agent tool call, on one connection: a single JSON line in, a single JSON line out. The
/// caller is named by exactly one of `execution` or `mailbox` and proved by its credential.
/// There is no owner vocabulary here to reach: the request decodes only as an execution-scoped
/// `ControllerAgentRequest` or a provider transcript report.
public struct ControllerBrokerRequest: Codable, Sendable {
    public var execution: String?
    public var mailbox: String?
    public var credential: String
    public var request: ControllerAgentRequest?
    /// An execution's provider transcript, reported by its `agent-notice` hook.
    public var transcript: ProviderTranscript?

    public init(execution: String? = nil, mailbox: String? = nil, credential: String,
                request: ControllerAgentRequest? = nil, transcript: ProviderTranscript? = nil) {
        self.execution = execution; self.mailbox = mailbox; self.credential = credential
        self.request = request; self.transcript = transcript
    }
}

public struct ControllerBrokerReply: Codable, Sendable {
    public var response: ControllerAgentResponse?
    /// The same token the store would have thrown (`forbidden`, `conflict`, `invalid_input: …`).
    public var error: String?
}

/// A refusal or failure reported by the broker, carried to the agent as its tool error text.
public struct ControllerBrokerFailure: Error, Equatable, CustomStringConvertible {
    public let description: String
}

/// How a launched agent reaches its tools. Chosen by the dispatcher, never by the recipe.
public enum ControllerAgentAccess: Sendable, Equatable {
    /// The resident supervisor's broker. The child gets this socket and no store path, and
    /// `agentBinary` (when set) as the controller executable it runs its tools with.
    case broker(socket: String, agentBinary: String?)
    /// Compatibility for a store with no resident supervisor (a manual `launch`, a one-shot
    /// `supervisor-tick`): the child opens the owner store itself, so this is honest only when
    /// the agent and the controller are one account that already trust each other.
    case legacyDatabase(String)

    public static let socketEnvironment = "THREADING_CONTROLLER_AGENT_SOCKET"
    public static let databaseEnvironment = "THREADING_CONTROLLER_DATABASE"
    /// Owner-side opt-in to `legacyDatabase` when no broker answers.
    public static let legacyOptInEnvironment = "THREADING_CONTROLLER_LEGACY_AGENT_DATABASE"

    /// The advertised broker when it answers; otherwise the legacy path only when opted in.
    public static func resolve(store: ControllerStore, database: String, allowLegacy: Bool) async -> ControllerAgentAccess? {
        if let advertised = try? await store.agentBrokerAdvertisement(),
           ControllerAgentBrokerClient.isServing(socket: advertised.socket) {
            return .broker(socket: advertised.socket, agentBinary: advertised.agentBinary)
        }
        return allowLegacy ? .legacyDatabase(database) : nil
    }
}

public enum ControllerBrokerLimits {
    /// The MCP server's own line limit plus the envelope.
    public static let requestBytes = 327_680
    /// Store pages are capped at 1 MiB of payload; JSON escaping can grow that.
    public static let responseBytes = 4_194_304
    public static let credentialBytes = 256
    /// Read, operation and write together, per connection.
    public static let connectionSeconds: TimeInterval = 10
    public static let concurrentConnections = 32
    static let backlog: Int32 = 64
    static let acceptPollMilliseconds: Int32 = 200
    static let refusalEventsPerMinute = 30
    static let rememberedPeers = 4_096
    static let stopSeconds: TimeInterval = 15
}

// MARK: - Server

/// Serves execution-scoped agent tools on a Unix socket for the resident supervisor, so a
/// launched agent never needs the owner store's path or file permissions.
///
/// It runs on its own threads — one accept thread and at most `concurrentConnections` handler
/// threads — and its own `ControllerStore` connection, so a slow or hostile client can hold a
/// handler for at most `connectionSeconds` and can never delay a supervisor tick. A connection
/// past the bound is answered `busy` and closed. The socket is `0660`: who may connect is decided
/// by the directory it is in and its group (see autonomous-controller.md, "Agent tool broker").
/// The peer's uid is recorded as evidence, never used as authority.
public final class ControllerAgentBroker: @unchecked Sendable {
    public static let socketPermissions: mode_t = 0o660
    public static let defaultSocketName = "agent.sock"
    public let socketPath: String
    private let store: ControllerStore
    private let listener: Int32
    private let slots = DispatchSemaphore(value: ControllerBrokerLimits.concurrentConnections)
    private let handlers = DispatchQueue(label: "threading.controller.agent-broker", attributes: .concurrent)
    private let running = DispatchGroup()
    private let lock = NSLock()
    private var stopping = false
    private var peers: Set<String> = []
    private var refusalWindow = Date.distantPast
    private var refusals = 0
    private let socketIdentity: (device: UInt64, inode: UInt64)

    public static func defaultSocketPath(database: String) -> String {
        URL(fileURLWithPath: database).deletingLastPathComponent().appendingPathComponent(defaultSocketName).path
    }

    public init(socketPath: String, store: ControllerStore) throws {
        self.socketPath = socketPath
        self.store = store
        do {
            listener = try ControllerUnixSocket.listen(path: socketPath, mode: Self.socketPermissions,
                                                       backlog: ControllerBrokerLimits.backlog)
        } catch ControllerSocketError.pathTooLong {
            throw ControllerError.invalidInput("agent_socket_path")
        } catch ControllerSocketError.notASocket {
            throw ControllerError.invalidInput("agent_socket_path_occupied")
        } catch {
            throw ControllerError.invalidInput("agent_socket_unavailable")
        }
        var info = stat()
        _ = lstat(socketPath, &info)
        socketIdentity = (UInt64(info.st_dev), UInt64(info.st_ino))
    }

    public func start() {
        running.enter()
        let thread = Thread { [self] in
            acceptLoop()
            running.leave()
        }
        thread.name = "threading.controller.agent-broker.accept"
        thread.start()
    }

    /// Stops accepting, waits (bounded) for in-flight connections, and removes the socket file
    /// only if it is still the one this broker bound.
    public func stop() {
        lock.lock(); stopping = true; lock.unlock()
        _ = running.wait(timeout: .now() + ControllerBrokerLimits.stopSeconds)
        ControllerUnixSocket.close(listener)
        var info = stat()
        if lstat(socketPath, &info) == 0, UInt64(info.st_dev) == socketIdentity.device, UInt64(info.st_ino) == socketIdentity.inode {
            unlink(socketPath)
        }
    }

    private var isStopping: Bool { lock.lock(); defer { lock.unlock() }; return stopping }

    private func acceptLoop() {
        while !isStopping {
            var event = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&event, 1, ControllerBrokerLimits.acceptPollMilliseconds) > 0 else { continue }
            let descriptor = accept(listener, nil, nil)
            guard descriptor >= 0 else { continue }
            let flags = fcntl(descriptor, F_GETFL, 0)
            guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0, flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                ControllerUnixSocket.close(descriptor); continue
            }
            #if canImport(Darwin)
            var suppress: Int32 = 1
            _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &suppress, socklen_t(MemoryLayout<Int32>.size))
            #endif
            guard slots.wait(timeout: .now()) == .success else {
                // Never queue past the bound: answer at once without waiting on the client.
                Self.reply(descriptor, ControllerBrokerReply(response: nil, error: "busy"),
                           until: ControllerUnixSocket.deadline(after: 0.05))
                ControllerUnixSocket.close(descriptor)
                continue
            }
            running.enter()
            handlers.async { [self] in
                serve(descriptor)
                ControllerUnixSocket.close(descriptor)
                slots.signal()
                running.leave()
            }
        }
    }

    private func serve(_ descriptor: Int32) {
        let deadline = ControllerUnixSocket.deadline(after: ControllerBrokerLimits.connectionSeconds)
        let uid = ControllerUnixSocket.peerUID(descriptor) ?? UInt32.max
        let line: Data
        do {
            line = try ControllerUnixSocket.readLine(descriptor, maximum: ControllerBrokerLimits.requestBytes, until: deadline)
        } catch ControllerSocketError.tooLarge {
            refused(uid: uid, reason: "request_too_large")
            Self.reply(descriptor, ControllerBrokerReply(response: nil, error: "request_too_large"), until: deadline)
            return
        } catch {
            return  // A client that went away or sent no line in time is owed nothing.
        }
        guard let envelope = try? JSONDecoder().decode(ControllerBrokerRequest.self, from: line) else {
            refused(uid: uid, reason: "invalid_request")
            Self.reply(descriptor, ControllerBrokerReply(response: nil, error: "invalid_request"), until: deadline)
            return
        }
        let outcome = Outcome()
        let done = DispatchSemaphore(value: 0)
        let store = store
        Task.detached {
            outcome.set(await Self.execute(store, envelope))
            done.signal()
        }
        let reply: ControllerBrokerReply
        if done.wait(timeout: DispatchTime(uptimeNanoseconds: deadline)) == .timedOut {
            reply = ControllerBrokerReply(response: nil, error: "timeout")
        } else {
            switch outcome.value {
            case .success(let (response, subject)):
                served(subject, uid: uid)
                reply = ControllerBrokerReply(response: response, error: nil)
            case .failure(let error):
                let token = (error as? ControllerError)?.description ?? "tool_operation_failed"
                if (error as? ControllerError) == .forbidden { refused(uid: uid, reason: "forbidden") }
                reply = ControllerBrokerReply(response: nil, error: token)
            case nil:
                reply = ControllerBrokerReply(response: nil, error: "tool_operation_failed")
            }
        }
        Self.reply(descriptor, reply, until: deadline)
    }

    /// Exactly the operations an agent process could perform with its credential before the
    /// broker existed — no more.
    static func execute(_ store: ControllerStore, _ envelope: ControllerBrokerRequest) async
        -> Result<(ControllerAgentResponse, ControllerAgentPeerEvent.AgentSubject), Error> {
        do {
            guard envelope.credential.utf8.count <= ControllerBrokerLimits.credentialBytes else { throw ControllerError.forbidden }
            switch (envelope.execution, envelope.mailbox) {
            case (let execution?, nil):
                let id = try ExecutionID(execution)
                if let transcript = envelope.transcript {
                    guard envelope.request == nil else { throw ControllerError.invalidInput("broker_request") }
                    try await store.bindProviderTranscript(id, credential: envelope.credential, transcript: transcript)
                    return .success((ControllerAgentResponse(), .execution(id)))
                }
                guard let request = envelope.request else { throw ControllerError.invalidInput("broker_request") }
                let response = try await store.agentRequest(executionID: id, credential: envelope.credential, request: request)
                return .success((response, .execution(id)))
            case (nil, let mailbox?):
                let address = try MailAddress(mailbox)
                guard envelope.transcript == nil, let request = envelope.request else {
                    throw ControllerError.invalidInput("broker_request")
                }
                let response = try await store.mailboxRequest(address: address, credential: envelope.credential, request: request)
                return .success((response, .mailbox(address)))
            default:
                throw ControllerError.forbidden
            }
        } catch {
            return .failure(error)
        }
    }

    private func served(_ subject: ControllerAgentPeerEvent.AgentSubject, uid: UInt32) {
        let key: String
        switch subject {
        case .execution(let id): key = "e:\(id.description):\(uid)"
        case .mailbox(let address): key = "m:\(address.description):\(uid)"
        }
        lock.lock()
        if peers.count >= ControllerBrokerLimits.rememberedPeers { peers.removeAll() }
        let first = peers.insert(key).inserted
        lock.unlock()
        guard first else { return }
        let store = store
        Task.detached { try? await store.recordAgentPeer(.served(subject: subject, uid: uid)) }
    }

    /// Refusals are evidence too, but a client could send them in a loop: at most
    /// `refusalEventsPerMinute` become events.
    private func refused(uid: UInt32, reason: String) {
        lock.lock()
        let now = Date()
        if now.timeIntervalSince(refusalWindow) >= 60 { refusalWindow = now; refusals = 0 }
        refusals += 1
        let record = refusals <= ControllerBrokerLimits.refusalEventsPerMinute
        lock.unlock()
        guard record else { return }
        let store = store
        Task.detached { try? await store.recordAgentPeer(.refused(uid: uid, reason: reason)) }
    }

    private static func reply(_ descriptor: Int32, _ reply: ControllerBrokerReply, until deadline: UInt64) {
        let encoder = JSONEncoder()
        var data = (try? encoder.encode(reply)) ?? Data()
        if data.count > ControllerBrokerLimits.responseBytes {
            data = (try? encoder.encode(ControllerBrokerReply(response: nil, error: "response_too_large"))) ?? Data()
        }
        data.append(10)
        try? ControllerUnixSocket.writeAll(descriptor, data, until: deadline)
    }

    private final class Outcome: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Result<(ControllerAgentResponse, ControllerAgentPeerEvent.AgentSubject), Error>?
        func set(_ value: Result<(ControllerAgentResponse, ControllerAgentPeerEvent.AgentSubject), Error>) {
            lock.lock(); stored = value; lock.unlock()
        }
        var value: Result<(ControllerAgentResponse, ControllerAgentPeerEvent.AgentSubject), Error>? {
            lock.lock(); defer { lock.unlock() }; return stored
        }
    }
}

// MARK: - Client

/// The agent side: `agent`, `agent-mcp` and `agent-notice` in an agent's process. Each call is
/// one bounded connection, so a supervisor restart costs one failed call, not a wedged server.
public enum ControllerAgentBrokerClient {
    static let connectSeconds: TimeInterval = 3
    static let probeSeconds: TimeInterval = 1
    /// Longer than the server's own budget, so the server's `timeout` answer arrives first.
    static let exchangeSeconds: TimeInterval = ControllerBrokerLimits.connectionSeconds + 5

    public static func perform(socket: String, _ envelope: ControllerBrokerRequest) throws -> ControllerAgentResponse {
        let descriptor: Int32
        do { descriptor = try ControllerUnixSocket.connect(path: socket, timeout: connectSeconds) }
        catch { throw ControllerBrokerFailure(description: "agent_broker_unavailable") }
        defer { ControllerUnixSocket.close(descriptor) }
        let deadline = ControllerUnixSocket.deadline(after: exchangeSeconds)
        var data = try JSONEncoder().encode(envelope)
        guard data.count <= ControllerBrokerLimits.requestBytes else { throw ControllerError.invalidInput("request_size") }
        data.append(10)
        let line: Data
        do {
            try ControllerUnixSocket.writeAll(descriptor, data, until: deadline)
            line = try ControllerUnixSocket.readLine(descriptor, maximum: ControllerBrokerLimits.responseBytes, until: deadline)
        } catch {
            throw ControllerBrokerFailure(description: "agent_broker_unavailable")
        }
        guard let reply = try? JSONDecoder().decode(ControllerBrokerReply.self, from: line) else {
            throw ControllerBrokerFailure(description: "agent_broker_protocol")
        }
        if let error = reply.error { throw ControllerBrokerFailure(description: error) }
        guard let response = reply.response else { throw ControllerBrokerFailure(description: "agent_broker_protocol") }
        return response
    }

    /// Whether something accepts connections at `socket` now. Closing at once frees the slot.
    public static func isServing(socket: String) -> Bool {
        guard let descriptor = try? ControllerUnixSocket.connect(path: socket, timeout: probeSeconds) else { return false }
        ControllerUnixSocket.close(descriptor)
        return true
    }
}

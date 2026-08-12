import Foundation
@preconcurrency import Network

/// An iOS-side loopback proxy. URLSession connects to the returned HTTP origin while logical TCP
/// streams cross the encrypted peer tunnel. The listener is loopback-only and accepts no more
/// sockets than the multiplexer can represent.
public final class PeerTunnelLocalProxy: @unchecked Sendable {
    private struct ActiveSocket {
        let socket: PeerTunnelSocket
        let task: Task<Void, Never>
    }

    private let multiplexer: PeerTunnelMultiplexer
    private let queue = DispatchQueue(label: "codes.threading.peer-tunnel.local-proxy")
    private let lifecycle = NSLock()
    private var didStart = false
    private var isStopped = false
    private var listener: NWListener?
    private var active: [UUID: ActiveSocket] = [:]

    public init(multiplexer: PeerTunnelMultiplexer) {
        self.multiplexer = multiplexer
    }

    public func start() async throws -> URL {
        let mayStart = lifecycle.withLock { () -> Bool in
            guard !didStart, !isStopped else { return false }
            didStart = true
            return true
        }
        guard mayStart else { throw PeerTunnelError.alreadyStarted }

        do {
            try await multiplexer.start()
            guard lifecycle.withLock({ !isStopped }) else {
                throw PeerTunnelError.closed
            }
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters)
            queue.sync { self.listener = listener }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            let port = try await PeerTunnelListenerStarter.start(listener, queue: queue)
            guard let origin = URL(string: "http://127.0.0.1:\(port.rawValue)/") else {
                throw PeerTunnelError.protocolViolation
            }
            return origin
        } catch {
            stop()
            throw error
        }
    }

    public func stop() {
        lifecycle.withLock { isStopped = true }
        queue.async { [weak self] in
            guard let self else { return }
            listener?.cancel()
            listener = nil
            let sockets = Array(active.values)
            active.removeAll(keepingCapacity: false)
            for item in sockets {
                item.task.cancel()
                item.socket.cancel()
            }
            Task { await self.multiplexer.close() }
        }
    }

    private func accept(_ connection: NWConnection) {
        guard active.count < PeerTunnelBounds.maximumStreams else {
            connection.cancel()
            return
        }
        let identifier = UUID()
        let socket = PeerTunnelSocket(
            connection: connection,
            queueLabel: "codes.threading.peer-tunnel.local-socket"
        )
        let task = Task { [weak self, socket, multiplexer] in
            defer {
                self?.queue.async { [weak self] in self?.active[identifier] = nil }
            }
            do {
                try await socket.start()
                let stream = try await multiplexer.openStream()
                try await PeerTunnelSocketPump.run(socket: socket, stream: stream)
            } catch {
                socket.cancel()
            }
        }
        active[identifier] = ActiveSocket(socket: socket, task: task)
    }
}

/// A Mac-side bridge from logical tunnel streams to the existing loopback-only remote server.
public final class PeerTunnelLoopbackBridge: @unchecked Sendable {
    private struct ActiveSocket {
        let socket: PeerTunnelSocket
        let task: Task<Void, Never>
    }

    private let multiplexer: PeerTunnelMultiplexer
    private let targetPort: NWEndpoint.Port
    private let queue = DispatchQueue(label: "codes.threading.peer-tunnel.loopback-bridge")
    private let lifecycle = NSLock()
    private var didStart = false
    private var isStopped = false
    private var acceptTask: Task<Void, Never>?
    private var active: [UUID: ActiveSocket] = [:]

    public init(multiplexer: PeerTunnelMultiplexer, targetPort: UInt16) throws {
        guard let port = NWEndpoint.Port(rawValue: targetPort) else {
            throw PeerTunnelError.protocolViolation
        }
        self.multiplexer = multiplexer
        self.targetPort = port
    }

    public func start() async throws {
        let mayStart = lifecycle.withLock { () -> Bool in
            guard !didStart, !isStopped else { return false }
            didStart = true
            return true
        }
        guard mayStart else { throw PeerTunnelError.alreadyStarted }
        do {
            try await multiplexer.start()
            guard lifecycle.withLock({ !isStopped }) else {
                throw PeerTunnelError.closed
            }
            queue.sync {
                acceptTask = Task { [weak self] in
                    await self?.acceptLoop()
                }
            }
        } catch {
            lifecycle.withLock { isStopped = true }
            throw error
        }
    }

    public func stop() {
        lifecycle.withLock { isStopped = true }
        queue.async { [weak self] in
            guard let self else { return }
            acceptTask?.cancel()
            acceptTask = nil
            let sockets = Array(active.values)
            active.removeAll(keepingCapacity: false)
            for item in sockets {
                item.task.cancel()
                item.socket.cancel()
            }
            Task { await self.multiplexer.close() }
        }
    }

    private func acceptLoop() async {
        while !Task.isCancelled {
            do {
                let stream = try await multiplexer.acceptStream()
                queue.async { [weak self] in self?.connect(stream) }
            } catch is CancellationError {
                return
            } catch {
                stop()
                return
            }
        }
    }

    private func connect(_ stream: PeerTunnelStream) {
        guard active.count < PeerTunnelBounds.maximumStreams else {
            Task { await stream.reset() }
            return
        }
        let identifier = UUID()
        let socket = PeerTunnelSocket(
            connection: NWConnection(host: "127.0.0.1", port: targetPort, using: .tcp),
            queueLabel: "codes.threading.peer-tunnel.loopback-socket"
        )
        let task = Task { [weak self, socket, stream] in
            defer {
                self?.queue.async { [weak self] in self?.active[identifier] = nil }
            }
            do {
                try await socket.start()
                try await stream.accept()
                try await PeerTunnelSocketPump.run(socket: socket, stream: stream)
            } catch {
                await stream.reset()
                socket.cancel()
            }
        }
        active[identifier] = ActiveSocket(socket: socket, task: task)
    }
}

private enum PeerTunnelSocketPump {
    static func run(socket: PeerTunnelSocket, stream: PeerTunnelStream) async throws {
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await withTaskCancellationHandler {
                        while true {
                            let read = try await socket.receive()
                            if !read.data.isEmpty {
                                try await stream.send(read.data)
                            }
                            if read.isComplete {
                                try await stream.endSending()
                                return
                            }
                        }
                    } onCancel: {
                        socket.cancel()
                        Task { await stream.reset() }
                    }
                }
                group.addTask {
                    try await withTaskCancellationHandler {
                        while let data = try await stream.receive() {
                            try await socket.send(data)
                            try await stream.acknowledge(data.count)
                        }
                        try await socket.finishSending()
                    } onCancel: {
                        socket.cancel()
                        Task { await stream.reset() }
                    }
                }
                try await group.waitForAll()
            }
            socket.cancel()
        } catch {
            await stream.reset()
            socket.cancel()
            throw error
        }
    }
}

private struct PeerTunnelSocketRead: Sendable {
    let data: Data
    let isComplete: Bool
}

/// Network.framework permits one read and one write at a time. The two socket pumps own those
/// directions, while `queue` owns state callbacks. Cancellation is safe from either pump.
private final class PeerTunnelSocket: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue

    init(connection: NWConnection, queueLabel: String) {
        self.connection = connection
        queue = DispatchQueue(label: queueLabel)
    }

    func start() async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            let gate = PeerTunnelContinuationGate(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    gate.succeed(())
                case .failed(let error):
                    gate.fail(error)
                case .cancelled:
                    gate.fail(PeerTunnelError.closed)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    func receive() async throws -> PeerTunnelSocketRead {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(
                minimumIncompleteLength: 1,
                maximumLength: PeerTunnelBounds.maximumDataBytes
            ) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(
                        returning: PeerTunnelSocketRead(
                            data: data ?? Data(),
                            isComplete: isComplete
                        )
                    )
                }
            }
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func finishSending() async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: nil,
                contentContext: .finalMessage,
                isComplete: true,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            )
        }
    }

    func cancel() {
        connection.cancel()
    }
}

private enum PeerTunnelListenerStarter {
    static func start(_ listener: NWListener, queue: DispatchQueue) async throws -> NWEndpoint.Port {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<NWEndpoint.Port, Error>) in
            let gate = PeerTunnelContinuationGate(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let port = listener.port {
                        gate.succeed(port)
                    } else {
                        gate.fail(PeerTunnelError.protocolViolation)
                    }
                case .failed(let error):
                    gate.fail(error)
                case .cancelled:
                    gate.fail(PeerTunnelError.closed)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }
}

private final class PeerTunnelContinuationGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func succeed(_ value: sending Value) {
        take()?.resume(returning: value)
    }

    func fail(_ error: Error) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<Value, Error>? {
        lock.withLock {
            defer { continuation = nil }
            return continuation
        }
    }
}

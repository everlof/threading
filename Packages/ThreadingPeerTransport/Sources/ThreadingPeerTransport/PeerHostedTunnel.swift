import Foundation

public enum PeerHostedBounds {
    public static let maximumConcurrentDeviceSessions = 8
}

public enum PeerHostedFailure: String, Equatable, Sendable {
    case unauthorized
    case hostOffline
    case sessionExpired
    case hostBusy
    case signaling
    case transport
}

public enum PeerHostedHostEvent: Equatable, Sendable {
    case ready
    case sessionConnected(
        sessionID: String,
        deviceID: String,
        route: PeerTransportRoute?
    )
    case sessionClosed(sessionID: String)
    case sessionFailed(sessionID: String?, reason: PeerHostedFailure)
    case listenerFailed(reason: PeerHostedFailure)
}

/// A live iOS-side loopback origin. Existing `RemoteClient` and WebSocket code can use `origin`
/// with its existing Mac-issued capability; this object only changes how TCP reaches the Mac.
public final class PeerHostedDeviceTunnel: @unchecked Sendable {
    public let origin: URL
    public let sessionID: String
    public let initialRoute: PeerTransportRoute?

    private let proxy: PeerTunnelLocalProxy
    private let socket: PeerRendezvousWebSocket
    private let transport: WebRTCPeerTransport
    private let localCandidateTask: Task<Void, Error>
    private let remoteSignalTask: Task<Void, Error>
    private let maintenanceTask: Task<Void, Never>
    private let lifecycle = NSLock()
    private var isStopped = false

    fileprivate init(
        origin: URL,
        sessionID: String,
        initialRoute: PeerTransportRoute?,
        proxy: PeerTunnelLocalProxy,
        socket: PeerRendezvousWebSocket,
        transport: WebRTCPeerTransport,
        localCandidateTask: Task<Void, Error>,
        remoteSignalTask: Task<Void, Error>,
        maintenanceTask: Task<Void, Never>
    ) {
        self.origin = origin
        self.sessionID = sessionID
        self.initialRoute = initialRoute
        self.proxy = proxy
        self.socket = socket
        self.transport = transport
        self.localCandidateTask = localCandidateTask
        self.remoteSignalTask = remoteSignalTask
        self.maintenanceTask = maintenanceTask
    }

    deinit { stop() }

    public func selectedRoute() async -> PeerTransportRoute? {
        await transport.selectedRoute()
    }

    public func stop() {
        let shouldStop = lifecycle.withLock { () -> Bool in
            guard !isStopped else { return false }
            isStopped = true
            return true
        }
        guard shouldStop else { return }
        localCandidateTask.cancel()
        remoteSignalTask.cancel()
        maintenanceTask.cancel()
        proxy.stop()
        Task { await socket.close() }
    }
}

/// Coarse, content-free stages for diagnosing a hosted connection without logging SDP, ICE
/// candidates, service addresses, credentials, or peer identifiers.
public enum PeerHostedDeviceConnectionPhase: String, Sendable {
    case rendezvous
    case awaitingHost
    case offer
    case ice
    case proxy
}

/// Owns whatever half-built transport exists when the parent connection task is cancelled.
/// Registration is actor-serialized with cancellation so a transport created at the boundary
/// cannot escape either side of the race.
private actor PeerHostedDeviceConnectionCancellation {
    private var isCancelled = false
    private var transport: WebRTCPeerTransport?

    func register(_ transport: WebRTCPeerTransport) throws {
        guard !isCancelled else { throw CancellationError() }
        self.transport = transport
    }

    func cancel(socket: PeerRendezvousWebSocket) async {
        isCancelled = true
        let transport = self.transport
        self.transport = nil
        await socket.close()
        await transport?.close()
    }
}

public enum PeerHostedDeviceConnector {
    public static func connect(
        endpoint: PeerRendezvousServiceEndpoint,
        hostID: String,
        deviceID: String,
        credential: PeerRendezvousCredential,
        progress: (@Sendable (PeerHostedDeviceConnectionPhase) -> Void)? = nil
    ) async throws -> PeerHostedDeviceTunnel {
        progress?(.rendezvous)
        let socket = try PeerRendezvousWebSocket(url: endpoint.deviceURL, credential: credential)
        let cancellation = PeerHostedDeviceConnectionCancellation()
        return try await withTaskCancellationHandler {
            try await socket.connect()
            do {
                try await socket.send(
                    PeerRendezvousEnvelope(
                        kind: .deviceConnect,
                        hostID: hostID,
                        deviceID: deviceID
                    )
                )
                progress?(.awaitingHost)
                let ready = try await socket.receive(
                    timeout: PeerTransportBounds.negotiationTimeout
                )
                try throwIfFailure(ready)
                guard ready.kind == .ready, let sessionID = ready.sessionID,
                      let iceServers = ready.iceServers else {
                    throw PeerRendezvousError.invalidEnvelope
                }

                progress?(.offer)
                let configuration = try PeerTransportConfiguration(iceServers: iceServers)
                let transport = try WebRTCPeerTransport(
                    role: .offerer,
                    configuration: configuration
                )
                do {
                    try await cancellation.register(transport)
                } catch {
                    await transport.close()
                    throw error
                }
                let offer = try await transport.makeTrickleOffer()
                try await socket.send(
                    PeerRendezvousEnvelope(
                        kind: .offer,
                        sessionID: sessionID,
                        description: offer
                    )
                )

                let localTask = signalingTask(transport: transport) {
                    try await forwardLocalCandidates(
                        transport: transport,
                        socket: socket,
                        sessionID: sessionID
                    )
                }
                let remoteTask = signalingTask(transport: transport) {
                    try await receiveDeviceSignals(
                        transport: transport,
                        socket: socket,
                        sessionID: sessionID
                    )
                }
                let maintenance = finishSignaling(
                    socket: socket,
                    transport: transport,
                    sessionID: sessionID,
                    localTask: localTask,
                    remoteTask: remoteTask
                )

                do {
                    progress?(.ice)
                    try await transport.waitUntilOpen()
                    let multiplexer = PeerTunnelMultiplexer(role: .client, transport: transport)
                    let proxy = PeerTunnelLocalProxy(multiplexer: multiplexer)
                    progress?(.proxy)
                    let origin = try await proxy.start()
                    try Task.checkCancellation()
                    return PeerHostedDeviceTunnel(
                        origin: origin,
                        sessionID: sessionID,
                        initialRoute: await transport.selectedRoute(),
                        proxy: proxy,
                        socket: socket,
                        transport: transport,
                        localCandidateTask: localTask,
                        remoteSignalTask: remoteTask,
                        maintenanceTask: maintenance
                    )
                } catch {
                    localTask.cancel()
                    remoteTask.cancel()
                    maintenance.cancel()
                    await socket.close()
                    await transport.close()
                    throw error
                }
            } catch {
                await socket.close()
                throw error
            }
        } onCancel: {
            // URLSessionWebSocketTask.receive and WebRTC's checked continuations do not make
            // cancellation ownership obvious. Explicitly closing both owned layers makes a
            // losing route race terminal promptly in every negotiation stage.
            Task { await cancellation.cancel(socket: socket) }
        }
    }
}

public final class PeerHostedHostTunnel: @unchecked Sendable {
    public let sessionID: String
    public let deviceID: String
    public let initialRoute: PeerTransportRoute?

    fileprivate let transport: WebRTCPeerTransport
    private let bridge: PeerTunnelLoopbackBridge
    private let socket: PeerRendezvousWebSocket
    private let localCandidateTask: Task<Void, Error>
    private let remoteSignalTask: Task<Void, Error>
    private let maintenanceTask: Task<Void, Never>
    private let lifecycle = NSLock()
    private var isStopped = false

    fileprivate init(
        sessionID: String,
        deviceID: String,
        initialRoute: PeerTransportRoute?,
        transport: WebRTCPeerTransport,
        bridge: PeerTunnelLoopbackBridge,
        socket: PeerRendezvousWebSocket,
        localCandidateTask: Task<Void, Error>,
        remoteSignalTask: Task<Void, Error>,
        maintenanceTask: Task<Void, Never>
    ) {
        self.sessionID = sessionID
        self.deviceID = deviceID
        self.initialRoute = initialRoute
        self.transport = transport
        self.bridge = bridge
        self.socket = socket
        self.localCandidateTask = localCandidateTask
        self.remoteSignalTask = remoteSignalTask
        self.maintenanceTask = maintenanceTask
    }

    deinit { stop() }

    public func selectedRoute() async -> PeerTransportRoute? {
        await transport.selectedRoute()
    }

    public func stop() {
        let shouldStop = lifecycle.withLock { () -> Bool in
            guard !isStopped else { return false }
            isStopped = true
            return true
        }
        guard shouldStop else { return }
        localCandidateTask.cancel()
        remoteSignalTask.cancel()
        maintenanceTask.cancel()
        bridge.stop()
        Task { await socket.close() }
    }
}

/// Long-lived Mac control connection. Session negotiations and retained tunnels are capped
/// independently; the listener is one-shot and app reconnect policy creates a fresh instance.
public actor PeerHostedHostListener {
    private struct PendingSession: Sendable {
        let deviceID: String
        let task: Task<Void, Never>
    }

    public nonisolated let events: AsyncStream<PeerHostedHostEvent>

    private let eventContinuation: AsyncStream<PeerHostedHostEvent>.Continuation
    private let endpoint: PeerRendezvousServiceEndpoint
    private let hostID: String
    private let credential: PeerRendezvousCredential
    private let targetPort: UInt16
    private var controlSocket: PeerRendezvousWebSocket?
    private var controlTask: Task<Void, Never>?
    private var pending: [String: PendingSession] = [:]
    private var sessions: [String: PeerHostedHostTunnel] = [:]
    private var didStart = false
    private var isStopped = false

    public init(
        endpoint: PeerRendezvousServiceEndpoint,
        hostID: String,
        credential: PeerRendezvousCredential,
        targetPort: UInt16
    ) {
        self.endpoint = endpoint
        self.hostID = hostID
        self.credential = credential
        self.targetPort = targetPort
        let stream = AsyncStream<PeerHostedHostEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(64)
        )
        events = stream.stream
        eventContinuation = stream.continuation
    }

    deinit {
        controlTask?.cancel()
        eventContinuation.finish()
    }

    public func start() async throws {
        guard !didStart, !isStopped else { throw PeerTunnelError.alreadyStarted }
        didStart = true
        let socket = try PeerRendezvousWebSocket(
            url: endpoint.hostControlURL,
            credential: credential
        )
        do {
            try await socket.connect()
            try await socket.send(PeerRendezvousEnvelope(kind: .hostHello, hostID: hostID))
            let response = try await socket.receive(
                timeout: PeerTransportBounds.negotiationTimeout
            )
            try throwIfFailure(response)
            guard response.kind == .hostReady, response.hostID == hostID else {
                throw PeerRendezvousError.invalidEnvelope
            }
            controlSocket = socket
            eventContinuation.yield(.ready)
            controlTask = Task { [weak self] in
                await self?.receiveControlMessages(socket)
            }
        } catch {
            await socket.close()
            isStopped = true
            throw error
        }
    }

    public func stop() async {
        guard !isStopped else { return }
        isStopped = true
        controlTask?.cancel()
        controlTask = nil
        let pendingTasks = pending.values.map(\.task)
        pending.removeAll(keepingCapacity: false)
        pendingTasks.forEach { $0.cancel() }
        let active = Array(sessions.values)
        sessions.removeAll(keepingCapacity: false)
        active.forEach { $0.stop() }
        if let controlSocket { await controlSocket.close() }
        controlSocket = nil
        eventContinuation.finish()
    }

    public func activeSessionCount() -> Int {
        sessions.count
    }

    /// Immediately removes every negotiating or active tunnel owned by `deviceID`.
    /// Call this when the app revokes the corresponding remote-device capability.
    public func disconnect(deviceID: String) {
        let pendingSessionIDs = pending.compactMap { sessionID, session in
            session.deviceID == deviceID ? sessionID : nil
        }
        for sessionID in pendingSessionIDs {
            pending.removeValue(forKey: sessionID)?.task.cancel()
        }

        let activeSessionIDs = sessions.compactMap { sessionID, tunnel in
            tunnel.deviceID == deviceID ? sessionID : nil
        }
        for sessionID in activeSessionIDs {
            guard let tunnel = sessions.removeValue(forKey: sessionID) else { continue }
            tunnel.stop()
            eventContinuation.yield(.sessionClosed(sessionID: sessionID))
        }
    }

    private func receiveControlMessages(_ socket: PeerRendezvousWebSocket) async {
        do {
            while !Task.isCancelled {
                let message = try await socket.receive()
                try throwIfFailure(message)
                guard message.kind == .incomingSession,
                      message.hostID == hostID,
                      let sessionID = message.sessionID,
                      let sessionToken = message.sessionToken,
                      let deviceID = message.deviceID else {
                    throw PeerRendezvousError.invalidEnvelope
                }
                await beginSession(
                    sessionID: sessionID,
                    deviceID: deviceID,
                    sessionToken: sessionToken
                )
            }
        } catch is CancellationError {
            return
        } catch {
            guard !isStopped else { return }
            eventContinuation.yield(.listenerFailed(reason: hostedFailure(error)))
            await stop()
        }
    }

    private func beginSession(
        sessionID: String,
        deviceID: String,
        sessionToken: String
    ) async {
        guard pending[sessionID] == nil, sessions[sessionID] == nil else { return }
        guard pending.count + sessions.count < PeerHostedBounds.maximumConcurrentDeviceSessions else {
            eventContinuation.yield(
                .sessionFailed(sessionID: sessionID, reason: .hostBusy)
            )
            return
        }
        guard let sessionCredential = try? PeerRendezvousCredential(sessionToken) else {
            eventContinuation.yield(
                .sessionFailed(sessionID: sessionID, reason: .unauthorized)
            )
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let tunnel = try await negotiateHostSession(
                    endpoint: endpoint,
                    sessionID: sessionID,
                    deviceID: deviceID,
                    credential: sessionCredential,
                    targetPort: targetPort
                )
                await didConnect(tunnel)
            } catch {
                await didFail(sessionID: sessionID, error: error)
            }
        }
        pending[sessionID] = PendingSession(deviceID: deviceID, task: task)
    }

    private func didConnect(_ tunnel: PeerHostedHostTunnel) async {
        pending[tunnel.sessionID] = nil
        guard !isStopped else {
            tunnel.stop()
            return
        }

        // A device owns at most one live direct tunnel. Keeping an older tunnel here would
        // preserve a revoked/stale path and consume one of the listener's bounded slots.
        let replacedSessionIDs = sessions.compactMap { sessionID, existing in
            existing.deviceID == tunnel.deviceID && sessionID != tunnel.sessionID
                ? sessionID
                : nil
        }
        for sessionID in replacedSessionIDs {
            guard let existing = sessions.removeValue(forKey: sessionID) else { continue }
            existing.stop()
            eventContinuation.yield(.sessionClosed(sessionID: sessionID))
        }
        sessions[tunnel.sessionID] = tunnel
        eventContinuation.yield(
            .sessionConnected(
                sessionID: tunnel.sessionID,
                deviceID: tunnel.deviceID,
                route: tunnel.initialRoute
            )
        )
        Task { [weak self, weak tunnel] in
            guard let tunnel else { return }
            for await state in tunnel.transport.stateChanges {
                switch state {
                case .closed, .failed:
                    await self?.sessionEnded(tunnel.sessionID, matching: tunnel)
                    return
                default:
                    break
                }
            }
        }
    }

    private func didFail(sessionID: String, error: Error) {
        pending[sessionID] = nil
        guard !isStopped else { return }
        eventContinuation.yield(
            .sessionFailed(sessionID: sessionID, reason: hostedFailure(error))
        )
    }

    private func sessionEnded(
        _ sessionID: String,
        matching tunnel: PeerHostedHostTunnel
    ) {
        guard sessions[sessionID] === tunnel else { return }
        sessions[sessionID] = nil
        tunnel.stop()
        eventContinuation.yield(.sessionClosed(sessionID: sessionID))
    }
}

private func negotiateHostSession(
    endpoint: PeerRendezvousServiceEndpoint,
    sessionID: String,
    deviceID: String,
    credential: PeerRendezvousCredential,
    targetPort: UInt16
) async throws -> PeerHostedHostTunnel {
    let socket = try PeerRendezvousWebSocket(url: endpoint.sessionURL, credential: credential)
    try await socket.connect()
    do {
        try await socket.send(
            PeerRendezvousEnvelope(kind: .sessionJoin, sessionID: sessionID)
        )
        let ready = try await socket.receive(timeout: PeerTransportBounds.negotiationTimeout)
        try throwIfFailure(ready)
        guard ready.kind == .ready, ready.sessionID == sessionID,
              let iceServers = ready.iceServers else {
            throw PeerRendezvousError.invalidEnvelope
        }
        let offerMessage = try await socket.receive(timeout: PeerTransportBounds.negotiationTimeout)
        try throwIfFailure(offerMessage)
        guard offerMessage.kind == .offer, offerMessage.sessionID == sessionID,
              let offer = offerMessage.description else {
            throw PeerRendezvousError.invalidEnvelope
        }

        let transport = try WebRTCPeerTransport(
            role: .answerer,
            configuration: PeerTransportConfiguration(iceServers: iceServers)
        )
        let answer = try await transport.makeTrickleAnswer(to: offer)
        try await socket.send(
            PeerRendezvousEnvelope(
                kind: .answer,
                sessionID: sessionID,
                description: answer
            )
        )

        let localTask = signalingTask(transport: transport) {
            try await forwardLocalCandidates(
                transport: transport,
                socket: socket,
                sessionID: sessionID
            )
        }
        let remoteTask = signalingTask(transport: transport) {
            try await receiveHostSignals(
                transport: transport,
                socket: socket,
                sessionID: sessionID
            )
        }
        let maintenance = finishSignaling(
            socket: socket,
            transport: transport,
            sessionID: sessionID,
            localTask: localTask,
            remoteTask: remoteTask
        )

        do {
            try await transport.waitUntilOpen()
            let multiplexer = PeerTunnelMultiplexer(role: .server, transport: transport)
            let bridge = try PeerTunnelLoopbackBridge(
                multiplexer: multiplexer,
                targetPort: targetPort
            )
            try await bridge.start()
            return PeerHostedHostTunnel(
                sessionID: sessionID,
                deviceID: deviceID,
                initialRoute: await transport.selectedRoute(),
                transport: transport,
                bridge: bridge,
                socket: socket,
                localCandidateTask: localTask,
                remoteSignalTask: remoteTask,
                maintenanceTask: maintenance
            )
        } catch {
            localTask.cancel()
            remoteTask.cancel()
            maintenance.cancel()
            await socket.close()
            await transport.close()
            throw error
        }
    } catch {
        await socket.close()
        throw error
    }
}

private func signalingTask(
    transport: WebRTCPeerTransport,
    operation: @escaping @Sendable () async throws -> Void
) -> Task<Void, Error> {
    Task {
        do {
            try await operation()
        } catch {
            await transport.close()
            throw error
        }
    }
}

private func forwardLocalCandidates(
    transport: WebRTCPeerTransport,
    socket: PeerRendezvousWebSocket,
    sessionID: String
) async throws {
    for try await candidate in transport.localCandidates {
        try Task.checkCancellation()
        try await socket.send(
            PeerRendezvousEnvelope(
                kind: .candidate,
                sessionID: sessionID,
                candidate: candidate
            )
        )
    }
    try await socket.send(
        PeerRendezvousEnvelope(kind: .candidatesComplete, sessionID: sessionID)
    )
}

private func receiveDeviceSignals(
    transport: WebRTCPeerTransport,
    socket: PeerRendezvousWebSocket,
    sessionID: String
) async throws {
    var acceptedAnswer = false
    while true {
        let message = try await socket.receive(timeout: PeerTransportBounds.negotiationTimeout)
        try throwIfFailure(message)
        guard message.sessionID == sessionID else { throw PeerRendezvousError.invalidEnvelope }
        switch message.kind {
        case .answer where !acceptedAnswer:
            guard let answer = message.description else {
                throw PeerRendezvousError.invalidEnvelope
            }
            try await transport.accept(answer: answer)
            acceptedAnswer = true
        case .candidate where acceptedAnswer:
            guard let candidate = message.candidate else {
                throw PeerRendezvousError.invalidEnvelope
            }
            try await transport.addRemoteCandidate(candidate)
        case .candidatesComplete where acceptedAnswer:
            return
        case .close:
            throw PeerRendezvousError.connectionClosed
        default:
            throw PeerRendezvousError.invalidEnvelope
        }
    }
}

private func receiveHostSignals(
    transport: WebRTCPeerTransport,
    socket: PeerRendezvousWebSocket,
    sessionID: String
) async throws {
    while true {
        let message = try await socket.receive(timeout: PeerTransportBounds.negotiationTimeout)
        try throwIfFailure(message)
        guard message.sessionID == sessionID else { throw PeerRendezvousError.invalidEnvelope }
        switch message.kind {
        case .candidate:
            guard let candidate = message.candidate else {
                throw PeerRendezvousError.invalidEnvelope
            }
            try await transport.addRemoteCandidate(candidate)
        case .candidatesComplete:
            return
        case .close:
            throw PeerRendezvousError.connectionClosed
        default:
            throw PeerRendezvousError.invalidEnvelope
        }
    }
}

private func finishSignaling(
    socket: PeerRendezvousWebSocket,
    transport: WebRTCPeerTransport,
    sessionID: String,
    localTask: Task<Void, Error>,
    remoteTask: Task<Void, Error>
) -> Task<Void, Never> {
    Task {
        do {
            try await localTask.value
            try await remoteTask.value
            try? await socket.send(
                PeerRendezvousEnvelope(kind: .close, sessionID: sessionID)
            )
        } catch {
            await transport.close()
        }
        await socket.close()
    }
}

private func throwIfFailure(_ envelope: PeerRendezvousEnvelope) throws {
    guard envelope.kind == .failure else { return }
    switch envelope.errorCode {
    case "unauthorized":
        throw PeerRendezvousError.unauthorized
    case "hostOffline":
        throw PeerRendezvousError.hostOffline
    case "sessionExpired":
        throw PeerRendezvousError.sessionExpired
    default:
        throw PeerRendezvousError.service(envelope.errorMessage ?? "Hosted service error")
    }
}

private func hostedFailure(_ error: Error) -> PeerHostedFailure {
    switch error {
    case PeerRendezvousError.unauthorized:
        return .unauthorized
    case PeerRendezvousError.hostOffline:
        return .hostOffline
    case PeerRendezvousError.sessionExpired:
        return .sessionExpired
    case let tunnel as PeerTunnelError where tunnel == .tooManyStreams(
        limit: PeerTunnelBounds.maximumStreams
    ):
        return .hostBusy
    case is PeerTransportError, is PeerTunnelError:
        return .transport
    default:
        return .signaling
    }
}

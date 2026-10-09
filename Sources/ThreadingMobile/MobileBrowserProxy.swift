import Foundation
import Network
import Security
import ThreadingRemoteKit

/// Keeps certificate verification in the app process. WebKit talks to this loopback-only
/// forwarder; its scoped CONNECT credential then crosses the same pinned Mac route as the API.
final class MobileBrowserProxy: @unchecked Sendable {
    private enum Bounds {
        static let connections = 8
        static let chunkBytes = 32 * 1_024
        static let connectSeconds: TimeInterval = 15
    }

    private let upstreamURL: URL
    private let queue = DispatchQueue(label: "codes.threading.mobile.browser-proxy")
    private var listener: NWListener?
    private var pendingStart: CheckedContinuation<UInt16, Error>?
    private var connections: [UUID: Connection] = [:]
    private var stopped = false

    init(upstreamURL: URL) { self.upstreamURL = upstreamURL }

    func start() async throws -> UInt16 {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    guard !self.stopped, self.listener == nil else {
                        continuation.resume(throwing: CancellationError()); return
                    }
                    self.pendingStart = continuation
                    do {
                        let parameters = NWParameters.tcp
                        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                        let listener = try NWListener(using: parameters)
                        self.listener = listener
                        listener.newConnectionHandler = { [weak self] socket in self?.accept(socket) }
                        listener.stateUpdateHandler = { [weak self] state in
                            guard let self else { return }
                            switch state {
                            case .ready:
                                guard let port = listener.port else { self.stopOnQueue(); return }
                                self.pendingStart?.resume(returning: port.rawValue)
                                self.pendingStart = nil
                            case .failed, .cancelled: self.stopOnQueue()
                            default: break
                            }
                        }
                        listener.start(queue: self.queue)
                        self.queue.asyncAfter(deadline: .now() + Bounds.connectSeconds) { [weak self] in
                            guard let self, self.pendingStart != nil else { return }
                            self.stopOnQueue()
                        }
                    } catch {
                        self.pendingStart?.resume(throwing: error)
                        self.pendingStart = nil
                        self.stopOnQueue()
                    }
                }
            }
        } onCancel: { self.stop() }
    }

    func stop() { queue.async { self.stopOnQueue() } }

    private func stopOnQueue() {
        guard !stopped else { return }
        stopped = true
        pendingStart?.resume(throwing: URLError(.cannotConnectToHost))
        pendingStart = nil
        listener?.cancel()
        listener = nil
        let old = Array(connections.values)
        connections.removeAll()
        old.forEach { $0.stop() }
    }

    private func accept(_ socket: NWConnection) {
        guard !stopped, connections.count < Bounds.connections,
              let host = upstreamURL.host,
              let portValue = UInt16(exactly: upstreamURL.port ?? (upstreamURL.scheme == "https" ? 443 : 80)),
              let port = NWEndpoint.Port(rawValue: portValue) else { socket.cancel(); return }
        let tls = upstreamURL.scheme == "https" ? NWProtocolTLS.Options() : nil
        if let tls {
            sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, host)
            sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
                let trust = sec_trust_copy_ref(trust).takeRetainedValue()
                let pins = RemoteClient.pinningDelegate.pins(forHost: host)
                switch RemoteCertificatePinning.evaluate(trust, against: pins) {
                case .accepted: complete(true)
                case .rejectedFingerprintMismatch: complete(false)
                case .notPinned: complete(SecTrustEvaluateWithError(trust, nil))
                }
            }, queue)
        }
        let upstream = NWConnection(
            host: .init(host), port: port, using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        )
        let id = UUID()
        let pipe = Connection(downstream: socket, upstream: upstream, queue: queue) { [weak self] in
            self?.connections.removeValue(forKey: id)
        }
        connections[id] = pipe
        pipe.start()
    }

    /// All mutable state and both Network.framework callbacks belong to the parent's queue.
    private final class Connection: @unchecked Sendable {
        let downstream: NWConnection
        let upstream: NWConnection
        let queue: DispatchQueue
        let onClose: () -> Void
        var stopped = false
        var finishedDirections = 0

        init(downstream: NWConnection, upstream: NWConnection, queue: DispatchQueue,
             onClose: @escaping () -> Void) {
            self.downstream = downstream
            self.upstream = upstream
            self.queue = queue
            self.onClose = onClose
        }

        func start() {
            downstream.stateUpdateHandler = { [weak self] state in
                if case .failed = state { self?.stop() }
            }
            upstream.stateUpdateHandler = { [weak self] state in
                guard let self, !stopped else { return }
                switch state {
                case .ready:
                    pump(from: downstream, to: upstream)
                    pump(from: upstream, to: downstream)
                case .failed, .cancelled: stop()
                default: break
                }
            }
            downstream.start(queue: queue)
            upstream.start(queue: queue)
            queue.asyncAfter(deadline: .now() + Bounds.connectSeconds) { [weak self] in
                guard let self, upstream.state != .ready else { return }
                stop()
            }
        }

        func stop() {
            guard !stopped else { return }
            stopped = true
            downstream.cancel()
            upstream.cancel()
            onClose()
        }

        func pump(from source: NWConnection, to destination: NWConnection) {
            guard !stopped else { return }
            source.receive(minimumIncompleteLength: 1, maximumLength: Bounds.chunkBytes) { [weak self] data, _, eof, error in
                guard let self, !stopped else { return }
                guard error == nil else { stop(); return }
                destination.send(content: data, contentContext: eof ? .finalMessage : .defaultMessage,
                                 isComplete: true, completion: .contentProcessed { [weak self] error in
                    guard let self, !stopped else { return }
                    guard error == nil else { stop(); return }
                    if eof {
                        finishedDirections += 1
                        if finishedDirections == 2 { stop() }
                    } else { pump(from: source, to: destination) }
                })
            }
        }
    }
}

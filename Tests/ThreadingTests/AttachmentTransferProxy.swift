import Network
import XCTest

/// A byte-preserving TLS tunnel with a slow downstream reader. It never terminates TLS or
/// buffers a whole response: each direction owns at most one 4 KiB chunk. All mutable socket
/// state belongs to `queue`; `stop` synchronously joins it before releasing the fixture.
final class AttachmentTransferProxy: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "AttachmentTransferProxy")
    private var connections: [NWConnection] = []
    private var stopped = false
    private static let chunkBytes = 4_096
    private static let downstreamDelay: TimeInterval = 0.005
    private static let maximumConnections = 8

    var port: UInt16 { listener.port!.rawValue }

    init(upstreamPort: UInt16) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "::1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] downstream in
            guard let self, !self.stopped,
                  self.connections.count < Self.maximumConnections * 2 else {
                downstream.cancel()
                return
            }
            let upstream = NWConnection(
                host: "::1", port: NWEndpoint.Port(rawValue: upstreamPort)!, using: .tcp
            )
            self.connections.append(contentsOf: [downstream, upstream])
            downstream.start(queue: self.queue)
            upstream.start(queue: self.queue)
            self.forward(from: downstream, to: upstream, delay: 0)
            self.forward(from: upstream, to: downstream, delay: Self.downstreamDelay)
        }
        let ready = XCTestExpectation(description: "attachment tunnel listening")
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.fulfill() }
        }
        listener.start(queue: queue)
        guard XCTWaiter.wait(for: [ready], timeout: 5) == .completed else {
            stop()
            throw URLError(.cannotConnectToHost)
        }
    }

    func stop() {
        queue.sync {
            stopped = true
            listener.cancel()
            for connection in connections { connection.cancel() }
            connections.removeAll()
        }
    }

    private func forward(from source: NWConnection, to destination: NWConnection, delay: TimeInterval) {
        guard !stopped else { return }
        source.receive(minimumIncompleteLength: 1, maximumLength: Self.chunkBytes) {
            [weak self] data, _, complete, error in
            guard let self, !self.stopped else { return }
            guard error == nil else {
                destination.cancel()
                return
            }
            destination.send(
                content: data,
                contentContext: complete ? .finalMessage : .defaultMessage,
                isComplete: true,
                completion: .contentProcessed { [weak self] error in
                    guard let self, error == nil, !complete else { return }
                    self.queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                        self?.forward(from: source, to: destination, delay: delay)
                    }
                }
            )
        }
    }
}

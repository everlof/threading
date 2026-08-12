import Foundation
@preconcurrency import Network
import ThreadingPeerTransport

@main
enum PeerTransportProbeHost {
    static func main() async {
        do {
            try await run()
        } catch {
            print("THREADING_PHONE_PROBE FAIL \(error.localizedDescription)")
            Foundation.exit(EXIT_FAILURE)
        }
    }

    private static func run() async throws {
        let stun = try PeerIceServer(urls: [ProbeConstants.stunURL])
        let configuration = try PeerTransportConfiguration(iceServers: [stun])
        let peer = try WebRTCPeerTransport(role: .offerer, configuration: configuration)
        let rendezvous = ProbeRendezvousClient(
            baseURL: ProbeConstants.localRendezvousURL,
            token: ProbeConstants.rendezvousToken
        )
        print("THREADING_PHONE_PROBE waiting via hosted rendezvous")

        let started = ContinuousClock.now
        let identifier = UUID()
        let offer = try await peer.makeTrickleOffer()
        try await rendezvous.publish(
            ProbeOffer(identifier: identifier, offer: offer),
            slot: "offer"
        )
        let publishing = Task {
            try await publishProbeCandidates(from: peer, side: "mac", through: rendezvous)
        }
        defer { publishing.cancel() }
        let reply = try await rendezvous.wait(for: ProbeAnswer.self, slot: "answer")
        guard reply.identifier == identifier else {
            throw ProbeNetworkError.mismatchedProbe
        }
        try await peer.accept(answer: reply.answer)
        let applying = Task {
            try await applyProbeCandidates(to: peer, remoteSide: "phone", through: rendezvous)
        }
        defer { applying.cancel() }
        try await peer.waitUntilOpen()

        let challenge = probeChallenge()
        try await peer.send(challenge)
        let echoed = try await peer.receive()
        guard echoed == challenge else {
            throw ProbeNetworkError.challengeMismatch
        }
        let route = await peer.selectedRoute()
        try await peer.send(probeAcknowledgement())
        let completion = try await rendezvous.wait(
            for: ProbeCompletion.self,
            slot: "completion"
        )
        guard completion.identifier == identifier else {
            throw ProbeNetworkError.mismatchedProbe
        }

        let elapsed = started.duration(to: .now)
        print(
            "THREADING_PHONE_PROBE PASS local_route=\(describe(route)) "
                + "phone_route=\(completion.phoneRoute) bytes=\(challenge.count) "
                + "elapsed=\(elapsed) phone_elapsed=\(completion.phoneElapsed)"
        )
        await peer.close()
    }
}

private final class ProbeListener: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "codes.threading.peer-probe.listener")

    init() throws {
        listener = try NWListener(using: .tcp, on: ProbeConstants.signalingPort)
        listener.service = NWListener.Service(
            name: "Threading Peer Probe",
            type: ProbeConstants.serviceType
        )
    }

    func firstConnection() async throws -> NWConnection {
        try await withCheckedThrowingContinuation { continuation in
            let gate = ProbeOneShot(continuation)
            listener.newConnectionHandler = { connection in
                gate.succeed(connection)
            }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let port = self.listener.port {
                        print("THREADING_PHONE_PROBE signaling-ready port=\(port.rawValue)")
                    }
                case .failed(let error):
                    gate.fail(ProbeNetworkError.connectionFailed(error.localizedDescription))
                case .cancelled:
                    break
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func cancel() {
        listener.newConnectionHandler = nil
        listener.stateUpdateHandler = nil
        listener.cancel()
    }
}

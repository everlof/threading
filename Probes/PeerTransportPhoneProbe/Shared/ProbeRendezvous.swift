import Foundation
import ThreadingPeerTransport

enum ProbeRendezvousError: LocalizedError, Sendable {
    case invalidResponse
    case rejected(Int)
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The rendezvous service returned an invalid response."
        case .rejected(let status):
            return "The rendezvous service rejected the request (HTTP \(status))."
        case .timedOut(let slot):
            return "Timed out waiting for rendezvous slot \(slot)."
        }
    }
}

struct ProbeRendezvousClient: Sendable {
    let baseURL: URL
    let token: String

    func publish<Value: Encodable & Sendable>(_ value: Value, slot: String) async throws {
        var request = URLRequest(url: endpoint(for: slot))
        request.httpMethod = "PUT"
        request.httpBody = try JSONEncoder().encode(value)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProbeRendezvousError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ProbeRendezvousError.rejected(http.statusCode)
        }
    }

    func wait<Value: Decodable & Sendable>(
        for type: Value.Type,
        slot: String,
        timeout: Duration = .seconds(60)
    ) async throws -> Value {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            try Task.checkCancellation()
            var request = URLRequest(url: endpoint(for: slot))
            request.timeoutInterval = 15
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ProbeRendezvousError.invalidResponse
            }
            switch http.statusCode {
            case 200:
                return try JSONDecoder().decode(type, from: data)
            case 404:
                try await Task.sleep(for: .milliseconds(150))
            default:
                throw ProbeRendezvousError.rejected(http.statusCode)
            }
        }
        throw ProbeRendezvousError.timedOut(slot)
    }

    private func endpoint(for slot: String) -> URL {
        baseURL
            .appendingPathComponent("v1")
            .appendingPathComponent("probe")
            .appendingPathComponent(token)
            .appendingPathComponent(slot)
    }
}

func probeCandidateSlot(side: String, index: Int) -> String {
    "\(side)-candidate-\(index)"
}

func publishProbeCandidates(
    from peer: WebRTCPeerTransport,
    side: String,
    through rendezvous: ProbeRendezvousClient
) async throws {
    var index = 0
    for try await candidate in peer.localCandidates {
        guard index < PeerTransportBounds.maximumIceCandidates else {
            throw PeerTransportError.tooManyIceCandidates(
                limit: PeerTransportBounds.maximumIceCandidates
            )
        }
        try await rendezvous.publish(
            candidate,
            slot: probeCandidateSlot(side: side, index: index)
        )
        index += 1
    }
}

func applyProbeCandidates(
    to peer: WebRTCPeerTransport,
    remoteSide: String,
    through rendezvous: ProbeRendezvousClient
) async throws {
    for index in 0..<PeerTransportBounds.maximumIceCandidates {
        let candidate = try await rendezvous.wait(
            for: PeerIceCandidate.self,
            slot: probeCandidateSlot(side: remoteSide, index: index)
        )
        try await peer.addRemoteCandidate(candidate)
    }
}

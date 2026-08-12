import Foundation
@preconcurrency import Network
import ThreadingPeerTransport

enum ProbeConstants {
    static let serviceType = "_threading-ice._tcp"
    // Probe-only fallback for the current physical-device run. Production signaling must use the
    // hosted service; a LAN address is deliberately not part of the transport package API.
    static let directMacHost = NWEndpoint.Host("192.168.1.181")
    static let signalingPort = NWEndpoint.Port(rawValue: 51_837)!
    static let rendezvousToken =
        "replace-with-a-random-64-character-one-use-token-before-building"
    static let localRendezvousURL = URL(string: "http://127.0.0.1:51838")!
    // Replaced with the one-use Quick Tunnel URL immediately before the cellular build.
    static let remoteRendezvousURL = URL(string: "https://probe.invalid")!
    static let stunURL = "stun:stun.cloudflare.com:3478"
    static let maximumSignalingBytes = PeerTransportBounds.maximumSessionDescriptionBytes + 4_096
    static let discoveryTimeout: TimeInterval = 60
    static let challengeBytes = 32 * 1_024
}

struct ProbeOffer: Codable, Sendable {
    let identifier: UUID
    let offer: PeerSessionDescription
}

struct ProbeAnswer: Codable, Sendable {
    let identifier: UUID
    let answer: PeerSessionDescription
}

struct ProbeCompletion: Codable, Sendable {
    let identifier: UUID
    let phoneRoute: String
    let phoneElapsed: String
}

enum ProbeNetworkError: LocalizedError, Sendable {
    case connectionFailed(String)
    case connectionClosed
    case signalingFrameTooLarge(Int)
    case invalidSignalingFrame
    case discoveryTimedOut
    case mismatchedProbe
    case challengeMismatch

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let message):
            return message
        case .connectionClosed:
            return "The signaling connection closed early."
        case .signalingFrameTooLarge(let count):
            return "The signaling frame was \(count) bytes."
        case .invalidSignalingFrame:
            return "The signaling frame was invalid."
        case .discoveryTimedOut:
            return "The Mac probe was not found within \(Int(ProbeConstants.discoveryTimeout)) seconds."
        case .mismatchedProbe:
            return "The answer did not match this one-use probe."
        case .challengeMismatch:
            return "The WebRTC challenge changed in transit."
        }
    }
}

/// A single bounded length-prefixed signaling connection. It carries only SDP; the challenge is
/// intentionally sent through `WebRTCPeerTransport` after negotiation.
final class ProbeFramedConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "codes.threading.peer-probe.signal")

    init(_ connection: NWConnection) {
        self.connection = connection
    }

    func start() async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            let gate = ProbeOneShot(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    gate.succeed(())
                case .failed(let error):
                    gate.fail(ProbeNetworkError.connectionFailed(error.localizedDescription))
                case .cancelled:
                    gate.fail(ProbeNetworkError.connectionClosed)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    func send<Value: Encodable & Sendable>(_ value: Value) async throws {
        let body = try JSONEncoder().encode(value)
        guard body.count <= ProbeConstants.maximumSignalingBytes else {
            throw ProbeNetworkError.signalingFrameTooLarge(body.count)
        }
        var length = UInt32(body.count).bigEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }
        frame.append(body)
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: frame, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(
                        throwing: ProbeNetworkError.connectionFailed(error.localizedDescription)
                    )
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func receive<Value: Decodable & Sendable>(_ type: Value.Type) async throws -> Value {
        let header = try await receiveExactly(4)
        let count = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard count > 0, count <= ProbeConstants.maximumSignalingBytes else {
            throw ProbeNetworkError.signalingFrameTooLarge(Int(count))
        }
        let body = try await receiveExactly(Int(count))
        do {
            return try JSONDecoder().decode(type, from: body)
        } catch {
            throw ProbeNetworkError.invalidSignalingFrame
        }
    }

    func cancel() {
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    private func receiveExactly(_ count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(
                minimumIncompleteLength: count,
                maximumLength: count
            ) { data, _, isComplete, error in
                if let error {
                    continuation.resume(
                        throwing: ProbeNetworkError.connectionFailed(error.localizedDescription)
                    )
                } else if let data, data.count == count {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(throwing: ProbeNetworkError.connectionClosed)
                } else {
                    continuation.resume(throwing: ProbeNetworkError.invalidSignalingFrame)
                }
            }
        }
    }
}

final class ProbeOneShot<Value: Sendable>: @unchecked Sendable {
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

func probeChallenge() -> Data {
    Data((0..<ProbeConstants.challengeBytes).map { UInt8($0 % 251) })
}

func probeAcknowledgement() -> Data {
    Data([0xA5])
}

func describe(_ route: PeerTransportRoute?) -> String {
    guard let route else { return "unknown" }
    let transport = route.networkProtocol ?? "unknown"
    return "\(route.localCandidate.rawValue)->\(route.remoteCandidate.rawValue)/\(transport)"
}

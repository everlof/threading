import Foundation

/// Hard bounds for the transport-facing data whose size is controlled by a peer or service.
///
/// Expected scale is one connection per remote device (normally 1-3, eventually capped by the
/// host). Negotiation has tens of candidates and happens once per reconnect. Messages are the hot
/// path: work is O(message bytes), application buffering is capped, and no per-message logging is
/// performed.
public enum PeerTransportBounds {
    public static let maximumIceServers = 8
    public static let maximumURLsPerIceServer = 4
    public static let maximumIceCandidates = 64
    public static let maximumSessionDescriptionBytes = 256 * 1024
    public static let maximumMessageBytes = 64 * 1024
    public static let maximumBufferedBytes = 2 * 1024 * 1024
    public static let maximumBufferedMessages = 4_096
    public static let negotiationTimeout: TimeInterval = 15
    public static let outboundBackpressureTimeout: TimeInterval = 30
}

public enum PeerTransportRole: Sendable {
    case offerer
    case answerer
}

public enum PeerTransportPolicy: Sendable {
    /// Gather host, server-reflexive, and relay candidates. ICE still prefers a direct path.
    case directAndRelay

    /// Test or force the TURN fallback by gathering relay candidates only.
    case relayOnly
}

public struct PeerIceServer: Codable, Equatable, Sendable {
    public let urls: [String]
    public let username: String?
    public let credential: String?

    public init(
        urls: [String],
        username: String? = nil,
        credential: String? = nil
    ) throws {
        guard !urls.isEmpty, urls.count <= PeerTransportBounds.maximumURLsPerIceServer else {
            throw PeerTransportError.invalidConfiguration(
                "An ICE server must have 1-\(PeerTransportBounds.maximumURLsPerIceServer) URLs."
            )
        }
        for url in urls {
            let normalized = url.lowercased()
            guard url.utf8.count <= 2_048,
                  normalized.hasPrefix("stun:")
                    || normalized.hasPrefix("stuns:")
                    || normalized.hasPrefix("turn:")
                    || normalized.hasPrefix("turns:")
            else {
                throw PeerTransportError.invalidConfiguration("Unsupported ICE server URL.")
            }
        }
        guard (username?.utf8.count ?? 0) <= 1_024,
              (credential?.utf8.count ?? 0) <= 1_024
        else {
            throw PeerTransportError.invalidConfiguration("ICE credentials exceed the size limit.")
        }
        self.urls = urls
        self.username = username
        self.credential = credential
    }

    private enum CodingKeys: String, CodingKey {
        case urls, username, credential
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            urls: container.decode([String].self, forKey: .urls),
            username: container.decodeIfPresent(String.self, forKey: .username),
            credential: container.decodeIfPresent(String.self, forKey: .credential)
        )
    }
}

public struct PeerTransportConfiguration: Equatable, Sendable {
    public let iceServers: [PeerIceServer]
    public let policy: PeerTransportPolicy

    public init(
        iceServers: [PeerIceServer] = [],
        policy: PeerTransportPolicy = .directAndRelay
    ) throws {
        guard iceServers.count <= PeerTransportBounds.maximumIceServers else {
            throw PeerTransportError.invalidConfiguration(
                "At most \(PeerTransportBounds.maximumIceServers) ICE servers are accepted."
            )
        }
        self.iceServers = iceServers
        self.policy = policy
    }
}

extension PeerTransportPolicy: Equatable {}

public struct PeerSessionDescription: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case offer
        case answer
    }

    public let kind: Kind
    public let sdp: String

    public init(kind: Kind, sdp: String) throws {
        guard !sdp.isEmpty,
              sdp.utf8.count <= PeerTransportBounds.maximumSessionDescriptionBytes
        else {
            throw PeerTransportError.invalidSessionDescription
        }
        self.kind = kind
        self.sdp = sdp
    }

    private enum CodingKeys: String, CodingKey {
        case kind, sdp
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            kind: container.decode(Kind.self, forKey: .kind),
            sdp: container.decode(String.self, forKey: .sdp)
        )
    }
}

/// One bounded ICE candidate for authenticated trickle signaling.
public struct PeerIceCandidate: Codable, Equatable, Sendable {
    public static let maximumSDPBytes = 16 * 1_024
    public static let maximumMidBytes = 256

    public let sdp: String
    public let sdpMLineIndex: Int32
    public let sdpMid: String?

    public init(sdp: String, sdpMLineIndex: Int32, sdpMid: String?) throws {
        guard !sdp.isEmpty, sdp.utf8.count <= Self.maximumSDPBytes,
              (sdpMid?.utf8.count ?? 0) <= Self.maximumMidBytes,
              sdpMLineIndex >= 0
        else {
            throw PeerTransportError.invalidIceCandidate
        }
        self.sdp = sdp
        self.sdpMLineIndex = sdpMLineIndex
        self.sdpMid = sdpMid
    }

    private enum CodingKeys: String, CodingKey {
        case sdp, sdpMLineIndex, sdpMid
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sdp: container.decode(String.self, forKey: .sdp),
            sdpMLineIndex: container.decode(Int32.self, forKey: .sdpMLineIndex),
            sdpMid: container.decodeIfPresent(String.self, forKey: .sdpMid)
        )
    }
}

public enum PeerTransportState: Equatable, Sendable {
    case idle
    case gathering
    case connecting
    case open
    case closed
    case failed(String)
}

public enum PeerCandidateKind: String, Equatable, Sendable {
    case host
    case serverReflexive = "srflx"
    case peerReflexive = "prflx"
    case relay
    case unknown
}

public struct PeerTransportRoute: Equatable, Sendable {
    public let localCandidate: PeerCandidateKind
    public let remoteCandidate: PeerCandidateKind
    public let networkProtocol: String?

    public var usesRelay: Bool {
        localCandidate == .relay || remoteCandidate == .relay
    }
}

public struct PeerTransportSnapshot: Equatable, Sendable {
    public let state: PeerTransportState
    public let generatedCandidateCount: Int
    public let outboundBufferedBytes: UInt64
    public let inboundBufferedBytes: Int
    public let inboundBufferedMessages: Int
}

public enum PeerTransportError: Error, Equatable, Sendable {
    case invalidConfiguration(String)
    case invalidSessionDescription
    case invalidIceCandidate
    case unexpectedSessionDescription(expected: PeerSessionDescription.Kind)
    case operationAlreadyPending
    case negotiationTimedOut
    case transportClosed
    case dataChannelNotOpen
    case messageTooLarge(actual: Int, limit: Int)
    case outboundBackpressure(buffered: UInt64, attempted: Int, limit: Int)
    case outboundBackpressureTimedOut(limit: Int)
    case inboundBufferExceeded(limit: Int)
    case inboundMessageLimitExceeded(limit: Int)
    case tooManyIceCandidates(limit: Int)
    case webRTC(String)
}

extension PeerTransportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message):
            return message
        case .invalidSessionDescription:
            return "The session description is empty or exceeds the size limit."
        case .invalidIceCandidate:
            return "The ICE candidate is invalid or exceeds the size limit."
        case .unexpectedSessionDescription(let expected):
            return "Expected a WebRTC \(expected.rawValue)."
        case .operationAlreadyPending:
            return "A transport operation is already pending."
        case .negotiationTimedOut:
            return "WebRTC negotiation timed out."
        case .transportClosed:
            return "The peer transport is closed."
        case .dataChannelNotOpen:
            return "The peer data channel is not open."
        case .messageTooLarge(let actual, let limit):
            return "The message is \(actual) bytes; the limit is \(limit)."
        case .outboundBackpressure(let buffered, let attempted, let limit):
            return "Sending \(attempted) bytes would exceed the \(limit)-byte outbound limit (\(buffered) already buffered)."
        case .outboundBackpressureTimedOut(let limit):
            return "The peer did not drain its \(limit)-byte outbound buffer in time."
        case .inboundBufferExceeded(let limit):
            return "The peer exceeded the \(limit)-byte inbound buffer."
        case .inboundMessageLimitExceeded(let limit):
            return "The peer exceeded the \(limit)-message inbound buffer."
        case .tooManyIceCandidates(let limit):
            return "ICE generated more than \(limit) candidates."
        case .webRTC(let message):
            return message
        }
    }
}

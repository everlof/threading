import Foundation

/// Wire-level bounds for the hosted control plane. Signaling is low-frequency (one exchange per
/// reconnect), but every field is service- or peer-controlled and must be rejected before WebRTC
/// or app state is allocated from it.
public enum PeerRendezvousBounds {
    public static let protocolVersion = 1
    public static let maximumEnvelopeBytes = 384 * 1_024
    public static let maximumIdentifierBytes = 256
    public static let maximumCredentialBytes = 4 * 1_024
    public static let maximumErrorBytes = 1 * 1_024
    public static let maximumSessionLifetime: TimeInterval = 5 * 60
}

public enum PeerRendezvousKind: String, Codable, Sendable {
    case hostHello
    case hostReady
    case deviceConnect
    case incomingSession
    case sessionJoin
    case ready
    case offer
    case answer
    case candidate
    case candidatesComplete
    case close
    case failure
}

/// One strictly validated JSON envelope shared by the Apple clients and hosted rendezvous.
/// Optional fields are constrained by `kind`, so malformed combinations fail before dispatch.
public struct PeerRendezvousEnvelope: Codable, Equatable, Sendable {
    public let version: Int
    public let kind: PeerRendezvousKind
    public let hostID: String?
    public let deviceID: String?
    public let sessionID: String?
    public let sessionToken: String?
    public let expiresAt: Date?
    public let iceServers: [PeerIceServer]?
    public let description: PeerSessionDescription?
    public let candidate: PeerIceCandidate?
    public let errorCode: String?
    public let errorMessage: String?

    public init(
        kind: PeerRendezvousKind,
        hostID: String? = nil,
        deviceID: String? = nil,
        sessionID: String? = nil,
        sessionToken: String? = nil,
        expiresAt: Date? = nil,
        iceServers: [PeerIceServer]? = nil,
        description: PeerSessionDescription? = nil,
        candidate: PeerIceCandidate? = nil,
        errorCode: String? = nil,
        errorMessage: String? = nil,
        now: Date = Date()
    ) throws {
        version = PeerRendezvousBounds.protocolVersion
        self.kind = kind
        self.hostID = hostID
        self.deviceID = deviceID
        self.sessionID = sessionID
        self.sessionToken = sessionToken
        self.expiresAt = Self.normalizedExpiry(expiresAt)
        self.iceServers = iceServers
        self.description = description
        self.candidate = candidate
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        try validate(now: now)
    }

    private enum CodingKeys: String, CodingKey {
        case version, kind, hostID, deviceID, sessionID, sessionToken, expiresAt, iceServers
        case description, candidate, errorCode, errorMessage
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        kind = try container.decode(PeerRendezvousKind.self, forKey: .kind)
        hostID = try container.decodeIfPresent(String.self, forKey: .hostID)
        deviceID = try container.decodeIfPresent(String.self, forKey: .deviceID)
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
        sessionToken = try container.decodeIfPresent(String.self, forKey: .sessionToken)
        expiresAt = Self.normalizedExpiry(
            try container.decodeIfPresent(Date.self, forKey: .expiresAt)
        )
        iceServers = try container.decodeIfPresent([PeerIceServer].self, forKey: .iceServers)
        description = try container.decodeIfPresent(
            PeerSessionDescription.self,
            forKey: .description
        )
        candidate = try container.decodeIfPresent(PeerIceCandidate.self, forKey: .candidate)
        errorCode = try container.decodeIfPresent(String.self, forKey: .errorCode)
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
        try validate(now: Date())
    }

    public func encoded() throws -> Data {
        try validate(now: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(self)
        guard data.count <= PeerRendezvousBounds.maximumEnvelopeBytes else {
            throw PeerRendezvousError.envelopeTooLarge(
                actual: data.count,
                limit: PeerRendezvousBounds.maximumEnvelopeBytes
            )
        }
        return data
    }

    public static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= PeerRendezvousBounds.maximumEnvelopeBytes else {
            throw PeerRendezvousError.envelopeTooLarge(
                actual: data.count,
                limit: PeerRendezvousBounds.maximumEnvelopeBytes
            )
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(Self.self, from: data)
    }

    private func validate(now: Date) throws {
        guard version == PeerRendezvousBounds.protocolVersion else {
            throw PeerRendezvousError.unsupportedVersion(version)
        }
        try Self.validateIdentifier(hostID)
        try Self.validateIdentifier(deviceID)
        try Self.validateIdentifier(sessionID)
        try Self.validateCredential(sessionToken)
        try Self.validateError(errorCode)
        try Self.validateError(errorMessage)
        if let iceServers {
            guard !iceServers.isEmpty,
                  iceServers.count <= PeerTransportBounds.maximumIceServers else {
                throw PeerRendezvousError.invalidEnvelope
            }
        }
        if let expiresAt {
            guard expiresAt > now.addingTimeInterval(-5),
                  expiresAt <= now.addingTimeInterval(
                    PeerRendezvousBounds.maximumSessionLifetime + 5
                  ) else {
                throw PeerRendezvousError.invalidExpiry
            }
        }

        let valid: Bool
        switch kind {
        case .hostHello:
            valid = hostID != nil && deviceID == nil && sessionID == nil
                && allPayloadFieldsAreNil()
        case .hostReady:
            valid = hostID != nil && deviceID == nil && sessionID == nil
                && allPayloadFieldsAreNil()
        case .deviceConnect:
            valid = hostID != nil && deviceID != nil && sessionID == nil
                && allPayloadFieldsAreNil()
        case .incomingSession:
            valid = hostID != nil && deviceID != nil && sessionID != nil
                && sessionToken != nil && expiresAt != nil && description == nil
                && candidate == nil && iceServers == nil
                && errorCode == nil && errorMessage == nil
        case .sessionJoin:
            valid = hostID == nil && deviceID == nil && sessionID != nil
                && allPayloadFieldsAreNil()
        case .ready:
            valid = hostID == nil && deviceID == nil && sessionID != nil
                && sessionToken == nil && expiresAt != nil && iceServers != nil
                && description == nil && candidate == nil
                && errorCode == nil && errorMessage == nil
        case .offer:
            valid = signalIdentityFieldsAreNil() && sessionID != nil
                && description?.kind == .offer && candidate == nil
        case .answer:
            valid = signalIdentityFieldsAreNil() && sessionID != nil
                && description?.kind == .answer && candidate == nil
        case .candidate:
            valid = signalIdentityFieldsAreNil() && sessionID != nil
                && candidate != nil && description == nil
        case .candidatesComplete, .close:
            valid = hostID == nil && deviceID == nil && sessionID != nil
                && allPayloadFieldsAreNil()
        case .failure:
            valid = hostID == nil && deviceID == nil && sessionToken == nil
                && expiresAt == nil && errorCode != nil && errorMessage != nil
                && description == nil && candidate == nil && iceServers == nil
        }
        guard valid else { throw PeerRendezvousError.invalidEnvelope }
    }

    private func allPayloadFieldsAreNil() -> Bool {
        sessionToken == nil && expiresAt == nil && iceServers == nil
            && description == nil && candidate == nil && errorCode == nil && errorMessage == nil
    }

    private func signalIdentityFieldsAreNil() -> Bool {
        hostID == nil && deviceID == nil && sessionToken == nil && expiresAt == nil
            && iceServers == nil && errorCode == nil && errorMessage == nil
    }

    private static func validateIdentifier(_ value: String?) throws {
        guard let value else { return }
        guard !value.isEmpty,
              value.utf8.count <= PeerRendezvousBounds.maximumIdentifierBytes else {
            throw PeerRendezvousError.invalidEnvelope
        }
    }

    private static func validateCredential(_ value: String?) throws {
        guard let value else { return }
        guard !value.isEmpty,
              value.utf8.count <= PeerRendezvousBounds.maximumCredentialBytes else {
            throw PeerRendezvousError.invalidEnvelope
        }
    }

    private static func validateError(_ value: String?) throws {
        guard let value else { return }
        guard !value.isEmpty, value.utf8.count <= PeerRendezvousBounds.maximumErrorBytes else {
            throw PeerRendezvousError.invalidEnvelope
        }
    }

    /// Session expiry is deliberately whole-second metadata. Normalizing before validation and
    /// encoding avoids equality and cache-key drift from JSON floating-point date round trips.
    private static func normalizedExpiry(_ value: Date?) -> Date? {
        value.map { Date(timeIntervalSince1970: floor($0.timeIntervalSince1970)) }
    }
}

public enum PeerRendezvousError: Error, Equatable, Sendable {
    case invalidEndpoint
    case invalidCredential
    case invalidEnvelope
    case unsupportedVersion(Int)
    case invalidExpiry
    case envelopeTooLarge(actual: Int, limit: Int)
    case unauthorized
    case hostOffline
    case sessionExpired
    case timedOut
    case service(String)
    case connectionClosed
}

extension PeerRendezvousError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "The hosted rendezvous endpoint is invalid."
        case .invalidCredential:
            return "The hosted rendezvous credential is invalid."
        case .invalidEnvelope:
            return "The hosted rendezvous message is invalid."
        case .unsupportedVersion(let version):
            return "Hosted rendezvous protocol version \(version) is unsupported."
        case .invalidExpiry:
            return "The hosted rendezvous session expiry is invalid."
        case .envelopeTooLarge(let actual, let limit):
            return "The hosted rendezvous message is \(actual) bytes; the limit is \(limit)."
        case .unauthorized:
            return "This device is not authorized for the hosted remote service."
        case .hostOffline:
            return "The Mac is not connected to the hosted remote service."
        case .sessionExpired:
            return "The hosted rendezvous session expired."
        case .timedOut:
            return "The hosted rendezvous service did not respond in time."
        case .service(let message):
            return message
        case .connectionClosed:
            return "The hosted rendezvous connection closed."
        }
    }
}

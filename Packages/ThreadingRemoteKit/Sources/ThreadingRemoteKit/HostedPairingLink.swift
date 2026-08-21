import Foundation

/// A one-time route for pairing an iPhone before it has a durable Mac-issued capability.
///
/// Every secret stays in a custom URL fragment, so scanning or pasting the value cannot send it
/// to an HTTP server, proxy log, or referrer. The hosted rendezvous credential only opens an
/// encrypted tunnel to the Mac's loopback remote server; `bootstrapToken` is still the authority
/// that must be redeemed there, preserving the existing pairing and authorization contract.
public struct HostedPairingLink: Equatable, Hashable, Sendable {
    public static let maximumEncodedBytes = 8 * 1_024

    public let serviceURL: URL
    public let hostID: String
    public let deviceID: String
    public let rendezvousCredential: String
    public let bootstrapToken: String
    public let expiresAt: Date

    private struct Payload: Codable {
        let v: Int
        let s: String
        let h: String
        let d: String
        let c: String
        let b: String
        let e: Double
    }

    public init?(
        serviceURL: URL,
        hostID: String,
        deviceID: String,
        rendezvousCredential: String,
        bootstrapToken: String,
        expiresAt: Date,
        now: Date = Date()
    ) {
        guard let serviceURL = Self.normalizedServiceURL(serviceURL),
              Self.isIdentifier(hostID),
              Self.isIdentifier(deviceID),
              Self.isSecret(rendezvousCredential),
              Self.isSecret(bootstrapToken),
              expiresAt > now,
              expiresAt <= now.addingTimeInterval(370 * 24 * 60 * 60) else {
            return nil
        }
        self.serviceURL = serviceURL
        self.hostID = hostID
        self.deviceID = deviceID
        self.rendezvousCredential = rendezvousCredential
        self.bootstrapToken = bootstrapToken
        self.expiresAt = expiresAt
    }

    public init?(string: String, now: Date = Date()) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= Self.maximumEncodedBytes,
              let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "threading",
              components.host?.lowercased() == "pair",
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.path.isEmpty,
              components.query == nil,
              let fragment = components.fragment,
              let data = Data(
                base64URLEncoded: fragment,
                maximumBytes: Self.maximumEncodedBytes
              ),
              data.count <= Self.maximumEncodedBytes,
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.v == 1,
              let serviceURL = URL(string: payload.s),
              let validated = Self(
                serviceURL: serviceURL,
                hostID: payload.h,
                deviceID: payload.d,
                rendezvousCredential: payload.c,
                bootstrapToken: payload.b,
                expiresAt: Date(timeIntervalSince1970: payload.e),
                now: now
              ) else {
            return nil
        }
        self = validated
    }

    public var scannablePayload: String {
        let payload = Payload(
            v: 1,
            s: serviceURL.absoluteString,
            h: hostID,
            d: deviceID,
            c: rendezvousCredential,
            b: bootstrapToken,
            e: expiresAt.timeIntervalSince1970
        )
        guard let data = try? JSONEncoder().encode(payload) else { return "" }
        return "THREADING://PAIR#\(data.base64URLEncodedString())"
    }

    public var isExpired: Bool { expiresAt <= Date() }

    private static func normalizedServiceURL(_ url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              scheme == "https" || (scheme == "http" && Self.isLoopback(host)) else {
            return nil
        }
        components.scheme = scheme
        components.host = host
        components.path = ""
        return components.url
    }

    private static func isIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 45, 46, 48...57, 58, 65...90, 95, 97...122: true
            default: false
            }
        }
    }

    private static func isSecret(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 4 * 1_024
            && value.unicodeScalars.allSatisfy { $0.value >= 0x21 && $0.value != 0x7f }
    }

    private static func isLoopback(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1" || host == "::1"
    }
}

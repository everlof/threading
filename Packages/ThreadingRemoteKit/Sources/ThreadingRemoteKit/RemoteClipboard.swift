import Foundation

/// Additive, live-only clipboard delivery. Older clients never announce readiness.
public enum RemoteClipboardPolicy {
    public static let maximumTextBytes = 64 * 1_024
    public static let readyType = "clipboardReady"
    public static let writeType = "clipboardWrite"
    public static let resultType = "clipboardResult"
    public static let lifetimeSeconds: TimeInterval = 10
}

public struct RemoteClipboardWrite: Codable, Equatable, Sendable {
    public let type: String
    public let requestID: String
    public let text: String
    public let expiresAt: TimeInterval

    public init(requestID: String, text: String, expiresAt: TimeInterval) {
        type = RemoteClipboardPolicy.writeType
        self.requestID = requestID
        self.text = text
        self.expiresAt = expiresAt
    }
}

public enum RemoteClipboardResult: String, Codable, Sendable {
    case copied
    case inactive
    case expired
    case invalid
    case failed
}

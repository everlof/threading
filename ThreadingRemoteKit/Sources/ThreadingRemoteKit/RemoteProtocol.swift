import Foundation

/// The remote-access protocol version, and the rule for deciding whether two ends can talk.
///
/// Both the server and every client carry a compiled-in `current` version and the oldest peer
/// they still understand (`minimumSupported`). When a client connects it declares its pair, and
/// the server decides — so a mismatch produces a **clear "please update" message pointing at the
/// right side**, not a cryptic decode failure three frames later.
///
/// Bump `current` on any breaking wire change; raise `minimumSupported` only when support for an
/// old peer is actually dropped.
public enum RemoteProtocol {
    /// The wire version this build speaks.
    public static let current = 1
    /// The oldest peer version this build still understands.
    public static let minimumSupported = 1
}

/// A version pair, as it crosses the wire in both directions.
public struct RemoteProtocolInfo: Codable, Equatable {
    public let version: Int
    public let minimumSupported: Int

    public init(version: Int = RemoteProtocol.current, minimumSupported: Int = RemoteProtocol.minimumSupported) {
        self.version = version
        self.minimumSupported = minimumSupported
    }
}

/// The outcome of comparing a peer's version pair against this build. It names *which* side is
/// behind, because that decides what the user is told: refresh/update the client, or update the
/// Mac app.
public enum RemoteProtocolCompatibility: String, Codable, Equatable {
    case compatible
    /// The peer is older than we support — it should update.
    case peerTooOld
    /// We are older than the peer supports — this build should update.
    case selfTooOld

    /// Evaluated from the perspective of *this* build against a peer's declared pair.
    public static func evaluate(peerVersion: Int, peerMinimumSupported: Int) -> RemoteProtocolCompatibility {
        if peerVersion < RemoteProtocol.minimumSupported { return .peerTooOld }
        if RemoteProtocol.current < peerMinimumSupported { return .selfTooOld }
        return .compatible
    }

    public static func evaluate(peer: RemoteProtocolInfo) -> RemoteProtocolCompatibility {
        evaluate(peerVersion: peer.version, peerMinimumSupported: peer.minimumSupported)
    }
}

/// Where a `RemoteProtocolCompatibility` mismatch, seen by the server, says the fix lives — so
/// the client can render the right sentence without re-deriving the direction.
public enum RemoteUpdateTarget: String, Codable, Equatable {
    /// The connecting client (web tab or app) is behind and should update or reload.
    case client
    /// The Mac running Threading is behind and should update.
    case host
}

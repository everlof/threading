import Foundation

/// Which edition of the session catalogue a `/api/me` body or a `sessionsChanged` delta describes.
///
/// A monotonic count would collide across Mac launches — a restarted host starts counting again
/// from one — so the count is qualified by an epoch the host mints once per process. Two values
/// are the same catalogue only when both halves match; a client that remembers one and finds the
/// host on a different epoch simply fetches in full, which is the right answer for "the Mac was
/// restarted and I do not know what changed".
///
/// The entity tag is the same value in the shape HTTP conditional requests expect, so a phone can
/// send it back as `If-None-Match` and be answered `304 Not Modified` without either side parsing
/// prose. `Cache-Control: no-store` stays on every response: this is application-level freshness,
/// not a shared cache, and nothing here permits a browser or proxy to keep the body.
public struct RemoteCatalogueRevisionDTO: Codable, Equatable, Hashable, Sendable {
    /// One process-lifetime token, opaque to clients.
    public let epoch: String
    /// Advances by one for every catalogue invalidation within `epoch`.
    public let revision: UInt64

    public init(epoch: String, revision: UInt64) {
        self.epoch = epoch
        self.revision = revision
    }

    /// A fresh epoch for a host that has just started.
    public static func newEpoch() -> String {
        UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(16).description
    }

    /// The `ETag` this revision is served under: a strong validator, quoted per RFC 9110.
    public var entityTag: String {
        "\"\(epoch):\(revision)\""
    }

    /// Reads a validator back off the wire, tolerating the weak-validator prefix and a bare
    /// unquoted value. Nil for anything that is not one of ours.
    public init?(entityTag: String) {
        var value = entityTag.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("W/") { value.removeFirst(2) }
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            value = String(value.dropFirst().dropLast())
        }
        let parts = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              !parts[0].isEmpty,
              let revision = UInt64(parts[1]) else { return nil }
        self.epoch = String(parts[0])
        self.revision = revision
    }

    /// Whether an `If-None-Match` header names this revision. The header may list several
    /// validators; any one matching is enough, and `*` matches nothing here because a client
    /// that has no catalogue at all must receive one.
    public func matches(ifNoneMatch header: String?) -> Bool {
        guard let header else { return false }
        return header
            .split(separator: ",")
            .compactMap { RemoteCatalogueRevisionDTO(entityTag: String($0)) }
            .contains(self)
    }
}

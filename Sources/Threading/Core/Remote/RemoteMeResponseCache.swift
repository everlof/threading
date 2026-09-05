import Foundation
import ThreadingRemoteKit

// MARK: - Encoded Response

/// One `/api/me` body, encoded once and served to every request that asks for the same catalogue
/// edition with the same authorization.
///
/// Encoding is the part of `/api/me` that scaled with the catalogue and ran on the main queue:
/// `JSONEncoder` over tens of rows per device per refresh, inside the same `DispatchQueue.main`
/// block that projected them. The projection is main-actor state and stays there; the bytes are
/// not, so they are produced on a worker and remembered here until the catalogue moves.
struct RemoteMeEncodedResponse: Sendable {
    let revision: RemoteCatalogueRevisionDTO
    let json: Data
    /// The same body in the gzip container, or nil when it is too small to be worth compressing.
    let gzip: Data?

    /// Encodes off whatever actor the caller is on. Pure: reads only its argument.
    static func encode(
        _ payload: RemoteMeDTO,
        revision: RemoteCatalogueRevisionDTO
    ) throws -> RemoteMeEncodedResponse {
        let json = try JSONEncoder().encode(payload)
        let gzip = json.count >= RemoteMeResponseDefaults.minimumCompressedBytes
            ? GzipWriter.compress(json)
            : nil
        return RemoteMeEncodedResponse(revision: revision, json: json, gzip: gzip)
    }
}

/// What the main actor hands a `/api/me` handler: either a body already encoded for this
/// authorization at the current edition, or the payload to encode on a worker. Exactly one of
/// the two is present.
struct RemoteMeResponseSnapshot: Sendable {
    let payload: RemoteMeDTO?
    let encoded: RemoteMeEncodedResponse?
    let revision: RemoteCatalogueRevisionDTO
}

// MARK: - Cache

/// What tells one `/api/me` body from another, apart from the catalogue edition itself.
///
/// The share label, capability, scope, principal and member all reach the payload — the owner's
/// projection is shared across devices but each device's `share` block names its own label — so
/// a body is keyed by every one of them. A guest scoped to one session never collides with an
/// owner, and two owner devices each hold their own entry.
struct RemoteMeResponseKey: Hashable, Sendable {
    let shareID: String
    let capability: RemoteCapability
    let scope: String
    let isOwnerDevice: Bool
    let memberID: String?

    init(_ authorization: RemoteAuthorization) {
        shareID = authorization.shareID
        capability = authorization.capability
        switch authorization.scope {
        case .allSessions: scope = "all"
        case let .session(id): scope = "session:\(id.uuidString)"
        case let .projectTerminal(id): scope = "terminal:\(id.uuidString)"
        }
        isOwnerDevice = authorization.principal == .ownerDevice
        memberID = authorization.member?.id
    }
}

/// Encoded `/api/me` bodies for the current catalogue edition, bounded by device count rather
/// than by time: a body is valid until the catalogue changes, and every change empties the cache.
///
/// A value type owned by `RemoteSessionMirrorRegistry`, so it inherits the registry's main-actor
/// isolation without a lock of its own. The bound is the number of distinct authorizations that
/// may reasonably be asking at once — one per admitted connection — and a store past it evicts
/// the entry that has gone longest without being served.
struct RemoteMeResponseCache {
    private struct Entry {
        let response: RemoteMeEncodedResponse
        var lastServed: UInt64
    }

    private var entries: [RemoteMeResponseKey: Entry] = [:]
    private var revision: RemoteCatalogueRevisionDTO?
    private var tick: UInt64 = 0
    private let capacity: Int

    init(capacity: Int = RemoteMeResponseDefaults.cacheCapacity) {
        self.capacity = capacity
    }

    var count: Int { entries.count }

    /// The body for this authorization at this revision, if one was encoded already.
    mutating func response(
        for key: RemoteMeResponseKey,
        revision current: RemoteCatalogueRevisionDTO
    ) -> RemoteMeEncodedResponse? {
        guard revision == current, var entry = entries[key] else { return nil }
        tick &+= 1
        entry.lastServed = tick
        entries[key] = entry
        return entry.response
    }

    /// Remembers a body. One encoded against an edition that has since moved is dropped, since
    /// the worker that produced it cannot know the catalogue changed while it ran.
    mutating func store(
        _ response: RemoteMeEncodedResponse,
        for key: RemoteMeResponseKey,
        revision current: RemoteCatalogueRevisionDTO
    ) {
        guard response.revision == current else { return }
        if revision != current {
            entries.removeAll(keepingCapacity: true)
            revision = current
        }
        tick &+= 1
        if entries[key] == nil, entries.count >= capacity,
           let oldest = entries.min(by: { $0.value.lastServed < $1.value.lastServed })?.key {
            entries.removeValue(forKey: oldest)
        }
        entries[key] = Entry(response: response, lastServed: tick)
    }

    mutating func removeAll() {
        entries.removeAll(keepingCapacity: true)
        revision = nil
    }
}

// MARK: - Defaults

enum RemoteMeResponseDefaults {
    /// Below this the gzip framing and the CPU are not worth it; a catalogue of a few sessions
    /// fits in one packet either way.
    static let minimumCompressedBytes = 4 * 1024
    /// Distinct authorizations whose bodies are kept per catalogue edition. Sized to the
    /// connection admission cap: more distinct bodies than that cannot be in flight at once.
    static let cacheCapacity = 16
}

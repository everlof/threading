import SwiftUI
import ThreadingRemoteKit
import UIKit

/// Request lifecycle is separate from cache residency. A successful request is suppressed while
/// its value is cached, then becomes eligible again if capacity eviction removes that value.
///
/// A failure is two different facts. A *terminal* one — the Mac answered 404, or sent bytes no
/// decoder accepts — stays suppressed for the owner's lifetime, so an unsupported request does
/// not repeatedly cost the link. A *transient* one — the connection under the request went away
/// — says nothing about the attachment, only about the moment, so it is suppressed until the
/// route moves and then asked again. The audit of 4–5 Sep 2026 found 27 previews lost to exactly
/// that moment, every one of them kept lost for as long as the gallery stayed open.
struct RemoteAttachmentThumbnailRequestState {
    enum Outcome {
        case success
        case failure
        case transientFailure
        case cancelled
    }

    private var inFlight: Set<String> = []
    private var failures: Set<String> = []
    private var transientFailures: Set<String> = []

    mutating func begin(id: String, isCached: Bool) -> Bool {
        guard !isCached,
              !inFlight.contains(id),
              !failures.contains(id),
              !transientFailures.contains(id) else { return false }
        inFlight.insert(id)
        return true
    }

    mutating func finish(id: String, outcome: Outcome) {
        inFlight.remove(id)
        switch outcome {
        case .failure: failures.insert(id)
        case .transientFailure: transientFailures.insert(id)
        case .success, .cancelled: break
        }
    }

    /// The route moved, so every request the old one lost is worth asking again.
    mutating func forgetTransientFailures() {
        transientFailures.removeAll()
    }
}

/// A bounded thumbnail cache whose fetch boundary is supplied by its owner. Keeping DTO and client
/// details outside this type makes the cache invariant independent of the transport vocabulary.
///
/// The client is handed in and replaced, not captured: a `StateObject` outlives every rebuild of
/// the view that made it, and a fetch closure that closed over the client of the first build
/// went on dialling that origin after the model had moved the phone to another. Whoever owns
/// the store tells it the current client whenever the route identity changes.
@MainActor
final class RemoteAttachmentThumbnailStore: ObservableObject {
    /// Fetches one thumbnail through the client the store holds now. The client is nil only in
    /// tests that supply their own bytes.
    typealias Fetch = @Sendable (_ id: String, _ client: RemoteClient?) async throws -> Data

    static let capacity = 200

    @Published private(set) var images: [String: UIImage] = [:]
    private let isOffered: Bool
    private let fetch: Fetch
    private let limiter: MobileMediaDownloadLimiter
    private var requests = RemoteAttachmentThumbnailRequestState()
    private var order: [String] = []
    private(set) var client: RemoteClient?

    init(
        isOffered: Bool,
        client: RemoteClient? = nil,
        seed: [String: UIImage] = [:],
        limiter: MobileMediaDownloadLimiter = .thumbnails,
        fetch: @escaping Fetch
    ) {
        self.isOffered = isOffered
        self.client = client
        self.fetch = fetch
        self.limiter = limiter
        for (id, image) in seed { store(image, for: id) }
    }

    func image(for id: String) -> UIImage? {
        images[id]
    }

    /// Follows the model to a new route. Thumbnails the old route lost become askable again;
    /// ones the Mac refused stay refused, since the Mac has not changed.
    func adopt(client: RemoteClient) {
        let moved = self.client.map {
            $0.link.baseURL != client.link.baseURL || $0.endpointKind != client.endpointKind
        } ?? true
        self.client = client
        if moved {
            requests.forgetTransientFailures()
        }
    }

    func load(id: String, hasThumbnail: Bool) async {
        guard isOffered,
              hasThumbnail,
              requests.begin(id: id, isCached: images[id] != nil) else { return }
        let client = self.client
        let fetch = self.fetch
        do {
            let data = try await limiter.run { try await fetch(id, client) }
            guard let image = UIImage(data: data) else {
                requests.finish(id: id, outcome: .failure)
                recordFailure(id: id, code: RemoteAttachmentThumbnailDefaults.undecodableCode, transient: false)
                return
            }
            store(image, for: id)
            requests.finish(id: id, outcome: .success)
        } catch {
            guard RemoteAttachmentPreviewFailure.message(for: error) != nil else {
                requests.finish(id: id, outcome: .cancelled)
                return
            }
            let transient = RemoteTransientTransportFailure.isTransient(error)
            requests.finish(id: id, outcome: transient ? .transientFailure : .failure)
            recordFailure(id: id, code: MobileDiagnostics.errorCode(error), transient: transient)
            MobileDiagnostics.logDegraded(.attachmentContent, error: error)
        }
    }

    // MARK: - Private Methods

    /// The share-safe journal line a lost thumbnail leaves, with the route it was lost on. A
    /// preview page has recorded its own for a long time; the ledger's failures were only ever
    /// in the unified log, which is why an audit could count them but not place them.
    private func recordFailure(id: String, code: String, transient: Bool) {
        var fields: [RemoteDiagnosticField: String] = [
            .kind: RemoteAttachmentThumbnailDefaults.diagnosticKind,
            .code: code,
            .detail: transient
                ? RemoteAttachmentThumbnailDefaults.transientDetail
                : RemoteAttachmentThumbnailDefaults.terminalDetail,
        ]
        if let client {
            fields[.transport] = client.endpointKind.rawValue
            fields[.origin] = MobileDiagnostics.originDigest(client.link.baseURL)
        }
        MobileDiagnostics.record(.attachmentPreviewFailed, level: .warning, fields: fields)
    }

    private func store(_ image: UIImage, for id: String) {
        images[id] = image
        order.append(id)
        while order.count > Self.capacity, let oldest = order.first {
            order.removeFirst()
            images.removeValue(forKey: oldest)
        }
    }
}

enum RemoteAttachmentThumbnailDefaults {
    /// The `kind` a ledger thumbnail records under, beside the preview kinds a page records.
    static let diagnosticKind = "thumbnail"
    static let transientDetail = "transient"
    static let terminalDetail = "terminal"
    static let undecodableCode = "image.undecodable"
}

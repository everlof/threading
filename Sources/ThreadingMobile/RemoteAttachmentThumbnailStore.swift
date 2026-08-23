import SwiftUI
import UIKit

/// Request lifecycle is separate from cache residency. A successful request is suppressed while
/// its value is cached, then becomes eligible again if capacity eviction removes that value.
/// Genuine failures stay suppressed for the owner's lifetime so an unsupported request does not
/// repeatedly cost the link.
struct RemoteAttachmentThumbnailRequestState {
    enum Outcome {
        case success
        case failure
        case cancelled
    }

    private var inFlight: Set<String> = []
    private var failures: Set<String> = []

    mutating func begin(id: String, isCached: Bool) -> Bool {
        guard !isCached, !inFlight.contains(id), !failures.contains(id) else { return false }
        inFlight.insert(id)
        return true
    }

    mutating func finish(id: String, outcome: Outcome) {
        inFlight.remove(id)
        if case .failure = outcome {
            failures.insert(id)
        }
    }
}

/// A bounded thumbnail cache whose fetch boundary is supplied by its owner. Keeping DTO and client
/// details outside this type makes the cache invariant independent of the transport vocabulary.
@MainActor
final class RemoteAttachmentThumbnailStore: ObservableObject {
    typealias Fetch = (_ id: String) async throws -> Data

    static let capacity = 200

    @Published private(set) var images: [String: UIImage] = [:]
    private let isOffered: Bool
    private let fetch: Fetch
    private var requests = RemoteAttachmentThumbnailRequestState()
    private var order: [String] = []

    init(
        isOffered: Bool,
        seed: [String: UIImage] = [:],
        fetch: @escaping Fetch
    ) {
        self.isOffered = isOffered
        self.fetch = fetch
        for (id, image) in seed { store(image, for: id) }
    }

    func image(for id: String) -> UIImage? {
        images[id]
    }

    func load(id: String, hasThumbnail: Bool) async {
        guard isOffered,
              hasThumbnail,
              requests.begin(id: id, isCached: images[id] != nil) else { return }
        do {
            let data = try await fetch(id)
            guard let image = UIImage(data: data) else {
                requests.finish(id: id, outcome: .failure)
                return
            }
            store(image, for: id)
            requests.finish(id: id, outcome: .success)
        } catch {
            guard RemoteAttachmentPreviewFailure.message(for: error) != nil else {
                requests.finish(id: id, outcome: .cancelled)
                return
            }
            requests.finish(id: id, outcome: .failure)
            MobileDiagnostics.logDegraded(.attachmentContent, error: error)
        }
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

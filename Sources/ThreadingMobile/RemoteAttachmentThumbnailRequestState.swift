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

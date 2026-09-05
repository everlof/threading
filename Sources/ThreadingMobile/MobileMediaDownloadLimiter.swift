import Foundation

/// How many media downloads of one kind may be in flight at once.
///
/// A gallery's ledger asks for every thumbnail the lazy row materialises and its pages ask for
/// whole files, all into one shared `URLSession` whose host answers each with `Connection:
/// close`. The audit of 4–5 Sep 2026 found 27 previews lost to `URLError.networkConnectionLost`
/// while the catalogue and terminal sockets beside them were healthy — the shape of a burst of
/// short-lived connections racing a pool, an idle timer and an admission cap, not of a bad link.
/// A bound here turns that burst into a queue: the same requests, a few at a time.
///
/// An actor rather than a semaphore because a waiter has to be able to leave: SwiftUI cancels a
/// lazy cell's task the moment the cell scrolls out of the retained window, and a cancelled
/// waiter that still took its turn would spend a slot on a picture nobody is looking at.
actor MobileMediaDownloadLimiter {
    /// Ledger thumbnails: many, small, and all wanted at once.
    static let thumbnails = MobileMediaDownloadLimiter(
        capacity: MobileMediaDownloadDefaults.concurrentThumbnails
    )
    /// Whole attachments and the pieces of a movie: few, and up to 24 MB each.
    static let previews = MobileMediaDownloadLimiter(
        capacity: MobileMediaDownloadDefaults.concurrentPreviews
    )

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    let capacity: Int
    private(set) var inUse = 0
    private var waiters: [Waiter] = []

    init(capacity: Int) {
        self.capacity = max(capacity, 1)
    }

    var waiting: Int { waiters.count }

    /// Runs `operation` once a slot is free, releasing it however the operation ends.
    func run<Value: Sendable>(
        _ operation: @Sendable () async throws -> Value
    ) async throws -> Value {
        try await acquire()
        defer { release() }
        return try await operation()
    }

    // MARK: - Private Methods

    private func acquire() async throws {
        try Task.checkCancellation()
        if inUse < capacity {
            inUse += 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.abandon(id) }
        }
    }

    /// Hands the slot straight to the next waiter, or frees it when nobody is waiting.
    private func release() {
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.continuation.resume()
        } else {
            inUse = max(inUse - 1, 0)
        }
    }

    private func abandon(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }
}

enum MobileMediaDownloadDefaults {
    static let concurrentThumbnails = 4
    static let concurrentPreviews = 2
}

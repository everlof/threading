import Foundation

/// Writes the stream to a store, off the pane's thread.
///
/// The pane drains on a 100 ms timer on the main actor. At the rate a paired device produces —
/// ~5,800 rows/sec — that is ~580 rows a tick, and writing them where they arrive would put a
/// measured ~17 ms of SQLite on the main thread ten times a second. So the batch is handed to a
/// serial queue that owns the store, and the pane goes back to drawing.
///
/// Failing to record is not failing to show. A store that will not open, or a write that fails,
/// leaves the pane exactly as it was before there was one: the rows are still on screen, and only
/// the queries that need history stop working. That is why nothing here throws at the caller.
public final class DeviceLogRecorder {

    private let queue = DispatchQueue(label: "codes.threading.devicelogs.recorder", qos: .utility)
    private var store: DeviceLogStore?
    private var writtenSinceTrim = 0

    /// Rows kept on disk. Larger than the pane's ring on purpose — the ring is what a table can
    /// hold, this is what a question can reach back through.
    public static let retainedRows = 500_000

    /// How many rows may be written before the oldest are dropped. Trimming on every batch would
    /// run a delete ten times a second for no benefit.
    private static let trimInterval = 50_000

    public private(set) var url: URL?

    public init(directory: URL, name: String) {
        let file = directory.appendingPathComponent("\(name).sqlite")
        queue.async { [weak self] in
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard let opened = try? DeviceLogStore(url: file) else { return }
            self?.store = opened
            self?.url = file
        }
    }

    /// Takes a batch. Returns immediately; the write happens on the queue.
    public func record(_ batch: [DeviceLogRow]) {
        guard !batch.isEmpty else { return }
        queue.async { [weak self] in
            guard let self, let store = self.store else { return }
            try? store.append(batch)
            self.writtenSinceTrim += batch.count
            if self.writtenSinceTrim >= Self.trimInterval {
                self.writtenSinceTrim = 0
                try? store.trim(to: Self.retainedRows)
            }
        }
    }

    /// Runs `work` against the store on its own queue. The store is single-threaded by design, so
    /// a reader asks here rather than holding the handle.
    public func read<T: Sendable>(_ work: @escaping @Sendable (DeviceLogStore) throws -> T,
                                  completion: @escaping @Sendable (Result<T, Error>) -> Void) {
        queue.async { [weak self] in
            guard let store = self?.store else {
                return completion(.failure(DeviceLogStore.StoreError.open("no store")))
            }
            completion(Result { try work(store) })
        }
    }
}

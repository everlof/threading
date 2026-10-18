import Foundation

/// Keeps the directory of recorded log histories bounded.
///
/// Each pane's store is capped at `DeviceLogRecorder.retainedRows`, but the *number* of stores was
/// not: one is named per owning session and none was ever removed. Measured on 2026-10-17 the
/// directory held **13,482 files in 6.2 GB**, growing by about 1,400 files a day, and only **6 of its
/// 2,186 stores belonged to a session that still existed** — the rest were made by hosted tests
/// constructing panes with fresh session ids against the real Caches folder (now redirected; see
/// `DeviceLogPaneViewController.storeDirectory`) and by sessions long since deleted.
///
/// The plugin does not know which sessions exist, and should not have to: these are caches — a log
/// history is reconstructible by watching again — so the bound is the one a cache takes. A store
/// nobody has written for `maximumAge` goes; then, oldest first, as many as it takes to bring the
/// directory under `byteBudget`. The store being opened is never touched.
///
/// It runs once per process, on the first recorder's utility queue, before that store opens. The directory is
/// listed once and every candidate is measured from that one listing; nothing here runs on the
/// pane's thread.
enum DeviceLogStoreRetention {

    /// A history untouched for two weeks belongs to a session nobody is debugging.
    static let maximumAge: TimeInterval = 14 * 24 * 60 * 60

    /// Room for about a dozen full stores — far more history than anyone is reading at once.
    static let byteBudget: Int64 = 4 * 1_000_000_000

    /// Files examined in one sweep. The measured directory held 13,482; past this a sweep works
    /// through what it listed, and the next launch continues.
    static let maximumEntries = 50_000

    /// The SQLite sidecars that belong to a store and go with it.
    private static let sidecarSuffixes = ["-wal", "-shm", "-journal"]

    struct Outcome: Equatable {
        var removedStores = 0
        var removedBytes: Int64 = 0
    }

    // MARK: - Once per process

    private static let lock = NSLock()
    nonisolated(unsafe) private static var hasSwept = false

    /// Sweeps `directory` the first time any recorder in this process opens a store there, and
    /// does nothing every time after. Called on the recorder's own queue before it opens its
    /// store, so batches queued behind it wait for the sweep rather than racing a removal.
    static func sweepIfFirst(directory: URL, protecting name: String) {
        lock.lock()
        let first = !hasSwept
        hasSwept = true
        lock.unlock()

        guard first else { return }
        sweep(directory: directory, protecting: [name], now: Date())
    }

    // MARK: - Sweep

    /// Removes expired stores, then the oldest until the rest fit the budget. Returns what went.
    ///
    /// A store is its `.sqlite` file plus its sidecars; its age is the newest modification of the
    /// database or its write-ahead log. The shared-memory file is ignored, because merely opening
    /// a store rewrites it — every store in the measured directory had a `-shm` touched on the same
    /// afternoon while its data was weeks old.
    @discardableResult
    static func sweep(
        directory: URL,
        protecting protected: Set<String>,
        now: Date,
        maximumAge: TimeInterval = maximumAge,
        byteBudget: Int64 = byteBudget,
        fileManager: FileManager = .default
    ) -> Outcome {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return Outcome() }

        var stores: [String: Store] = [:]
        for url in entries.prefix(maximumEntries) {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }

            let (base, suffix) = storeName(of: url.lastPathComponent)
            guard base.hasSuffix(".sqlite") else { continue }

            var store = stores[base] ?? Store(name: base)
            store.files.append(url)
            store.bytes += Int64(values.totalFileAllocatedSize ?? 0)
            if suffix != "-shm", let modified = values.contentModificationDate {
                store.modifiedAt = max(store.modifiedAt ?? modified, modified)
            }
            stores[base] = store
        }

        let protectedFiles = Set(protected.map { $0.hasSuffix(".sqlite") ? $0 : $0 + ".sqlite" })
        var outcome = Outcome()
        var kept: [Store] = []

        for store in stores.values {
            guard !protectedFiles.contains(store.name) else { continue }
            if let modified = store.modifiedAt, now.timeIntervalSince(modified) <= maximumAge {
                kept.append(store)
            } else {
                remove(store, from: &outcome, fileManager: fileManager)
            }
        }

        let protectedBytes = stores.values.filter { protectedFiles.contains($0.name) }.reduce(0) { $0 + $1.bytes }
        var total = protectedBytes + kept.reduce(0) { $0 + $1.bytes }
        for store in kept.sorted(by: { ($0.modifiedAt ?? .distantPast) < ($1.modifiedAt ?? .distantPast) }) {
            guard total > byteBudget else { break }
            remove(store, from: &outcome, fileManager: fileManager)
            total -= store.bytes
        }

        return outcome
    }

    // MARK: - Private

    private struct Store {
        let name: String
        var files: [URL] = []
        var bytes: Int64 = 0
        var modifiedAt: Date?
    }

    private static func storeName(of file: String) -> (base: String, suffix: String?) {
        for suffix in sidecarSuffixes where file.hasSuffix(suffix) {
            return (String(file.dropLast(suffix.count)), suffix)
        }
        return (file, nil)
    }

    private static func remove(_ store: Store, from outcome: inout Outcome, fileManager: FileManager) {
        var removedAny = false
        for file in store.files where (try? fileManager.removeItem(at: file)) != nil {
            removedAny = true
        }
        guard removedAny else { return }
        outcome.removedStores += 1
        outcome.removedBytes += store.bytes
    }
}

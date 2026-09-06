import Foundation

// MARK: - Transcript Fact Reader

/// One fact read back off the end of a session's own transcript, cached against its file
/// identity, modification time and size, and re-read only in the background.
///
/// A transcript is the only source that reports what a **terminal** session is actually doing
/// rather than what it was configured to do: the model that answered, the posture the user
/// Shift+Tabbed into. Both facts want the same three properties, and each one is a cost the
/// surfaces asking would otherwise pay — the corner card refreshes on `ProjectsDidChange`, which
/// fires for the terminal titles agents rewrite constantly.
///
/// - **Backwards and capped.** The scan closure walks from the end and gives up after its own
///   budget, so an answer that has scrolled out of reach is nil rather than a walk through a
///   conversation that has grown to hundreds of megabytes.
/// - **Never on the main thread.** `known(at:)` answers from memory and touches no disk, so a
///   view can ask while it paints. Even the attribute check that decides whether to re-read happens
///   on the background queue.
/// - **Called back only on a change.** A completion per event would redraw for an answer that
///   had not moved.
///
/// Generic over the fact rather than written twice. It was written twice first — the model
/// reader, then the permission-mode reader beside it — and the second copy is what made the
/// point: the caching, the size gate, the in-flight set and the queue hop are properties of
/// *reading a transcript*, and only the scan differs. What stays with each fact is its own
/// `nonisolated` scan function, which is also the part worth testing directly.
///
/// Held as an instance rather than as more static state so two facts cannot share one cache:
/// they have different lifetimes on the same file — a model that has not moved in an hour, a
/// mode that changed a second ago — and one size gate covering both would make each answer stale
/// whenever the other was fresh.
@MainActor
final class TranscriptFactReader<Value: Equatable & Sendable> {

    // MARK: - Types

    private typealias Completion = @MainActor @Sendable (Value?) -> Void

    private struct FileStamp: Equatable, Sendable {
        let size: Int
        let modified: Date?
        let inode: UInt64?
    }

    /// A copied byte boundary suppresses historical output until the worker first stats it.
    /// Ordinary readings also track replacement and modification, including same-size rewrites.
    private enum Boundary: Sendable {
        case copiedSize(Int)
        case file(FileStamp)

        func matches(_ stamp: FileStamp) -> Bool {
            switch self {
            case .copiedSize(let size): return size == stamp.size
            case .file(let previous): return previous == stamp
            }
        }
    }

    private struct Reading: Sendable {
        let boundary: Boundary
        let value: Value?
    }

    private struct Scan {
        var isCurrent = true
    }

    // MARK: - Properties

    /// In memory rather than on disk: this records what a *running conversation* is doing, where
    /// an answer from a previous launch is worth less than reading the file again.
    private var readings: [String: Reading] = [:]

    /// One scan per transcript at a time, so a burst of refreshes cannot queue a stack of reads
    /// behind each other.
    private var scanning: [String: Scan] = [:]

    /// Requests that arrived after a scan took its size snapshot. They become one trailing scan
    /// wave when the current one lands. Dropping them is a correctness race, not coalescing: the
    /// request may describe bytes appended after the in-flight scan read the file, and there may
    /// be no later output event to ask again.
    private var pendingCompletions: [String: [Completion]] = [:]

    /// Reads the fact out of one file, or nil when the file does not state it within its budget.
    /// `nonisolated` by type: it runs on a utility queue and must reach nothing isolated.
    private let scan: @Sendable (URL) -> Value?

    // MARK: - Initialization

    init(scan: @escaping @Sendable (URL) -> Value?) {
        self.scan = scan
    }

    // MARK: - Public Methods

    /// What has already been read for this transcript. Touches no disk, so a caller painting a
    /// view can ask on the main thread.
    func known(at url: URL) -> Value? {
        readings[url.path]?.value
    }

    /// Re-reads in the background when the transcript changes, calling back only if the answer
    /// changed.
    func revalidate(at url: URL, completion: @escaping @MainActor @Sendable (Value?) -> Void) {
        let path = url.path
        guard scanning[path] == nil else {
            pendingCompletions[path, default: []].append(completion)
            return
        }

        beginRevalidation(at: url, completions: [completion])
    }

    /// Seeds a byte-for-byte transcript copy with the size installed at its new path.
    ///
    /// A copied transcript has a new path but not new provider output. Without carrying the size
    /// boundary across, the first validation at the destination announces every fact in the copied
    /// tail as though it had just happened there. `value` is supplied by the fact owner because a
    /// copy can preserve one fact (the model) while invalidating another (a refusal belonging to
    /// the account the transcript just left). The copy transaction supplies the byte count rather
    /// than this reader asking the main thread to stat the file, and rather than reusing a possibly
    /// stale source reading from before the provider finished its last write.
    func seedCopiedTranscript(at destination: URL, byteCount: Int, value: Value?) {
        invalidateScan(at: destination.path)
        readings[destination.path] = Reading(boundary: .copiedSize(byteCount), value: value)
    }

    /// Starts one single-flight read. Calls that overlap it collect in `pendingCompletions` and
    /// are answered by one subsequent read against the newest file size.
    private func beginRevalidation(at url: URL, completions: [Completion]) {
        let path = url.path

        let previous = readings[path]
        let scan = scan
        scanning[path] = Scan()

        DispatchQueue.global(qos: .utility).async {
            let reading = Self.read(at: url, unchangedFrom: previous, scan: scan)

            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if self.scanning[path]?.isCurrent == true, let reading {
                        self.readings[path] = reading
                        if reading.value != previous?.value {
                            for completion in completions {
                                // A callback may itself migrate/reset the transcript.
                                guard self.scanning[path]?.isCurrent == true else { break }
                                completion(reading.value)
                            }
                        }
                    }

                    // Keep the path marked as scanning while callbacks run. A callback may ask
                    // for another validation; admitting it immediately would race this queued
                    // trailing wave and violate the one-scan-per-path contract.
                    let pending = self.pendingCompletions.removeValue(forKey: path)
                    self.scanning.removeValue(forKey: path)
                    if let pending, !pending.isEmpty {
                        self.beginRevalidation(at: url, completions: pending)
                    }
                }
            }
        }
    }

    /// Forgets what has been read. For tests, and for a reset that should re-ask.
    ///
    /// Keep the single-flight slot until its worker lands, but revoke its authority to publish.
    /// Requests after the reset get a trailing scan against the new state.
    func forgetAll() {
        readings.removeAll()
        for path in Array(scanning.keys) { invalidateScan(at: path) }
    }

    // MARK: - Private Methods

    private func invalidateScan(at path: String) {
        scanning[path]?.isCurrent = false
        pendingCompletions.removeValue(forKey: path)
    }

    /// Stat and scan off-main. Unchanged files preserve their cached fact; a first stat after a
    /// copy establishes its file identity without announcing copied history as fresh output.
    private nonisolated static func read(
        at url: URL,
        unchangedFrom previous: Reading?,
        scan: @Sendable (URL) -> Value?
    ) -> Reading? {
        // `URL.resourceValues` caches requested keys on the URL value. These readers deliberately
        // reuse one URL for a running transcript, so a second request can return the size from
        // the first scan even after the provider appended a lifecycle record. Ask the filesystem
        // for current attributes instead; this remains on the utility queue.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.intValue else {
            return nil
        }
        let stamp = FileStamp(
            size: size,
            modified: attributes[.modificationDate] as? Date,
            inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        )
        let value = previous?.boundary.matches(stamp) == true ? previous?.value : scan(url)
        return Reading(boundary: .file(stamp), value: value)
    }
}

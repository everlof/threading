import Foundation

// MARK: - Transcript Fact Reader

/// One fact read back off the end of a session's own transcript, cached against the size it was
/// read at, and re-read only in the background.
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
///   view can ask while it paints. Even the size check that decides whether to re-read happens
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

    /// One transcript's answer and the size it was read at. The size is the invalidation: a file
    /// that has not grown cannot have recorded a different answer.
    private struct Reading: Sendable {
        let size: Int
        let value: Value?
    }

    // MARK: - Properties

    /// In memory rather than on disk: this records what a *running conversation* is doing, where
    /// an answer from a previous launch is worth less than reading the file again.
    private var readings: [String: Reading] = [:]

    /// One scan per transcript at a time, so a burst of refreshes cannot queue a stack of reads
    /// behind each other.
    private var scanning: Set<String> = []

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

    /// Re-reads in the background when the transcript has grown, calling back only if the answer
    /// changed.
    func revalidate(at url: URL, completion: @escaping @MainActor @Sendable (Value?) -> Void) {
        let path = url.path
        guard !scanning.contains(path) else { return }

        let previous = readings[path]
        let scan = scan
        scanning.insert(path)

        DispatchQueue.global(qos: .utility).async {
            let reading = Self.read(at: url, unchangedFrom: previous?.size, scan: scan)

            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.scanning.remove(path)
                    guard let reading else { return }

                    self.readings[path] = reading
                    guard reading.value != previous?.value else { return }
                    completion(reading.value)
                }
            }
        }
    }

    /// Forgets what has been read. For tests, and for a reset that should re-ask.
    ///
    /// Deliberately leaves `scanning` alone: a scan already in flight clears its own entry when
    /// it lands, and dropping the entry here would let a second scan start over the same file.
    /// What that in-flight read writes back is what the file says, which is the right answer for
    /// a forgotten transcript anyway.
    func forgetAll() {
        readings.removeAll()
    }

    // MARK: - Private Methods

    /// The transcript's answer, or nil when the file has not grown since `previousSize` — which
    /// is "nothing to update", not "no answer".
    private nonisolated static func read(
        at url: URL,
        unchangedFrom previousSize: Int?,
        scan: @Sendable (URL) -> Value?
    ) -> Reading? {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else {
            return nil
        }
        guard previousSize != size else { return nil }

        return Reading(size: size, value: scan(url))
    }
}

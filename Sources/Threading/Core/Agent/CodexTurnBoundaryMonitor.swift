import Foundation
import Darwin

/// One process's lifecycle cursor. Initial hydration is O(transcript bytes), in 64 KiB worker
/// passes; subsequent reads are O(appended bytes). Only one pass and one refresh request may be
/// outstanding. Expected: 1–10 live rollouts; stress: 100 MiB history and multi-MiB tool records.
/// No historical boundary is published until the cursor catches up to the current file.
@MainActor
final class CodexTurnBoundaryMonitor {
    private typealias Completion = @MainActor @Sendable (CodexTurnBoundary?) -> Void
    private var cursor = CodexTurnBoundaryCursor()
    private var generation = 0
    private var reading = false
    private var requested: URL?
    private var completion: Completion?
    private var published: CodexTurnBoundary?

    func revalidate(
        at url: URL,
        completion: @escaping @MainActor @Sendable (CodexTurnBoundary?) -> Void
    ) {
        requested = url
        self.completion = completion
        readIfNeeded()
    }

    func reset() {
        generation &+= 1
        cursor = CodexTurnBoundaryCursor()
        requested = nil
        completion = nil
        published = nil
    }

    private func readIfNeeded() {
        guard !reading, let url = requested else { return }
        requested = nil
        reading = true
        let generation = generation
        let previous = cursor
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var next = previous
            let hasMore = next.readPass(at: url)
            let result = next
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.reading = false
                if self.generation == generation {
                    self.cursor = result
                    if hasMore { self.requested = self.requested ?? url }
                    if self.requested == nil, result.boundary != self.published {
                        self.published = result.boundary
                        self.completion?(result.boundary)
                    }
                }
                self.readIfNeeded()
            }
        }
    }
}

/// Value state crosses the worker boundary; file access and JSON decoding never run on main.
/// Oversized unrelated records are skipped by JSONLReader's resumable, bounded scan. A partial
/// final record waits for its newline, and a scan that cannot advance waits for another event.
struct CodexTurnBoundaryCursor: Sendable {
    private(set) var offset: UInt64 = 0
    private(set) var boundary: CodexTurnBoundary?
    private var path: String?
    private var inode: UInt64?
    private var size: UInt64 = 0
    private var modifiedSeconds = 0
    private var modifiedNanoseconds = 0

    mutating func readPass(at url: URL) -> Bool {
        // Foundation's full attributes dictionary also resolves owner/group names, which can
        // involve directory-service IPC per pass. Only these numeric stat fields are needed.
        var status = stat()
        guard stat(url.path, &status) == 0, status.st_size >= 0 else { return false }
        let fileSize = UInt64(status.st_size)
        let fileInode = UInt64(status.st_ino)
        let fileModifiedSeconds = status.st_mtimespec.tv_sec
        let fileModifiedNanoseconds = status.st_mtimespec.tv_nsec
        if path != url.path || inode != fileInode || fileSize < size
            || (fileSize == size && (modifiedSeconds != fileModifiedSeconds
                || modifiedNanoseconds != fileModifiedNanoseconds)) {
            offset = 0
            boundary = nil
        }
        path = url.path
        inode = fileInode
        size = fileSize
        modifiedSeconds = fileModifiedSeconds
        modifiedNanoseconds = fileModifiedNanoseconds
        guard offset < fileSize else { return false }

        let previousOffset = offset
        offset = JSONLReader.forEachRecord(
            at: url, from: offset, limit: CodexTurnBoundaryDefaults.scanBytes
        ) { record in
            if CodexTranscriptTurnBoundary.isLifecycleBoundary(record) {
                // An unknown abort supersedes the old boundary too; it cannot resurrect a
                // completed or started turn from before the unknown record.
                boundary = CodexTranscriptTurnBoundary.boundary(in: record)
            }
            return true
        }
        return offset > previousOffset && offset < fileSize
    }
}

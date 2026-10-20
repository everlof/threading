#if os(Linux)
import Foundation
import ThreadingUsage
@testable import CoreSlice

/// A report from Claude's newest transcript, never a setting for the next launch.
/// The catalogue loader calls this on its serial file worker, not while drawing a menu.
enum ComposerRecentPermissionMode {
    private static let projectLimit = 5
    private static let transcriptLimit = 10
    private static let directoryEntryLimit = 4_096
    private static let scanBytes = 2 * JSONLDefaults.chunkBytes

    static func read(in accountDirectory: URL) -> AgentPermissionMode? {
        let projects = accountDirectory.appendingPathComponent("projects", isDirectory: true)
        let recentProjects = newestEntries(in: projects, limit: projectLimit)
        let transcripts = recentProjects.flatMap { newestEntries(in: $0, limit: transcriptLimit) }
            .filter { $0.pathExtension == "jsonl" }
        guard let newest = transcripts.max(by: { modificationDate($0) < modificationDate($1) }) else {
            return nil
        }

        return read(at: newest)
    }

    /// The newest posture asserted in this transcript's bounded tail.
    static func read(at transcript: URL) -> AgentPermissionMode? {
        var recorded: String?
        JSONLReader.forEachRecordFromEnd(at: transcript, limit: scanBytes) { record in
            guard record["type"] as? String == "permission-mode",
                  let mode = record["permissionMode"] as? String,
                  !mode.isEmpty else { return true }
            recorded = mode
            return false
        }
        return recorded.flatMap { AgentPermissionMode(externalValue: $0, for: .claude) }
    }

    /// Keep only the most recent entries. An oversized directory yields no observation rather
    /// than a possibly stale answer chosen from an arbitrary prefix of the filesystem order.
    private static func newestEntries(in directory: URL, limit: Int) -> [URL] {
        guard let entries = FileManager.default.enumerator(at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else { return [] }
        var newest: [(url: URL, date: Date)] = []
        var visited = 0
        for case let url as URL in entries {
            visited += 1
            if visited > directoryEntryLimit { return [] }
            let date = modificationDate(url)
            newest.append((url, date))
            newest.sort { $0.date > $1.date }
            if newest.count > limit { newest.removeLast() }
        }
        return newest.map(\.url)
    }

    private static func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
    }
}
#endif

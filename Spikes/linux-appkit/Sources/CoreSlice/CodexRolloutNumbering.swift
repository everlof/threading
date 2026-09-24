import Foundation

/// A bounded read of the one Codex rollout shape known to fail resume: numbered records
/// followed by a final record without an ordinal. Older all-unnumbered rollouts remain valid.
enum CodexRolloutNumbering {
    static func isMixed(at url: URL) -> Bool {
        guard let tail = tail(of: url) else { return false }
        let lines = tail
            .split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
            .map { Data($0) }
        guard let last = lines.last else { return false }
        // The first line may be clipped by the bounded tail read. Codex appends complete
        // records, so the final line is the one that determines whether numbering stopped.
        return lines.contains { hasOrdinal($0) } && !hasOrdinal(last)
    }

    private static func tail(of url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let offset = size > 65_536 ? size - 65_536 : 0
        try? handle.seek(toOffset: offset)
        return try? handle.readToEnd()
    }

    private static func hasOrdinal(_ line: Data) -> Bool {
        // Scan raw envelope bytes: a tool result may contain the same key deep in its payload.
        line.prefix(512).range(of: Data("\"ordinal\":".utf8)) != nil
    }
}

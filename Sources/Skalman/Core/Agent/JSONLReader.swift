import Foundation

/// Streams newline-delimited JSON records from a file.
///
/// Both CLIs keep their conversations this way, and both are read for more than one purpose —
/// discovering importable sessions, and replaying one into the conversation view. The reading
/// itself carries two hard-won properties, so it lives in one place rather than being written
/// again per caller:
///
/// - **Records are never cut at a fixed byte count.** A Codex `session_meta` line carries the
///   project's instructions and runs to tens of kilobytes; a truncated line is not parseable
///   JSON, so capping the read silently drops the record entirely. The *scan* is bounded here,
///   never the record.
/// - **Reading stops when the caller says so**, not when a guessed prefix is exhausted. The
///   opening turn can sit hundreds of kilobytes into a Codex rollout, behind telemetry, so a
///   caller that needs it can read on while the common case still costs one chunk.
enum JSONLReader {

    /// Calls `handle` for each record until it returns false or `limit` bytes have been read.
    static func forEachRecord(at url: URL, limit: Int, _ handle: ([String: Any]) -> Bool) {
        guard let file = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? file.close() }

        var buffer = Data()
        var consumed = 0
        let newline = UInt8(ascii: "\n")

        while consumed < limit {
            guard let chunk = try? file.read(upToCount: JSONLDefaults.chunkBytes),
                  !chunk.isEmpty else { break }

            consumed += chunk.count
            buffer.append(chunk)

            while let index = buffer.firstIndex(of: newline) {
                let line = buffer.prefix(upTo: index)

                // Re-based, because slicing `Data` keeps the original indices.
                buffer = Data(buffer.suffix(from: buffer.index(after: index)))

                if !deliver(line, to: handle) { return }
            }
        }

        // A trailing record with no newline is still a record.
        _ = deliver(buffer, to: handle)
    }

    /// Parses one line and passes it on, reporting whether reading should continue.
    private static func deliver(_ line: Data, to handle: ([String: Any]) -> Bool) -> Bool {
        guard !line.isEmpty,
              let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
        else { return true }

        return handle(record)
    }
}

// MARK: - Defaults

enum JSONLDefaults {
    static let chunkBytes = 64 * 1024
}

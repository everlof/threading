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
        forEachLine(at: url, limit: limit) { line in
            deliver(line, to: handle)
        }
    }

    /// The same stream, **unparsed**.
    ///
    /// Exists for the one caller that reads whole conversations rather than the head of one:
    /// the usage index walks every transcript on the disk, and most records in them carry no
    /// usage at all. Parsing each into a dictionary before deciding that is the entire cost of
    /// the scan, and skipping it on a substring test is the difference between seconds and
    /// minutes over a gigabyte.
    ///
    /// The chunking, the newline handling and the never-truncate-a-record rule stay here, so
    /// the two views cannot drift apart.
    static func forEachLine(at url: URL, limit: Int, _ handle: (Data) -> Bool) {
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

            // Lines are handed out as slices and the buffer is compacted **once per chunk**,
            // not once per line. Rebuilding `Data` after every line is quadratic in the chunk's
            // length, which is invisible on a short head-read and ruinous over a gigabyte: it
            // was the difference between four seconds and five minutes across this corpus.
            var lineStart = buffer.startIndex
            while let index = buffer[lineStart...].firstIndex(of: newline) {
                let line = buffer[lineStart..<index]
                lineStart = buffer.index(after: index)

                if !line.isEmpty, !handle(line) { return }
            }

            buffer.removeSubrange(buffer.startIndex..<lineStart)
        }

        // A trailing record with no newline is still a record.
        if !buffer.isEmpty { _ = handle(buffer) }
    }

    /// Reads the last complete JSON object without walking the whole file.
    ///
    /// Subagent history uses this to distinguish a child that reached `end_turn` from one whose
    /// process stopped mid-tool. The read grows backwards until it finds the preceding newline,
    /// so even an unusually large final record is never truncated at a guessed byte cap.
    static func lastRecord(at url: URL) -> [String: Any]? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }

        guard let fileSize = try? file.seekToEnd(), fileSize > 0 else { return nil }

        var offset = fileSize
        var buffer = Data()
        let newline = UInt8(ascii: "\n")

        while offset > 0 {
            let count = min(UInt64(JSONLDefaults.chunkBytes), offset)
            offset -= count

            do {
                try file.seek(toOffset: offset)
                guard let chunk = try file.read(upToCount: Int(count)), !chunk.isEmpty else {
                    return nil
                }
                buffer.insert(contentsOf: chunk, at: buffer.startIndex)
            } catch {
                return nil
            }

            var logicalEnd = buffer.endIndex
            while logicalEnd > buffer.startIndex,
                  buffer[buffer.index(before: logicalEnd)] == newline {
                logicalEnd = buffer.index(before: logicalEnd)
            }
            guard logicalEnd > buffer.startIndex else { continue }

            if let delimiter = buffer[buffer.startIndex..<logicalEnd].lastIndex(of: newline) {
                let line = buffer[buffer.index(after: delimiter)..<logicalEnd]
                return dictionary(from: line)
            }

            if offset == 0 {
                return dictionary(from: buffer[buffer.startIndex..<logicalEnd])
            }
        }

        return nil
    }

    /// Parses one line and passes it on, reporting whether reading should continue.
    private static func deliver(_ line: Data, to handle: ([String: Any]) -> Bool) -> Bool {
        guard let record = dictionary(from: line) else { return true }

        return handle(record)
    }

    private static func dictionary<T: DataProtocol>(from line: T) -> [String: Any]? {
        guard !line.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: Data(line)) else {
            return nil
        }
        return object as? [String: Any]
    }
}

// MARK: - Defaults

enum JSONLDefaults {
    static let chunkBytes = 64 * 1024
}

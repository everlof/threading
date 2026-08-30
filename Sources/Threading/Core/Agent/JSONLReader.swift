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

    /// The same forward stream, **resumable**: reading starts at `offset`, and the returned
    /// position is just past the last record handed out.
    ///
    /// A trailing record with no newline is deliberately *not* delivered here, which is the one
    /// place this reader differs from the plain forward scan. A resumable caller cannot tell a
    /// final record from one the agent is halfway through writing, and remembering a position
    /// inside a half-written line would drop its remainder for good. Waiting for the newline
    /// costs one re-read of one line and cannot lose a record.
    ///
    /// Stopping early is free for the same reason: the returned position covers exactly the
    /// records `handle` accepted, so a bounded pass resumes where it left off.
    @discardableResult
    static func forEachRecord(
        at url: URL,
        from offset: UInt64,
        limit: Int,
        _ handle: ([String: Any]) -> Bool
    ) -> UInt64 {
        (try? scanForward(
            at: url,
            from: offset,
            limit: limit,
            deliversTrailingRecord: false
        ) { line in
            deliver(line, to: handle)
        }) ?? offset
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
        _ = try? scanForward(
            at: url,
            from: 0,
            limit: limit,
            deliversTrailingRecord: true,
            handle
        )
    }

    /// The usage ledger's strict sibling to `forEachLine`.
    ///
    /// Replay and discovery are recovery readers: an unreadable line can be omitted while the
    /// rest of the conversation remains useful. A bill is different. Its caller must be able to
    /// distinguish a complete source from a file that could not be opened, stopped reading, or
    /// contained a usage record it could not parse. The streaming implementation remains shared;
    /// only this entry point lets those failures escape.
    static func forEachLineStrict(
        at url: URL,
        limit: Int,
        _ handle: (Data) throws -> Bool
    ) throws {
        _ = try scanForward(
            at: url,
            from: 0,
            limit: limit,
            deliversTrailingRecord: true,
            handle
        )
    }

    /// The one forward implementation, so the chunking, the newline handling, the
    /// never-truncate-a-record rule and the resume position cannot drift apart.
    ///
    /// Returns the absolute position just past the last record handed to `handle`.
    private static func scanForward(
        at url: URL,
        from offset: UInt64,
        limit: Int,
        deliversTrailingRecord: Bool,
        _ handle: (Data) throws -> Bool
    ) throws -> UInt64 {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }

        if offset > 0 {
            try file.seek(toOffset: offset)
        }

        var buffer = Data()
        var consumed = 0
        var delivered = offset
        var reachedEndOfFile = false
        let newline = UInt8(ascii: "\n")

        while consumed < limit {
            guard let chunk = try file.read(upToCount: JSONLDefaults.chunkBytes),
                  !chunk.isEmpty else { reachedEndOfFile = true; break }

            consumed += chunk.count
            buffer.append(chunk)

            // Lines are handed out as slices and the buffer is compacted **once per chunk**,
            // not once per line. Rebuilding `Data` after every line is quadratic in the chunk's
            // length, which is invisible on a short head-read and ruinous over a gigabyte: it
            // was the difference between four seconds and five minutes across this corpus.
            var lineStart = buffer.startIndex
            while let index = buffer[lineStart...].firstIndex(of: newline) {
                let line = buffer[lineStart..<index]
                let next = buffer.index(after: index)

                if !line.isEmpty, try !handle(line) {
                    return delivered + UInt64(next - buffer.startIndex)
                }
                lineStart = next
            }

            delivered += UInt64(lineStart - buffer.startIndex)
            buffer.removeSubrange(buffer.startIndex..<lineStart)
        }

        // A trailing record with no newline is still a record — but only at **end of file**.
        // When the loop stopped because `limit` was reached, what is left in the buffer is the
        // front of a record whose rest was never read, and handing that out is the one thing
        // this reader promises not to do. It did: a `limit` below one chunk still reads a whole
        // chunk, so every bounded scan of a file larger than 64 KB ended by delivering a record
        // cut in half. `forEachRecordFromEnd` already guards this with `offset == 0`; the two
        // directions now make the same promise.
        //
        // A resumable scan declines it even at end of file, and `delivered` stays behind it: see
        // `forEachRecord(at:from:limit:)`.
        if deliversTrailingRecord, reachedEndOfFile, !buffer.isEmpty { _ = try handle(buffer) }
        return delivered
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

    /// Calls `handle` for each record from the **end** backwards, newest first, until it returns
    /// false or `limit` bytes have been read.
    ///
    /// `lastRecord` above answers "how did this conversation stop", which only ever needs the
    /// final line. This answers "when did it last say X", and the two are different questions
    /// whenever the fact wanted is not on that line — a Claude transcript ends on whatever the
    /// last tool wrote, while the model is recorded on assistant records only. Reading forwards
    /// to find it would walk an entire conversation to reach the part nearest its end.
    ///
    /// `limit` bounds the scan rather than the record, the same rule the forward reader keeps: a
    /// tail made of nothing but tool output answers nothing rather than reading a 250 MB file to
    /// the top.
    static func forEachRecordFromEnd(at url: URL, limit: Int, _ handle: ([String: Any]) -> Bool) {
        guard let file = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? file.close() }

        guard let fileSize = try? file.seekToEnd(), fileSize > 0 else { return }

        var offset = fileSize
        var buffer = Data()
        var consumed = 0
        let newline = UInt8(ascii: "\n")

        while offset > 0, consumed < limit {
            let count = min(UInt64(JSONLDefaults.chunkBytes), offset)
            offset -= count

            do {
                try file.seek(toOffset: offset)
                guard let chunk = try file.read(upToCount: Int(count)), !chunk.isEmpty else {
                    return
                }
                buffer.insert(contentsOf: chunk, at: buffer.startIndex)
            } catch {
                return
            }

            consumed += Int(count)

            // Everything after the buffer's first newline is a whole record and can be handed
            // out now, newest first. What is left in front of that newline is the *tail* of a
            // record whose start lies in the chunk not read yet, so it waits — the same
            // never-truncate-a-record rule, in the other direction.
            while let delimiter = buffer.lastIndex(of: newline) {
                let line = buffer[buffer.index(after: delimiter)...]
                buffer.removeSubrange(delimiter..<buffer.endIndex)
                if !line.isEmpty, !deliver(line, to: handle) { return }
            }
        }

        // Only once the top of the file has been reached is the leading remainder a whole
        // record; a scan that stopped at `limit` leaves a fragment, which is not one.
        if offset == 0, !buffer.isEmpty { _ = deliver(buffer, to: handle) }
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

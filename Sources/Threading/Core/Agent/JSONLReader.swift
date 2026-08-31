import Foundation
import Darwin

/// Streams newline-delimited JSON records from a file.
///
/// Both CLIs keep their conversations this way, and both are read for more than one purpose —
/// discovering importable sessions, and replaying one into the conversation view. The reading
/// itself carries two hard-won properties, so it lives in one place rather than being written
/// again per caller:
///
/// - **Records are never handed out partially.** Unbounded scans reassemble records of any size.
///   Finite scans retain at most one pass: an individual record that fills that entire budget is
///   skipped across resumable passes, keeping hostile or corrupt input from defeating the cap.
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

    /// A forward record stream that also exposes the exact byte window occupied by each JSONL
    /// record. Search keeps those offsets as opaque source locators, allowing exact historical
    /// landing to seek rather than replaying a transcript from byte zero.
    @discardableResult
    static func forEachRecordWithOffsets(
        at url: URL,
        from offset: UInt64 = 0,
        limit: Int,
        _ handle: (_ record: [String: Any], _ startOffset: UInt64, _ endOffset: UInt64) -> Bool
    ) -> UInt64 {
        (try? scanForward(
            at: url,
            from: offset,
            limit: limit,
            deliversTrailingRecord: false
        ) { line, start, end in
            guard let record = dictionary(from: line) else { return true }
            return handle(record, start, end)
        }) ?? offset
    }

    /// The same forward stream, **resumable**: reading starts at `offset`, and the returned
    /// position is where the next bounded pass should resume.
    ///
    /// A trailing record with no newline is deliberately *not* delivered here, which is the one
    /// place this reader differs from the plain forward scan. A resumable caller cannot tell a
    /// final record from one the agent is halfway through writing, and remembering a position
    /// inside a half-written line would drop its remainder for good. Waiting for the newline
    /// costs one re-read of one line and cannot lose a record.
    ///
    /// A normal incomplete record is retried from its beginning. A record larger than a whole
    /// finite pass is deliberately advanced through without delivery; the next pass detects that
    /// its offset is inside a record and discards through the newline before resuming normally.
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
        ) { line, _, _ in
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
            deliversTrailingRecord: true
        ) { line, _, _ in handle(line) }
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
            deliversTrailingRecord: true
        ) { line, _, _ in try handle(line) }
    }

    /// The one forward implementation, so the chunking, the newline handling, the
    /// never-truncate-a-record rule and the resume position cannot drift apart.
    ///
    /// Returns the absolute position at which a caller should resume. That is normally just past
    /// the last complete record. A finite pass may instead return a position inside an oversized
    /// record so subsequent passes can discard it without retaining it all at once.
    private static func scanForward(
        at url: URL,
        from offset: UInt64,
        limit: Int,
        deliversTrailingRecord: Bool,
        _ handle: (Data, UInt64, UInt64) throws -> Bool
    ) throws -> UInt64 {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }

        var buffer = Data()
        var consumed = 0
        var bufferStartOffset = offset
        var reachedEndOfFile = false
        let newline = UInt8(ascii: "\n")
        let isBounded = limit != .max
        guard !isBounded || limit > 0 else { return offset }
        let scanBudget = isBounded ? max(limit, JSONLDefaults.chunkBytes) : .max

        // A previous bounded pass can return from the middle of an oversized record. Inspecting
        // the preceding byte lets this pass discard only that leading fragment; offsets that
        // already sit on a record boundary continue to deliver normally.
        var discardingLeadingFragment = false
        if offset > 0 {
            try file.seek(toOffset: offset - 1)
            if let previous = try file.read(upToCount: 1), let byte = previous.first {
                discardingLeadingFragment = byte != newline
            }
        }
        try file.seek(toOffset: offset)

        while consumed < scanBudget {
            let readCount = isBounded
                ? min(JSONLDefaults.chunkBytes, scanBudget - consumed)
                : JSONLDefaults.chunkBytes
            guard let chunk = try file.read(upToCount: readCount),
                  !chunk.isEmpty else { reachedEndOfFile = true; break }

            consumed += chunk.count
            // `buffer` is only the incomplete tail from the preceding chunk. Every byte in it
            // was already searched, so start at the newly appended bytes. Starting again at
            // zero makes one large JSON record quadratic in its size: a measured 22 MB Codex
            // record was searched 336 times while the usage index waited behind it.
            var searchOffset = buffer.count
            buffer.append(chunk)

            // Lines are handed out as slices and the buffer is compacted **once per chunk**,
            // not once per line. Rebuilding `Data` after every line is quadratic in the chunk's
            // length, which is invisible on a short head-read and ruinous over a gigabyte: it
            // was the difference between four seconds and five minutes across this corpus.
            var lineStartOffset = 0
            while let newlineOffset = firstOffset(
                of: newline,
                in: buffer,
                startingAt: searchOffset
            ) {
                let lineStart = buffer.index(buffer.startIndex, offsetBy: lineStartOffset)
                let index = buffer.index(buffer.startIndex, offsetBy: newlineOffset)
                let line = buffer[lineStart ..< index]

                let absoluteLineStart = bufferStartOffset + UInt64(lineStartOffset)
                let absoluteLineEnd = bufferStartOffset + UInt64(newlineOffset + 1)
                if discardingLeadingFragment {
                    discardingLeadingFragment = false
                } else if !line.isEmpty,
                          try !handle(Data(line), absoluteLineStart, absoluteLineEnd)
                {
                    return absoluteLineEnd
                }
                lineStartOffset = newlineOffset + 1
                searchOffset = lineStartOffset
            }

            bufferStartOffset += UInt64(lineStartOffset)
            if lineStartOffset > 0 {
                let lineStart = buffer.index(buffer.startIndex, offsetBy: lineStartOffset)
                buffer.removeSubrange(buffer.startIndex ..< lineStart)
            }
        }

        // A trailing record with no newline is still a record — but only at **end of file**.
        // When the loop stopped because `limit` was reached, what is left in the buffer is the
        // front of a record whose rest was never read, and handing that out is the one thing
        // this reader promises not to do. It did: a `limit` below one chunk still reads a whole
        // chunk, so every bounded scan of a file larger than 64 KB ended by delivering a record
        // cut in half. `forEachRecordFromEnd` already guards this with `offset == 0`; the two
        // directions now make the same promise.
        //
        // A resumable scan declines it even at end of file and normally keeps its resume cursor
        // behind that unfinished record: see `forEachRecord(at:from:limit:)`.
        if deliversTrailingRecord,
           reachedEndOfFile,
           !discardingLeadingFragment,
           !buffer.isEmpty
        {
            _ = try handle(
                buffer,
                bufferStartOffset,
                bufferStartOffset + UInt64(buffer.count)
            )
        }

        // Preserve an ordinary partial tail so a growing transcript can complete it later. If a
        // single record filled a whole bounded pass, advance instead: retaining or retrying that
        // record would respectively violate the memory cap or prevent incremental progress.
        if !deliversTrailingRecord,
           !discardingLeadingFragment,
           !buffer.isEmpty,
           !isBounded || buffer.count < scanBudget
        {
            return bufferStartOffset
        }
        return offset + UInt64(consumed)
    }

    /// Finds one byte through libc's contiguous-memory search rather than the generic
    /// `Collection.firstIndex(of:)` witness path. `Data`'s generic subscript has substantial
    /// per-byte overhead in an unoptimised app build; it occupied a utility core continuously
    /// while a cold usage scan walked a large rollout.
    private static func firstOffset(
        of byte: UInt8,
        in data: Data,
        startingAt startOffset: Int
    ) -> Int? {
        guard startOffset >= 0, startOffset < data.count else { return nil }

        return data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return nil }
            let start = base.advanced(by: startOffset)
            guard let match = memchr(start, Int32(byte), bytes.count - startOffset) else {
                return nil
            }
            return base.distance(to: UnsafeRawPointer(match))
        }
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
                  buffer[buffer.index(before: logicalEnd)] == newline
            {
                logicalEnd = buffer.index(before: logicalEnd)
            }
            guard logicalEnd > buffer.startIndex else { continue }

            if let delimiter = buffer[buffer.startIndex ..< logicalEnd].lastIndex(of: newline) {
                let line = buffer[buffer.index(after: delimiter) ..< logicalEnd]
                return dictionary(from: line)
            }

            if offset == 0 {
                return dictionary(from: buffer[buffer.startIndex ..< logicalEnd])
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
                buffer.removeSubrange(delimiter ..< buffer.endIndex)
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
              let object = try? JSONSerialization.jsonObject(with: Data(line))
        else {
            return nil
        }
        return object as? [String: Any]
    }
}

// MARK: - Defaults

enum JSONLDefaults {
    static let chunkBytes = 64 * 1024
}

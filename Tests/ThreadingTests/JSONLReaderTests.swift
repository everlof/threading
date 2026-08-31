@testable import Threading
import XCTest

/// Covers the streaming reader every Claude and Codex transcript is read through.
///
/// Its two promises are the ones worth attacking: a **record is never cut** at a byte count, and
/// the `limit` bounds the *scan* rather than the record. Both are about what happens at a chunk
/// boundary, which is where a reader that works on a small fixture stops working on a real
/// 250 MB rollout — so the fixtures here are deliberately built to straddle one.
final class JSONLReaderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("JSONLReaderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    private func write(_ contents: String, named name: String = "transcript.jsonl") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    /// A record whose serialized form is comfortably larger than one 64 KB read.
    private func oversizedRecord(id: String) -> String {
        let padding = String(repeating: "x", count: JSONLDefaults.chunkBytes * 2)
        return #"{"id":"\#(id)","pad":"\#(padding)"}"#
    }

    private func records(at url: URL, limit: Int = .max) -> [[String: Any]] {
        var collected: [[String: Any]] = []
        JSONLReader.forEachRecord(at: url, limit: limit) { collected.append($0); return true }
        return collected
    }

    private func lines(at url: URL, limit: Int = .max) -> [Data] {
        var collected: [Data] = []
        JSONLReader.forEachLine(at: url, limit: limit) { collected.append(Data($0)); return true }
        return collected
    }

    // MARK: - Malformed and degenerate input

    /// A transcript is an unreviewed file on the user's disk. Nothing in it may throw, and a
    /// line that is not an object is skipped rather than ending the read — a half-written final
    /// record from a killed agent is the common case, and the records before it are still good.
    func testUnparseableLinesAreSkippedWithoutEndingTheRead() throws {
        let url = try write("""
        {"n":1}
        not json at all
        [1,2,3]
        "a bare string"
        null
        {"n":2}
        {"n":3
        """)

        // `[1,2,3]`, `"a bare string"` and `null` all parse as JSON but are not objects, and the
        // unterminated final record does not parse at all. Only the two objects survive.
        XCTAssertEqual(records(at: url).compactMap { $0["n"] as? Int }, [1, 2])
    }

    func testBlankLinesAreSkippedWithoutDisturbingTheRecordsAroundThem() throws {
        let url = try write("\n\n\n{\"n\":1}\n\n\n\n{\"n\":2}\n\n")
        XCTAssertEqual(records(at: url).compactMap { $0["n"] as? Int }, [1, 2])
    }

    func testAnEmptyFileAndAMissingFileAreBothSilentlyEmpty() throws {
        let empty = try write("")
        XCTAssertTrue(records(at: empty).isEmpty)
        XCTAssertNil(JSONLReader.lastRecord(at: empty))

        let missing = directory.appendingPathComponent("nope.jsonl")
        XCTAssertTrue(records(at: missing).isEmpty)
        XCTAssertNil(JSONLReader.lastRecord(at: missing))
    }

    /// A directory opens as a `FileHandle` but reads as nothing, and a file of raw bytes is not
    /// text at all. Neither may trap.
    func testADirectoryAndBinaryNoiseAreRefusedRatherThanTrapped() throws {
        XCTAssertTrue(records(at: directory).isEmpty)

        let binary = directory.appendingPathComponent("noise.jsonl")
        try Data((0 ... 255).map { UInt8($0) }).write(to: binary)
        XCTAssertTrue(records(at: binary).isEmpty)
        XCTAssertNil(JSONLReader.lastRecord(at: binary))
    }

    // MARK: - Records are never cut

    /// The headline promise. A Codex `session_meta` runs to tens of kilobytes, so a record that
    /// spans several reads has to be reassembled — capping the read drops it entirely.
    func testARecordLargerThanOneReadIsDeliveredWhole() throws {
        let url = try write(oversizedRecord(id: "big") + "\n" + #"{"id":"after"}"# + "\n")

        let found = records(at: url)
        XCTAssertEqual(found.compactMap { $0["id"] as? String }, ["big", "after"])
        XCTAssertEqual((found.first?["pad"] as? String)?.count, JSONLDefaults.chunkBytes * 2)
    }

    /// Codex can put a complete tool result in one JSON record. A 22 MB record in the measured
    /// corpus made the old chunk loop search its incomplete prefix again after every 64 KB read,
    /// keeping the usage-index worker busy for minutes. Eight MiB is large enough to distinguish
    /// that quadratic walk from a single pass while remaining a modest test fixture.
    func testAMultiMegabyteRecordIsScannedOnceAcrossChunkBoundaries() throws {
        let paddingBytes = 8 * 1024 * 1024
        let record = #"{"id":"wide","pad":"\#(String(repeating: "x", count: paddingBytes))"}"#
        let url = try write(record + "\n")
        let started = Date()

        let found = records(at: url)

        XCTAssertEqual(found.first?["id"] as? String, "wide")
        XCTAssertEqual((found.first?["pad"] as? String)?.count, paddingBytes)
        XCTAssertLessThan(
            Date().timeIntervalSince(started),
            2,
            "an 8 MiB record was rescanned as its chunks arrived"
        )
    }

    /// The same record read from the end, where the reassembly runs in the other direction.
    func testAnOversizedFinalRecordIsFoundFromTheEnd() throws {
        let url = try write(#"{"id":"first"}"# + "\n" + oversizedRecord(id: "last") + "\n")

        XCTAssertEqual(JSONLReader.lastRecord(at: url)?["id"] as? String, "last")
    }

    func testATrailingRecordWithNoNewlineIsStillARecord() throws {
        let url = try write("{\"n\":1}\n{\"n\":2}")
        XCTAssertEqual(records(at: url).compactMap { $0["n"] as? Int }, [1, 2])
        XCTAssertEqual(JSONLReader.lastRecord(at: url)?["n"] as? Int, 2)
    }

    func testTrailingNewlinesDoNotHideTheLastRecord() throws {
        let url = try write("{\"n\":1}\n{\"n\":9}\n\n\n\n")
        XCTAssertEqual(JSONLReader.lastRecord(at: url)?["n"] as? Int, 9)
    }

    // MARK: - The limit bounds the scan, not the record

    /// `limit` stops the *scan*. What it must never do is hand the caller a record it cut in
    /// half: the forward reader flushes whatever is left in its buffer when the loop ends, and
    /// when the loop ended because the limit was reached rather than because the file did, that
    /// remainder is the front of a record whose rest was never read.
    ///
    /// `forEachRecord` hides it — a fragment fails to parse and is dropped — so the assertion
    /// that catches it has to be made on the unparsed stream, which is what `CodexUsageBackfill`
    /// actually reads.
    func testAScanStoppedByTheLimitNeverDeliversAPartialLine() throws {
        let record = #"{"id":"r","pad":"\#(String(repeating: "y", count: 8 * 1024))"}"#
        let url = try write(
            (0 ..< 12).map { _ in record }.joined(separator: "\n") + "\n"
        )

        let delivered = lines(at: url, limit: 1)
        XCTAssertFalse(delivered.isEmpty, "a limit of one byte still reads the first chunk")

        for line in delivered {
            XCTAssertNotNil(
                try? JSONSerialization.jsonObject(with: line),
                "delivered a record cut at the scan limit: \(line.count) bytes"
            )
        }
    }

    /// The backward reader makes the same promise, and states it: only once the top of the file
    /// is reached is the leading remainder a whole record.
    func testAReverseScanStoppedByTheLimitNeverDeliversAPartialLine() throws {
        let record = #"{"id":"r","pad":"\#(String(repeating: "y", count: 8 * 1024))"}"#
        let url = try write(
            (0 ..< 12).map { _ in record }.joined(separator: "\n") + "\n"
        )

        var seen = 0
        JSONLReader.forEachRecordFromEnd(at: url, limit: 1) { record in
            seen += 1
            XCTAssertEqual(record["id"] as? String, "r")
            return true
        }
        XCTAssertGreaterThan(seen, 0)
    }

    func testReturningFalseStopsTheReadImmediately() throws {
        let url = try write((1 ... 50).map { "{\"n\":\($0)}" }.joined(separator: "\n") + "\n")

        var seen: [Int] = []
        JSONLReader.forEachRecord(at: url, limit: .max) { record in
            seen.append(record["n"] as? Int ?? -1)
            return seen.count < 3
        }
        XCTAssertEqual(seen, [1, 2, 3])
    }

    func testResumableRecordOffsetsAreExactAndDoNotConsumeAnIncompleteTail() throws {
        let first = #"{"n":1}"# + "\n"
        let second = #"{"n":2}"# + "\n"
        let tail = #"{"n":3}"#
        let url = try write(first + second + tail)
        var windows: [(Int, UInt64, UInt64)] = []

        let end = JSONLReader.forEachRecordWithOffsets(
            at: url,
            from: 0,
            limit: .max
        ) { record, start, end in
            windows.append((record["n"] as? Int ?? -1, start, end))
            return true
        }

        XCTAssertEqual(windows.map(\.0), [1, 2])
        XCTAssertEqual(windows.map(\.1), [0, UInt64(first.utf8.count)])
        XCTAssertEqual(
            windows.map(\.2),
            [UInt64(first.utf8.count), UInt64(first.utf8.count + second.utf8.count)]
        )
        XCTAssertEqual(end, UInt64(first.utf8.count + second.utf8.count))
    }

    func testFiniteResumableScansSkipAnOversizedRecordWithoutStalling() throws {
        let padding = String(repeating: "z", count: JSONLDefaults.chunkBytes * 3)
        let oversized = #"{"id":"huge","pad":"\#(padding)"}"#
        let url = try write(oversized + "\n" + #"{"id":"after"}"# + "\n")
        var offset: UInt64 = 0
        var seen: [String] = []
        var advances: [UInt64] = []

        for _ in 0 ..< 8 {
            let next = JSONLReader.forEachRecordWithOffsets(
                at: url,
                from: offset,
                limit: JSONLDefaults.chunkBytes
            ) { record, _, _ in
                if let id = record["id"] as? String { seen.append(id) }
                return true
            }
            advances.append(next - offset)
            if next == offset { break }
            offset = next
            if seen.contains("after") { break }
        }

        XCTAssertFalse(seen.contains("huge"))
        XCTAssertEqual(seen, ["after"])
        XCTAssertTrue(advances.allSatisfy { $0 <= UInt64(JSONLDefaults.chunkBytes) })
    }

    func testFiniteResumableScanRetriesANormalRecordThatStraddlesItsBudget() throws {
        let firstPadding = String(repeating: "a", count: JSONLDefaults.chunkBytes - 256)
        let secondPadding = String(repeating: "b", count: 1024)
        let first = #"{"id":"first","pad":"\#(firstPadding)"}"# + "\n"
        let second = #"{"id":"second","pad":"\#(secondPadding)"}"# + "\n"
        let url = try write(first + second)
        var firstPass: [String] = []

        let resume = JSONLReader.forEachRecordWithOffsets(
            at: url,
            from: 0,
            limit: JSONLDefaults.chunkBytes
        ) { record, _, _ in
            if let id = record["id"] as? String { firstPass.append(id) }
            return true
        }

        var secondPass: [String] = []
        _ = JSONLReader.forEachRecordWithOffsets(
            at: url,
            from: resume,
            limit: JSONLDefaults.chunkBytes
        ) { record, _, _ in
            if let id = record["id"] as? String { secondPass.append(id) }
            return true
        }

        XCTAssertEqual(firstPass, ["first"])
        XCTAssertEqual(resume, UInt64(first.utf8.count))
        XCTAssertEqual(secondPass, ["second"])
    }

    // MARK: - Reading from the end

    func testTheReverseScanYieldsNewestFirst() throws {
        let url = try write((1 ... 5).map { "{\"n\":\($0)}" }.joined(separator: "\n") + "\n")

        var seen: [Int] = []
        JSONLReader.forEachRecordFromEnd(at: url, limit: .max) { record in
            seen.append(record["n"] as? Int ?? -1)
            return true
        }
        XCTAssertEqual(seen, [5, 4, 3, 2, 1])
    }

    /// A file with no newline anywhere is one record, from either direction.
    func testAFileOfOneUnterminatedRecordReadsFromBothEnds() throws {
        let url = try write(#"{"only":true}"#)

        XCTAssertEqual(records(at: url).count, 1)
        XCTAssertEqual(JSONLReader.lastRecord(at: url)?["only"] as? Bool, true)

        var seen = 0
        JSONLReader.forEachRecordFromEnd(at: url, limit: .max) { _ in seen += 1; return true }
        XCTAssertEqual(seen, 1)
    }
}

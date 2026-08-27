import XCTest
@testable import Threading

/// The index that answers "what spent the week". Its one hard requirement is deduplication:
/// measured on a real corpus, 52.9% of turns were copies, and counting them made 186.4M tokens
/// read as 478.9M.
final class TranscriptUsageIndexTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-usage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Fixtures

    private func record(
        id: String,
        request: String,
        cwd: String = "/Users/x/repo/sonda",
        model: String = "claude-opus-4-8",
        day: String = "2026-07-22",
        input: Int = 10,
        output: Int = 20,
        cacheWrite: Int = 30,
        cacheRead: Int = 4000
    ) -> String {
        let usage = """
            {"input_tokens":\(input),"output_tokens":\(output),\
            "cache_creation_input_tokens":\(cacheWrite),"cache_read_input_tokens":\(cacheRead)}
            """
        return """
            {"type":"assistant","requestId":"\(request)","timestamp":"\(day)T10:00:00.000Z",\
            "cwd":"\(cwd)","message":{"id":"\(id)","model":"\(model)","usage":\(usage)}}
            """
    }

    @discardableResult
    private func write(_ name: String, _ lines: [String]) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Counting

    func testCountsBilledTokensAndKeepsCacheReadsApart() throws {
        let url = try write("a.jsonl", [record(id: "m1", request: "r1")])

        var deduplicator = TranscriptUsageDeduplicator()
        let entries = TranscriptUsageIndex.entries(
            inTranscriptAt: url,
            deduplicator: &deduplicator
        )
        let entry = try XCTUnwrap(entries.first)

        // input + output + cache *writes*; reads are the cheap path and would drown everything.
        XCTAssertEqual(entry.usage.billedTokens, 60)
        XCTAssertEqual(entry.usage.cachedTokens, 4000)
        XCTAssertEqual(entry.usage.turns, 1)
        XCTAssertEqual(entry.model, "claude-opus-4-8")
        XCTAssertEqual(entry.day, "2026-07-22")
        XCTAssertEqual(entry.workingDirectory, "/Users/x/repo/sonda")
    }

    /// The measured failure, in miniature: resuming and forking copy prior turns into the new
    /// transcript, so the same turn appears in several files. Counted once, or the total is
    /// wrong by more than half.
    func testTheSameTurnAcrossTranscriptsIsCountedOnce() throws {
        let shared = record(id: "m1", request: "r1")
        let parent = try write("parent.jsonl", [shared, record(id: "m2", request: "r2")])
        // A fork carries the parent's turn forward, then adds its own.
        let fork = try write("fork.jsonl", [shared, record(id: "m3", request: "r3")])

        var deduplicator = TranscriptUsageDeduplicator()
        let all = TranscriptUsageIndex.entries(
            inTranscriptAt: parent,
            deduplicator: &deduplicator
        ) + TranscriptUsageIndex.entries(
            inTranscriptAt: fork,
            deduplicator: &deduplicator
        )

        let total = all.reduce(TranscriptUsage()) { $0 + $1.usage }
        XCTAssertEqual(total.turns, 3, "four records, three distinct turns")
        XCTAssertEqual(total.billedTokens, 180)
    }

    func testStreamingPartialsKeepTheMaximumCountersAcrossTranscripts() throws {
        let parent = try write("parent.jsonl", [
            record(id: "m1", request: "r1", output: 5, cacheRead: 100)
        ])
        let fork = try write("fork.jsonl", [
            record(id: "m1", request: "r1", output: 160, cacheRead: 100),
            record(id: "m1", request: "r1", output: 20, cacheRead: 100)
        ])

        var deduplicator = TranscriptUsageDeduplicator()
        let all = TranscriptUsageIndex.entries(
            inTranscriptAt: parent,
            deduplicator: &deduplicator
        ) + TranscriptUsageIndex.entries(
            inTranscriptAt: fork,
            deduplicator: &deduplicator
        )

        let total = all.reduce(TranscriptUsage()) { $0 + $1.usage }
        XCTAssertEqual(total.turns, 1)
        XCTAssertEqual(total.billedTokens, 200)
        XCTAssertEqual(total.cachedTokens, 100)
    }

    /// Two turns can share a message id across different requests — retries do this — so the
    /// key is the pair, not either half.
    func testIdentityIsTheMessageAndRequestTogether() throws {
        let url = try write("a.jsonl", [
            record(id: "m1", request: "r1"),
            record(id: "m1", request: "r2")
        ])

        var deduplicator = TranscriptUsageDeduplicator()
        let total = TranscriptUsageIndex.entries(
            inTranscriptAt: url,
            deduplicator: &deduplicator
        )
            .reduce(TranscriptUsage()) { $0 + $1.usage }

        XCTAssertEqual(total.turns, 2)
    }

    /// A record with neither identifier is counted rather than dropped. Understating is the
    /// failure this index exists to avoid, so the tie breaks towards counting.
    func testUnidentifiableTurnsAreStillCounted() throws {
        let url = try write("a.jsonl", [
            #"{"type":"assistant","message":{"usage":{"input_tokens":5,"output_tokens":5}}}"#,
            #"{"type":"assistant","message":{"usage":{"input_tokens":5,"output_tokens":5}}}"#
        ])

        var deduplicator = TranscriptUsageDeduplicator()
        let total = TranscriptUsageIndex.entries(
            inTranscriptAt: url,
            deduplicator: &deduplicator
        )
            .reduce(TranscriptUsage()) { $0 + $1.usage }

        XCTAssertEqual(total.turns, 2)
        XCTAssertEqual(total.billedTokens, 20)
    }

    // MARK: - Buckets

    /// Quarter-hours are what let a five-hour window be measured at all; a day-resolution
    /// series cannot say what a window starting at 14:37 has consumed.
    func testTimestampsFallIntoQuarterHours() {
        XCTAssertEqual(TranscriptUsageIndex.quarterHour(of: "2026-07-22T14:37:02.000Z"), "2026-07-22T14:30")
        XCTAssertEqual(TranscriptUsageIndex.quarterHour(of: "2026-07-22T14:00:00.000Z"), "2026-07-22T14:00")
        XCTAssertEqual(TranscriptUsageIndex.quarterHour(of: "2026-07-22T14:14:59.000Z"), "2026-07-22T14:00")
        XCTAssertEqual(TranscriptUsageIndex.quarterHour(of: "2026-07-22T14:59:59.000Z"), "2026-07-22T14:45")
        XCTAssertEqual(TranscriptUsageIndex.quarterHour(of: "2026-07-22T14:09:00.000Z"), "2026-07-22T14:00")
    }

    /// A timestamp that is not a timestamp must not crash the scan or invent a bucket.
    func testMalformedTimestampsAreLeftAlone() {
        XCTAssertEqual(TranscriptUsageIndex.quarterHour(of: ""), "")
        XCTAssertEqual(TranscriptUsageIndex.quarterHour(of: "nope"), "nope")
    }

    // MARK: - Grouping

    func testSplitsByDayModelAndCheckout() throws {
        let url = try write("a.jsonl", [
            record(id: "m1", request: "r1", day: "2026-07-21"),
            record(id: "m2", request: "r2", day: "2026-07-22"),
            record(id: "m3", request: "r3", model: "claude-fable-5", day: "2026-07-22"),
            record(id: "m4", request: "r4", cwd: "/Users/x/repo/other", day: "2026-07-22")
        ])

        var deduplicator = TranscriptUsageDeduplicator()
        let entries = TranscriptUsageIndex.entries(
            inTranscriptAt: url,
            deduplicator: &deduplicator
        )

        XCTAssertEqual(entries.count, 4)
        XCTAssertEqual(Set(entries.map { $0.day }), ["2026-07-21", "2026-07-22"])
        XCTAssertEqual(Set(entries.map { $0.model }), ["claude-opus-4-8", "claude-fable-5"])
        XCTAssertEqual(
            Set(entries.map { $0.workingDirectory }),
            ["/Users/x/repo/sonda", "/Users/x/repo/other"]
        )
    }

    /// Records with no usage are the overwhelming majority of a transcript and must cost
    /// nothing but a substring test.
    func testRecordsWithoutUsageAreIgnored() throws {
        let url = try write("a.jsonl", [
            #"{"type":"user","message":{"role":"user","content":"hello"}}"#,
            #"{"type":"summary","summary":"a title"}"#,
            record(id: "m1", request: "r1")
        ])

        var deduplicator = TranscriptUsageDeduplicator()
        XCTAssertEqual(
            TranscriptUsageIndex.entries(
                inTranscriptAt: url,
                deduplicator: &deduplicator
            ).count,
            1
        )
    }

    /// Subagent threads are nested a level deeper than ordinary transcripts and hold turns that
    /// appear nowhere else — verified against a real session, where 101 subagent turns shared
    /// no identity at all with their parent. A one-level scan misses every one of them.
    func testFindsSubagentTranscriptsNestedUnderASession() throws {
        let projects = directory.appendingPathComponent("projects/-Users-x-repo-sonda")
        let subagents = projects.appendingPathComponent("session-1/subagents")
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)

        try "{}".write(
            to: projects.appendingPathComponent("session-1.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        try "{}".write(
            to: subagents.appendingPathComponent("agent-abc.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let found = TranscriptUsageIndex.transcripts(inAccountAt: directory.path)
            .map { $0.lastPathComponent }
            .sorted()

        XCTAssertEqual(found, ["agent-abc.jsonl", "session-1.jsonl"])
    }

    func testMalformedLinesDoNotStopTheScan() throws {
        let url = try write("a.jsonl", [
            "{ this is not json but mentions \"usage\" }",
            record(id: "m1", request: "r1")
        ])

        var deduplicator = TranscriptUsageDeduplicator()
        XCTAssertEqual(
            TranscriptUsageIndex.entries(
                inTranscriptAt: url,
                deduplicator: &deduplicator
            ).count,
            1
        )
    }
}

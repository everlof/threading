import XCTest
@testable import Threading

/// What this client does with a JSON integer larger than `Int64`.
///
/// **Every fixture here is built from JSON text, and it has to be.** A Swift integer literal past
/// `Int64.max` does not compile, and one inside the range never reproduces the storage
/// `JSONSerialization` chooses for an oversized number — so a literal-built test cannot observe
/// this defect at all. That is the same blind spot that hid the boolean bridge bug in `3277a3a0`
/// and the reason `ProviderWireTextCorpusTests` exists.
///
/// Three readers took `NSNumber.int64Value`/`intValue` unguarded before this: `JSONValue`'s
/// scalar bridge, which claimed `.integer` for a wrapped number; `TranscriptReplay`'s context
/// reading, which added four of them and trapped the process; and the usage adapters, which
/// clamped a wrapped negative to `0`.
final class WireIntegerTests: XCTestCase {

    // MARK: - What Foundation actually does

    /// The measurements the whole fix rests on, asserted so a platform change is a failing test
    /// rather than a silent return of the bug.
    func testFoundationHidesAnOversizedIntegerBehindAWrappedReading() throws {
        let big = try wireNumber("12345678901234567890")
        XCTAssertEqual(String(cString: big.objCType), "Q", "stored unsigned, not signed")
        XCTAssertEqual(big.doubleValue, 1.2345678901234567e19)
        XCTAssertEqual(big.int64Value, -6101065172474983726, "int64Value wraps")

        let justPast = try wireNumber("9223372036854775808")
        XCTAssertEqual(String(cString: justPast.objCType), "Q")
        XCTAssertEqual(justPast.int64Value, -9223372036854775808)

        let negative = try wireNumber("-12345678901234567890")
        XCTAssertEqual(String(cString: negative.objCType), "d", "stored as a double, not unsigned")
        XCTAssertEqual(negative.doubleValue, -1.2345678901234567e19)
        XCTAssertEqual(negative.int64Value, 6101065172474983726, "and the sign flips to positive")

        let largest = try wireNumber("9223372036854775807")
        XCTAssertEqual(String(cString: largest.objCType), "q", "an ordinary signed integer")
        XCTAssertEqual(largest.int64Value, 9223372036854775807, "which reads back exactly")
    }

    /// The guard that looks right and is not: it refuses a legitimate `Int64.max`.
    ///
    /// `doubleValue` has already rounded `9223372036854775807` to 2^63 by the time this asks, so
    /// a fix written this way demotes exact integers to approximations. `WireInteger` asks the
    /// `NSNumber` instead, and keeps it.
    func testTheObviousGuardRefusesALegitimateInt64Max() throws {
        let largest = try wireNumber("9223372036854775807")
        XCTAssertNil(Int64(exactly: largest.doubleValue), "the obvious guard says no")
        XCTAssertEqual(WireInteger.exact(largest), 9223372036854775807, "the honest one says yes")
    }

    // MARK: - WireInteger

    func testExactKeepsWhatInt64HoldsAndRefusesTheRest() throws {
        XCTAssertNil(WireInteger.exact(try wireNumber("12345678901234567890")))
        XCTAssertNil(WireInteger.exact(try wireNumber("9223372036854775808")))
        XCTAssertNil(WireInteger.exact(try wireNumber("-12345678901234567890")))
        XCTAssertNil(WireInteger.exact(try wireNumber("18446744073709551615")))
        XCTAssertNil(WireInteger.exact(try wireNumber("1e30")))

        XCTAssertEqual(WireInteger.exact(try wireNumber("9223372036854775807")), 9223372036854775807)
        XCTAssertEqual(
            WireInteger.exact(try wireNumber("-9223372036854775808")), -9223372036854775808
        )
        XCTAssertEqual(WireInteger.exact(try wireNumber("2.0")), 2, "an integral double is an integer")
        XCTAssertEqual(WireInteger.exact(try wireNumber("0")), 0)
        XCTAssertEqual(WireInteger.exact(try wireNumber("1")), 1)
        XCTAssertNil(WireInteger.exact(try wireNumber("1.5")), "not a whole number")
    }

    func testWholeTruncatesTheWayInt64ValueDoesAndStillRefusesTheOversized() throws {
        XCTAssertEqual(WireInteger.whole(try wireNumber("1.5")), 1)
        XCTAssertEqual(WireInteger.whole(try wireNumber("100.4")), 100)
        XCTAssertEqual(WireInteger.whole(try wireNumber("100.6")), 100, "toward zero, not nearest")
        XCTAssertEqual(WireInteger.whole(try wireNumber("-1.5")), -1)
        XCTAssertEqual(WireInteger.whole(try wireNumber("9223372036854775807")), 9223372036854775807)

        XCTAssertNil(WireInteger.whole(try wireNumber("12345678901234567890")))
        XCTAssertNil(WireInteger.whole(try wireNumber("9223372036854775808")))
        XCTAssertNil(WireInteger.whole(try wireNumber("-12345678901234567890")))
        XCTAssertNil(WireInteger.whole(try wireNumber("1e30")), "int64Value would saturate here")

        // A boolean is a number to `NSNumber`, and the two readers that reach `whole` were
        // already counting one as a token. That behaviour is preserved deliberately.
        XCTAssertEqual(WireInteger.whole(try wireNumber("true")), 1)
        XCTAssertEqual(WireInteger.whole(try wireNumber("false")), 0)
    }

    // MARK: - JSONValue

    /// An integer past `Int64` becomes `.number`, keeping its sign and magnitude, because
    /// `.integer` is this type's claim of exactness and the audit ledger records that claim.
    func testAnOversizedIntegerBecomesANumberRatherThanAWrappedInteger() throws {
        guard case .number(let big) = try converted("12345678901234567890") else {
            return XCTFail("expected a number, got \(try converted("12345678901234567890"))")
        }
        XCTAssertEqual(big, 1.2345678901234567e19)

        guard case .number(let justPast) = try converted("9223372036854775808") else {
            return XCTFail("expected a number, got \(try converted("9223372036854775808"))")
        }
        XCTAssertEqual(justPast, 9.223372036854776e18)
    }

    /// The negative case, where the old reading did not merely lose precision: it changed sign.
    func testAnOversizedNegativeKeepsItsSign() throws {
        XCTAssertEqual(
            try wireNumber("-12345678901234567890").int64Value, 6101065172474983726,
            "the reading this replaced answered positive"
        )
        guard case .number(let value) = try converted("-12345678901234567890") else {
            return XCTFail("expected a number, got \(try converted("-12345678901234567890"))")
        }
        XCTAssertEqual(value, -1.2345678901234567e19)
        XCTAssertLessThan(value, 0)
    }

    /// The demotion this fix must not cause, and the two readings around it.
    func testTheIntegersJSONValueStillCallsIntegers() throws {
        XCTAssertEqual(try converted("9223372036854775807"), .integer(9223372036854775807))
        XCTAssertEqual(try converted("-9223372036854775808"), .integer(-9223372036854775808))
        XCTAssertEqual(try converted("2.0"), .integer(2), "an integral double is still an integer")
        XCTAssertEqual(try converted("0"), .integer(0))
        XCTAssertEqual(try converted("1"), .integer(1))
        XCTAssertEqual(try converted("1.5"), .number(1.5))
        XCTAssertEqual(try converted("true"), .bool(true), "and a boolean is still a boolean")
        XCTAssertEqual(try converted("false"), .bool(false))
    }

    /// An oversized integer is JSON, so it is never marked as something that is not.
    func testAnOversizedIntegerIsNotMarkedUnconvertible() throws {
        switch try converted("12345678901234567890") {
        case .number:
            break
        case .unconvertible(let describedType):
            XCTFail("a big integer is valid JSON, not \(describedType)")
        case .object, .array, .string, .integer, .bool, .null:
            XCTFail("expected a number")
        }

        // The strict bridge answers the same way rather than refusing the container it is in.
        let value = try XCTUnwrap(JSONValue(foundationValue: try wireNumber("12345678901234567890")))
        guard case .number = value else { return XCTFail("expected a number, got \(value)") }
    }

    // MARK: - TranscriptReplay: the crash

    /// Four `usage` terms, two of them oversized. This trapped the process before the fix.
    ///
    /// `int64Value` handed Swift's `+` two wrapped negatives whose sum is below `Int64.min`, and
    /// `+` traps on overflow — measured as `Trace/BPT trap: 5`, exit 133, against the reader this
    /// replaced. `TranscriptReplay` reads transcript files from disk, so opening a conversation
    /// whose file holds such a value crashed the app, and crashed it again on every reopen.
    func testAContextReadingWithTwoOversizedTermsDoesNotCrash() throws {
        let readings = try contextReadings(fromClaudeUsage: #"""
        {"input_tokens":12345678901234567890,"cache_read_input_tokens":12345678901234567890,
         "cache_creation_input_tokens":0,"output_tokens":10}
        """#)
        XCTAssertEqual(readings, [nil], "the turn ends with no reading rather than a wrong one")
    }

    /// The other half of the same crash, which exactness alone does not fix: two terms that read
    /// *exactly* and whose sum still overflows. Only overflow-safe addition removes this one.
    func testAContextReadingWhoseExactTermsOverflowDoesNotCrash() throws {
        let readings = try contextReadings(fromClaudeUsage: #"""
        {"input_tokens":9223372036854775807,"cache_read_input_tokens":9223372036854775807,
         "output_tokens":0}
        """#)
        XCTAssertEqual(readings, [nil])
    }

    /// One unreadable term makes the whole reading unknown rather than a quieter wrong number.
    func testOneOversizedTermRefusesTheWholeReading() throws {
        let readings = try contextReadings(fromClaudeUsage: #"""
        {"input_tokens":100,"cache_read_input_tokens":12345678901234567890,"output_tokens":10}
        """#)
        XCTAssertEqual(readings, [nil], "110 would understate the window with nothing to say so")
    }

    /// And the ordinary reading is untouched: four readable terms still add up.
    func testAnOrdinaryContextReadingStillAddsUp() throws {
        let readings = try contextReadings(fromClaudeUsage: #"""
        {"input_tokens":100,"cache_read_input_tokens":20,
         "cache_creation_input_tokens":5,"output_tokens":10}
        """#)
        XCTAssertEqual(readings, [135])
    }

    /// Codex reports one number rather than four, and an oversized one is refused the same way.
    /// Its `model_context_window` is an adjunct, so an unreadable one costs only itself.
    func testCodexContextReadingsRefuseAnOversizedTotalAndKeepTheWindowSeparate() throws {
        let directory = try ProviderWireTextCorpus.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try XCTUnwrap(ProviderWireTextCorpus.write(#"""
        {"type":"event_msg","timestamp":"2026-08-27T09:59:59Z","payload":{"type":"user_message","message":"go"}}
        {"type":"event_msg","timestamp":"2026-08-27T10:00:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":4000},"model_context_window":12345678901234567890}}}
        """#, to: directory, named: "codex-oversized-window.jsonl"))

        let readings = TranscriptReplay.read(at: url, kind: .codex).0
            .compactMap { event -> (Int?, Int?)? in
                guard case .turnFinished(_, _, let metrics) = event else { return nil }
                return (metrics.contextTokens, metrics.contextWindow)
            }
        XCTAssertEqual(readings.count, 1)
        XCTAssertEqual(readings.first?.0, 4000, "the total is readable and is kept")
        XCTAssertNil(readings.first?.1, "the window is not, and costs only itself")
    }

    // MARK: - Usage adapters

    /// An oversized count no longer files a billed response as one that used no tokens.
    func testAnOversizedClaudeCountRefusesItsLineAndKeepsTheOthers() throws {
        let directory = try ProviderWireTextCorpus.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try XCTUnwrap(ProviderWireTextCorpus.write(#"""
        {"type":"assistant","timestamp":"2026-08-27T10:00:00Z","requestId":"r1","cwd":"/tmp","message":{"id":"m1","model":"claude-sonnet-4-5","usage":{"input_tokens":12345678901234567890,"output_tokens":200}}}
        {"type":"assistant","timestamp":"2026-08-27T10:00:01Z","requestId":"r2","cwd":"/tmp","message":{"id":"m2","model":"claude-sonnet-4-5","usage":{"input_tokens":1000,"output_tokens":200}}}
        """#, to: directory, named: "claude-oversized.jsonl"))

        let records = ClaudeUsageAdapter.records(
            inTranscriptAt: url, accountID: "a", accountName: "A"
        )
        XCTAssertEqual(records.count, 1, "the unreadable line produces no record")
        XCTAssertEqual(records.first?.identity, "claude|m2|r2", "and the readable one still does")
        XCTAssertEqual(records.first?.tokens.uncachedInput, 1000)
    }

    /// A count of exactly `Int64.max` is a number this app can hold, so it is kept.
    func testAClaudeCountOfInt64MaxIsKeptRatherThanRefused() throws {
        let directory = try ProviderWireTextCorpus.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try XCTUnwrap(ProviderWireTextCorpus.write(#"""
        {"type":"assistant","timestamp":"2026-08-27T10:00:00Z","requestId":"r1","cwd":"/tmp","message":{"id":"m1","model":"m","usage":{"input_tokens":9223372036854775807,"output_tokens":0}}}
        """#, to: directory, named: "claude-int64-max.jsonl"))

        let records = ClaudeUsageAdapter.records(
            inTranscriptAt: url, accountID: "a", accountName: "A"
        )
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.tokens.uncachedInput, 9223372036854775807)
    }

    func testAnOversizedCodexCountRefusesItsRecord() throws {
        let directory = try ProviderWireTextCorpus.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try XCTUnwrap(ProviderWireTextCorpus.write(#"""
        {"type":"session_meta","timestamp":"2026-08-27T10:00:00Z","payload":{"id":"s1","cwd":"/tmp","model":"gpt-5"}}
        {"type":"event_msg","timestamp":"2026-08-27T10:00:01Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":12345678901234567890,"output_tokens":5}}}}
        {"type":"event_msg","timestamp":"2026-08-27T10:00:02Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":30,"output_tokens":5}}}}
        """#, to: directory, named: "codex-oversized.jsonl"))

        let records = CodexUsageAdapter.records(
            inRolloutAt: url, accountID: "a", accountName: "A"
        )
        XCTAssertEqual(records.count, 1, "the unreadable record is refused, the readable one is not")
        XCTAssertEqual(records.first?.tokens.output, 5)
    }

    /// OpenCode's adapter refuses the whole export for one unreadable message, and an oversized
    /// count is now one of the things that makes a message unreadable. That is its stated
    /// contract: its answer is a single total a person reads as *the* cost of the session, and
    /// `TranscriptUsageService` turns the refusal into a visible coverage gap.
    func testAnOversizedOpenCodeCountRefusesTheWholeExport() {
        let data = Data(#"""
        {"info":{"id":"s1","directory":"/tmp"},"messages":[{"info":{
          "id":"m1","role":"assistant","providerID":"anthropic","modelID":"m",
          "tokens":{"input":12345678901234567890,"output":600},
          "time":{"created":1754654400}}}]}
        """#.utf8)

        XCTAssertThrowsError(try OpenCodeUsageAdapter.records(fromExport: data)) { error in
            XCTAssertEqual(
                error as? OpenCodeUsageAdapter.Failure, .unreadableMessage(index: 0)
            )
        }
    }

    // MARK: - Helpers

    /// One JSON number, parsed from text, as `JSONSerialization` hands it over.
    private func wireNumber(_ text: String) throws -> NSNumber {
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data("{\"v\":\(text)}".utf8)) as? [String: Any]
        )
        return try XCTUnwrap(object["v"] as? NSNumber)
    }

    private func converted(_ text: String) throws -> JSONValue {
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data("{\"v\":\(text)}".utf8)) as? [String: Any]
        )
        return JSONValue.converting(foundationValue: try XCTUnwrap(object["v"]))
    }

    /// The context readings a replayed Claude transcript carrying exactly this `usage` object
    /// produces, one per turn end.
    ///
    /// A replayed turn only reports metrics once a user record has opened it, so the fixture
    /// carries the opening record — without it there is no `.turnFinished` to read and an
    /// unreadable count would look fixed by being invisible.
    private func contextReadings(fromClaudeUsage usage: String) throws -> [Int?] {
        let directory = try ProviderWireTextCorpus.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let compacted = usage.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined()
        let url = try XCTUnwrap(ProviderWireTextCorpus.write("""
        {"type":"user","timestamp":"2026-08-27T09:59:59Z","message":{"content":"go"}}
        {"type":"assistant","timestamp":"2026-08-27T10:00:00Z","message":{"usage":\(compacted),\
        "content":[{"type":"text","text":"hi"}]}}
        """, to: directory, named: "claude-usage.jsonl"))

        var readings: [Int?] = []
        for event in TranscriptReplay.read(at: url, kind: .claude).0 {
            guard case .turnFinished(_, _, let metrics) = event else { continue }
            readings.append(metrics.contextTokens)
        }
        return readings
    }
}

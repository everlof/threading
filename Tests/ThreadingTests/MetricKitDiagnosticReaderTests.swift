import Foundation
import XCTest
@testable import Threading

/// The payloads MetricKit leaves behind were write-only sediment until something read them back.
///
/// What is pinned here is mostly the difference between four answers that a naive reader collapses
/// into one: never delivered, delivered nothing, delivered something, and delivered something this
/// build could not parse. Only the last one is a reason to distrust the rest of the report, and a
/// reader that returns "no diagnostics" for a directory full of corrupt blobs says the opposite.
final class MetricKitDiagnosticReaderTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("metrickit-reader-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        try super.tearDownWithError()
    }

    // MARK: - The Four Answers

    func testAMissingDirectoryIsNotAnEmptyOne() {
        XCTAssertEqual(MetricKitDiagnosticReader(directory: directory).read(), .noDirectory)
    }

    func testADirectoryWithNoPayloadsReadsAsEmpty() throws {
        try makeDirectory()
        XCTAssertEqual(MetricKitDiagnosticReader(directory: directory).read(), .empty)
    }

    /// The load-bearing case. A truncated payload must not read as "MetricKit saw no crash".
    func testACorruptPayloadIsUnreadableRatherThanEmpty() throws {
        try write(named: "1750000000-1750086400", contents: "{\"crashDiagnostics\": [")

        XCTAssertEqual(
            MetricKitDiagnosticReader(directory: directory).read(),
            .unreadable(payloadFiles: 1)
        )
    }

    /// Valid JSON that is not a diagnostic payload is not a diagnostic payload. Accepting it would
    /// report a healthy machine on the strength of a file that says nothing at all.
    func testJSONThatIsNotAPayloadIsUnreadable() throws {
        try write(named: "1750000000-1750086400", contents: "{\"hello\": \"world\"}")
        try write(named: "1750086400-1750172800", contents: "[1, 2, 3]")

        XCTAssertEqual(
            MetricKitDiagnosticReader(directory: directory).read(),
            .unreadable(payloadFiles: 2)
        )
    }

    /// A directory that exists and cannot be listed is an error, not an empty inventory. It is
    /// reported with no payload files because none could be counted, which is the honest answer.
    func testAnUnlistableDirectoryIsUnreadable() throws {
        try makeDirectory()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: directory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: directory.path
            )
        }

        // Running as root defeats the permission bits, and CI may. Skip rather than assert a
        // platform behaviour the test cannot arrange.
        try XCTSkipIf(
            (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) != nil,
            "This process can list a 0o000 directory, so the failure cannot be staged"
        )

        XCTAssertEqual(
            MetricKitDiagnosticReader(directory: directory).read(),
            .unreadable(payloadFiles: 0)
        )
    }

    // MARK: - What The Payloads Say

    func testACrashPayloadReportsItsCountAndIdentifyingFacts() throws {
        try write(named: "1750000000-1750086400", contents: Fixtures.crash)

        let summary = try readSummary()
        XCTAssertEqual(summary.payloadCount, 1)
        XCTAssertEqual(summary.crashCount, 1)
        XCTAssertEqual(summary.hangCount, 0)
        XCTAssertEqual(summary.unreadablePayloadCount, 0)
        XCTAssertEqual(summary.skippedPayloadCount, 0)

        let crash = try XCTUnwrap(summary.mostRecentCrash)
        XCTAssertEqual(crash.appVersion, "1.4.2")
        XCTAssertEqual(crash.appBuildVersion, "311")
        XCTAssertEqual(crash.exceptionType, 1)
        XCTAssertEqual(crash.exceptionCode, 0)
        XCTAssertEqual(crash.signal, 11)
    }

    func testAHangPayloadIsCountedAsAHangAndCarriesNoCrash() throws {
        try write(named: "1750000000-1750086400", contents: Fixtures.hang)

        let summary = try readSummary()
        XCTAssertEqual(summary.hangCount, 1)
        XCTAssertEqual(summary.crashCount, 0)
        XCTAssertNil(summary.mostRecentCrash)
    }

    func testCountsAndTheCoveredWindowSpanEveryPayload() throws {
        try writeAllThreeFixtures()

        let summary = try readSummary()
        XCTAssertEqual(summary.payloadCount, 3)
        XCTAssertEqual(summary.crashCount, 3)
        XCTAssertEqual(summary.hangCount, 3)
        XCTAssertEqual(summary.cpuExceptionCount, 1)
        XCTAssertEqual(summary.diskWriteExceptionCount, 1)

        // The fixtures state their own timestamps; the window is the outermost pair of them.
        XCTAssertEqual(summary.coveredFrom, Self.date("2026-07-30T00:00:00Z"))
        XCTAssertEqual(summary.coveredTo, Self.date("2026-08-07T00:00:00Z"))
    }

    /// "Most recent" is the newest payload that carries one, and the last entry inside it — Apple
    /// documents no order within a payload's own array, so the payload is what makes the answer
    /// defensible. The newest payload here holds two crashes and is not the newest file written.
    func testTheReportedCrashComesFromTheNewestPayloadCarryingOne() throws {
        try writeAllThreeFixtures()

        let crash = try XCTUnwrap(readSummary().mostRecentCrash)
        XCTAssertEqual(crash.appVersion, "2.0.0")
    }

    /// Ordering follows the timestamps in the payloads, not the order the files happen to sit in.
    func testTheNewestPayloadIsChosenByItsTimestampsRatherThanItsName() throws {
        try write(named: "1750000000-1750086400", contents: Fixtures.mixed)
        try write(named: "1750172800-1750259200", contents: Fixtures.crash)

        // `crash` covers 2026-08-04..05 and `mixed` covers 2026-08-06..07, so the file named last
        // is the older payload and must not win.
        let crash = try XCTUnwrap(readSummary().mostRecentCrash)
        XCTAssertEqual(crash.appVersion, "2.0.0")
    }

    // MARK: - Written By Whatever macOS Was Running

    /// `exceptionType` has been a number and a string across releases. A strict decode would throw
    /// inside the payload and discard a perfectly readable crash over a field nobody needed.
    func testScalarsThatChangedTypeBetweenReleasesStillParse() throws {
        try write(named: "1750000000-1750086400", contents: Fixtures.stringScalars)

        let crash = try XCTUnwrap(readSummary().mostRecentCrash)
        XCTAssertEqual(crash.exceptionType, 1)
        XCTAssertEqual(crash.signal, 11)
    }

    /// Apple writes a sentence; a support field takes a token. The reader reduces it, so no
    /// consumer can pass an OS-authored string through untouched.
    func testTheTerminationReasonIsReducedToOneToken() throws {
        try write(named: "1750000000-1750086400", contents: Fixtures.crash)

        let reason = try XCTUnwrap(readSummary().mostRecentCrash?.terminationReason)
        XCTAssertEqual(reason, "Namespace-SIGNAL-Code-0xb")
        XCTAssertFalse(reason.contains(" "))
        XCTAssertFalse(reason.contains("/"))
    }

    /// The payload's timestamps are formatted by whichever macOS wrote it. The file name is ours,
    /// and is epoch seconds, so it is the fallback that cannot be reformatted out from under us.
    func testTheFileNameSuppliesTheWindowWhenThePayloadTimestampsDoNot() throws {
        try write(named: "1750000000-1750086400", contents: Fixtures.undatedCrash)

        let summary = try readSummary()
        XCTAssertEqual(summary.coveredFrom, Date(timeIntervalSince1970: 1_750_000_000))
        XCTAssertEqual(summary.coveredTo, Date(timeIntervalSince1970: 1_750_086_400))
    }

    // MARK: - Bounded Work

    /// The writer already prunes to 20. The reader states its own budget anyway, because a budget
    /// enforced only by the other side of a boundary is not a budget.
    func testTheDirectoryIsReadWithinItsOwnBudget() throws {
        let extra = 6
        let total = MetricKitReadBudget.maximumPayloadFiles + extra
        for index in 0..<total {
            let began = 1_750_000_000 + index * 86_400
            try write(named: "\(began)-\(began + 86_400)", contents: Fixtures.hang)
        }

        let summary = try readSummary()
        XCTAssertEqual(summary.payloadCount, MetricKitReadBudget.maximumPayloadFiles)
        XCTAssertEqual(summary.skippedPayloadCount, extra)
        XCTAssertEqual(summary.unreadablePayloadCount, 0)
    }

    /// A file past the byte budget is refused rather than parsed, and refusing counts — the
    /// alternative is a report that quietly excludes the one payload that mattered.
    func testAPayloadPastTheByteBudgetIsCountedAsUnreadable() throws {
        let padding = String(
            repeating: "x",
            count: MetricKitReadBudget.maximumPayloadBytes + 1
        )
        try write(named: "1750000000-1750086400", contents: Fixtures.crash)
        try write(
            named: "1750086400-1750172800",
            contents: "{\"hangDiagnostics\": [], \"padding\": \"\(padding)\"}"
        )

        let summary = try readSummary()
        XCTAssertEqual(summary.payloadCount, 1)
        XCTAssertEqual(summary.unreadablePayloadCount, 1)
    }

    /// A damaged file beside a readable one loses that file, not the answer.
    func testACorruptPayloadBesideAValidOneIsCountedNotFatal() throws {
        try write(named: "1750000000-1750086400", contents: Fixtures.crash)
        try write(named: "1750086400-1750172800", contents: "{ truncated")

        let summary = try readSummary()
        XCTAssertEqual(summary.payloadCount, 1)
        XCTAssertEqual(summary.crashCount, 1)
        XCTAssertEqual(summary.unreadablePayloadCount, 1)
    }

    func testFilesThatAreNotPayloadsAreIgnoredEntirely() throws {
        try write(named: "1750000000-1750086400", contents: Fixtures.crash)
        try makeDirectory()
        try "not a payload".write(
            to: directory.appendingPathComponent("README.txt"),
            atomically: true,
            encoding: .utf8
        )

        let summary = try readSummary()
        XCTAssertEqual(summary.payloadCount, 1)
        XCTAssertEqual(summary.unreadablePayloadCount, 0)
    }

    // MARK: - What Is Never Read

    /// The cheapest redaction is the field that was never decoded. A crash payload's call tree is
    /// most of its bytes and none of its usefulness in a support conversation.
    func testNoIdentifyingFactCarriesACallStackOrAnAddress() throws {
        try write(named: "1750000000-1750086400", contents: Fixtures.crash)

        let crash = try XCTUnwrap(readSummary().mostRecentCrash)
        let values = [
            crash.appVersion, crash.appBuildVersion, crash.terminationReason
        ].compactMap { $0 }

        for value in values {
            XCTAssertFalse(value.contains("0x1"), "\(value) looks like an address")
            XCTAssertFalse(value.contains("/"), "\(value) looks like a path")
            XCTAssertFalse(value.contains(" "), "\(value) is not one token")
            XCTAssertLessThanOrEqual(value.count, MetricKitReadBudget.maximumTokenCharacters)
        }
    }

    // MARK: - Helpers

    private enum Failure: Error, CustomStringConvertible {
        case notReadable(String)

        var description: String {
            switch self {
            case .notReadable(let reading): "Expected a readable summary, got \(reading)"
            }
        }
    }

    private func readSummary() throws -> MetricKitDiagnosticSummary {
        let reading = MetricKitDiagnosticReader(directory: directory).read()
        guard case .read(let summary) = reading else {
            throw Failure.notReadable(String(describing: reading))
        }
        return summary
    }

    /// The three fixtures in one directory, named so that file order and payload order disagree.
    private func writeAllThreeFixtures() throws {
        try write(named: "1750000000-1750086400", contents: Fixtures.hang)
        try write(named: "1750086400-1750172800", contents: Fixtures.mixed)
        try write(named: "1750172800-1750259200", contents: Fixtures.crash)
    }

    private func makeDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func write(named name: String, contents: String) throws {
        try makeDirectory()
        try contents.write(
            to: directory.appendingPathComponent("\(name).json"),
            atomically: true,
            encoding: .utf8
        )
    }

    private static func date(_ iso: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)
    }
}

// MARK: - Fixtures

/// Shaped after `MXDiagnosticPayload.jsonRepresentation()`, trimmed to the keys the reader looks
/// at plus one it must ignore. The call-stack tree is present on purpose: a fixture without it
/// would not prove that the reader leaves it alone.
private enum Fixtures {

    static let crash = """
    {
      "timeStampBegin": "2026-08-04 00:00:00",
      "timeStampEnd": "2026-08-05 00:00:00",
      "crashDiagnostics": [
        {
          "version": "1.0.0",
          "callStackTree": {
            "callStackPerThread": true,
            "callStacks": [
              {
                "threadAttributed": true,
                "callStackRootFrames": [
                  {
                    "binaryUUID": "8B7B0F5C-0C0F-4C0F-9C0F-0C0F4C0F9C0F",
                    "offsetIntoBinaryTextSegment": 123456,
                    "binaryName": "Threading",
                    "address": 4310384128
                  }
                ]
              }
            ]
          },
          "diagnosticMetaData": {
            "appVersion": "1.4.2",
            "appBuildVersion": "311",
            "osVersion": "macOS 15.5 (24F74)",
            "platformArchitecture": "arm64e",
            "regionFormat": "SE",
            "exceptionType": 1,
            "exceptionCode": 0,
            "signal": 11,
            "terminationReason": "Namespace SIGNAL, Code 0xb",
            "virtualMemoryRegionInfo": "0x0 is not in any region."
          }
        }
      ],
      "hangDiagnostics": [],
      "cpuExceptionDiagnostics": [],
      "diskWriteExceptionDiagnostics": []
    }
    """

    static let hang = """
    {
      "timeStampBegin": "2026-07-30 00:00:00",
      "timeStampEnd": "2026-07-31 00:00:00",
      "crashDiagnostics": [],
      "hangDiagnostics": [
        {
          "version": "1.0.0",
          "diagnosticMetaData": {
            "appVersion": "1.4.1",
            "appBuildVersion": "308",
            "osVersion": "macOS 15.5 (24F74)",
            "hangDuration": "4 sec"
          }
        }
      ]
    }
    """

    /// Two crashes, two hangs, one CPU exception and one disk-write exception in one payload, and
    /// the newest window of the three.
    static let mixed = """
    {
      "timeStampBegin": "2026-08-06 00:00:00",
      "timeStampEnd": "2026-08-07 00:00:00",
      "crashDiagnostics": [
        {
          "diagnosticMetaData": {
            "appVersion": "1.9.9",
            "appBuildVersion": "400",
            "exceptionType": 1,
            "signal": 6
          }
        },
        {
          "diagnosticMetaData": {
            "appVersion": "2.0.0",
            "appBuildVersion": "401",
            "exceptionType": 1,
            "signal": 11
          }
        }
      ],
      "hangDiagnostics": [
        { "diagnosticMetaData": { "hangDuration": "3 sec" } },
        { "diagnosticMetaData": { "hangDuration": "9 sec" } }
      ],
      "cpuExceptionDiagnostics": [
        { "diagnosticMetaData": { "totalCPUTime": "45 sec" } }
      ],
      "diskWriteExceptionDiagnostics": [
        { "diagnosticMetaData": { "writesCaused": "1024 mB" } }
      ]
    }
    """

    /// The same crash after a hypothetical release moved its scalars to strings.
    static let stringScalars = """
    {
      "timeStampBegin": "2026-08-04T00:00:00.000Z",
      "timeStampEnd": "2026-08-05T00:00:00.000Z",
      "crashDiagnostics": [
        {
          "diagnosticMetaData": {
            "appVersion": "1.4.2",
            "exceptionType": "1",
            "signal": "11"
          }
        }
      ]
    }
    """

    /// No timestamps at all, so only the file name can say when this was.
    static let undatedCrash = """
    {
      "crashDiagnostics": [
        { "diagnosticMetaData": { "appVersion": "1.4.2", "signal": 11 } }
      ]
    }
    """
}

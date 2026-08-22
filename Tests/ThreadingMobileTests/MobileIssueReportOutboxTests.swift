import XCTest
import ThreadingRemoteKit
@testable import ThreadingMobile

final class MobileIssueReportOutboxTests: XCTestCase {

    /// One queued report, shaped the way the consent screen writes them.
    private func submission(
        id: String,
        directory: URL
    ) throws -> PublicIssueReportSubmissionDTO {
        let report = RemoteDiagnosticJournal(
            directory: directory.appendingPathComponent("diagnostics", isDirectory: true),
            source: .iOSClient,
        ).supportReport(
            appVersion: "1",
            appBuild: "1",
            operatingSystem: "iOS",
            protocolVersion: RemoteProtocol.current,
            minimumProtocolVersion: RemoteProtocol.minimumSupported,
        )
        return PublicIssueReportSubmissionDTO(
            id: id,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            trigger: "diagnostics",
            description: "Connectivity fixture",
            diagnostics: PublicIssueReportDiagnosticsDTO(bounding: report)
        )
    }
    func testConnectivityRetryMonitorFollowsForegroundLifetime() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mobile-issue-outbox-\(UUID().uuidString)",
            isDirectory: true
        )
        let outbox = MobileIssueReportOutbox(
            directory: directory,
            endpoint: URL(string: "https://example.invalid/v1/reports")!
        )

        await outbox.setConnectivityRetryActive(true)
        let active = await outbox.connectivityRetryIsActive
        XCTAssertTrue(active)

        await outbox.setConnectivityRetryActive(false)
        let inactive = await outbox.connectivityRetryIsActive
        XCTAssertFalse(inactive)

        try? FileManager.default.removeItem(at: directory)
    }

    func testFailedDeliveryRecordsOneTimedAttemptAndKeepsTheReportQueued() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mobile-issue-outbox-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let reportID = UUID().uuidString.lowercased()
        let now = ISO8601DateFormatter().string(from: Date())
        let report = RemoteDiagnosticJournal(
            directory: directory.appendingPathComponent("diagnostics", isDirectory: true),
            source: .iOSClient,
        ).supportReport(
            appVersion: "1",
            appBuild: "1",
            operatingSystem: "iOS",
            protocolVersion: RemoteProtocol.current,
            minimumProtocolVersion: RemoteProtocol.minimumSupported,
        )
        let submission = PublicIssueReportSubmissionDTO(
            id: reportID,
            createdAt: now,
            trigger: "diagnostics",
            description: "Connectivity fixture",
            diagnostics: PublicIssueReportDiagnosticsDTO(bounding: report)
        )
        try JSONEncoder().encode(submission).write(
            to: directory.appendingPathComponent("\(reportID).json"),
            options: .atomic
        )
        let outbox = MobileIssueReportOutbox(
            directory: directory,
            endpoint: URL(string: "http://127.0.0.1:1/v1/reports")!
        )

        await outbox.flush()

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("\(reportID).json").path
        ))
        let records = MobileDiagnostics.journal.records().filter {
            $0.fields[RemoteDiagnosticField.trace.rawValue] == reportID
        }
        let started = try XCTUnwrap(records.last {
            $0.event == .issueReportSubmissionStarted
        })
        let deferred = try XCTUnwrap(records.last {
            $0.event == .issueReportSubmissionDeferred
        })
        XCTAssertEqual(started.fields[RemoteDiagnosticField.timeoutMS.rawValue], "30000")
        XCTAssertEqual(deferred.fields[RemoteDiagnosticField.result.rawValue], "queued")
        XCTAssertNotNil(deferred.fields[RemoteDiagnosticField.durationMS.rawValue])
    }

    /// The 2026-08-21 report carries 251 delivery attempts and 250 deferrals for one report id,
    /// every one of them the same TLS refusal answered in under a second, several of them seconds
    /// apart. `flush()` runs at launch, on every foreground, and on every path update the monitor
    /// calls satisfied. Nothing stood between an endpoint that was not going to answer and an
    /// unbounded number of handshakes, and those 500 records were written into the same bounded
    /// journal ring the report exists to carry.
    func testAnAutomaticRetryWaitsOutTheDelayTheLastFailureEarned() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mobile-issue-outbox-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let reportID = UUID().uuidString.lowercased()
        try JSONEncoder().encode(try submission(id: reportID, directory: directory)).write(
            to: directory.appendingPathComponent("\(reportID).json"),
            options: .atomic
        )
        let outbox = MobileIssueReportOutbox(
            directory: directory,
            endpoint: URL(string: "http://127.0.0.1:1/v1/reports")!
        )

        await outbox.flush()
        await outbox.flush()
        await outbox.flush()

        let started = MobileDiagnostics.journal.records().filter {
            $0.event == .issueReportSubmissionStarted
                && $0.fields[RemoteDiagnosticField.trace.rawValue] == reportID
        }
        XCTAssertEqual(
            started.count,
            1,
            "three flushes in the same second are one delivery, not three"
        )
        let deferred = try XCTUnwrap(MobileDiagnostics.journal.records().last {
            $0.event == .issueReportSubmissionDeferred
                && $0.fields[RemoteDiagnosticField.trace.rawValue] == reportID
        })
        XCTAssertEqual(deferred.fields[RemoteDiagnosticField.attempt.rawValue], "1")
        XCTAssertEqual(
            deferred.fields[RemoteDiagnosticField.delayMS.rawValue],
            MobileDiagnostics.milliseconds(MobileIssueReportOutbox.retryDelay(afterAttempt: 1)),
            "the report says what the next attempt is waiting for"
        )
    }

    /// The delay doubles and then stops doubling. A dead endpoint costs a handful of handshakes
    /// over a quarter of an hour rather than hundreds over an evening.
    func testTheRetryDelayDoublesToACeiling() {
        let delays = (1...10).map(MobileIssueReportOutbox.retryDelay(afterAttempt:))

        XCTAssertEqual(delays[0], 30)
        XCTAssertEqual(delays[1], 60)
        XCTAssertEqual(delays[2], 120)
        XCTAssertEqual(delays.last, 15 * 60)
        XCTAssertEqual(delays, delays.sorted(), "a delay never shrinks with more failures")
        XCTAssertLessThan(
            delays.reduce(0, +) / Double(delays.count),
            15 * 60,
            "the ceiling is a ceiling, not the first value"
        )
    }

    /// An endpoint is stated or absent, never assumed. This side carried a compiled-in
    /// `remote.threading.codes` fallback, and that host is not serving the intake: its DNS is the
    /// registrar's parking record and the address behind it answers a TLS ClientHello with a
    /// handshake_failure alert and no certificate. That is the `url.-1200` in the 2026-08-21
    /// report, 250 times, with not one delivery anywhere in the journal.
    func testAnIntakeIsStatedOrAbsentAndNeverAssumed() {
        XCTAssertNil(
            MobileIssueReportOutbox.configuredEndpoint(infoDictionary: [:]),
            "no compiled-in fallback: a build that states no endpoint delivers nothing"
        )
        XCTAssertNil(
            MobileIssueReportOutbox.configuredEndpoint(
                infoDictionary: ["ThreadingReportIntakeURL": ""]
            ),
            "an empty key states nothing"
        )
        XCTAssertEqual(
            MobileIssueReportOutbox.configuredEndpoint(
                infoDictionary: ["ThreadingReportIntakeURL": "https://intake.example/v1/reports"]
            ),
            URL(string: "https://intake.example/v1/reports")
        )
    }

    /// A build with no intake keeps its record and makes no attempt, rather than spending
    /// handshakes and journal records on an address nobody chose.
    func testWithNoIntakeTheReportIsKeptAndNothingIsAttempted() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mobile-issue-outbox-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let reportID = UUID().uuidString.lowercased()
        try JSONEncoder().encode(try submission(id: reportID, directory: directory)).write(
            to: directory.appendingPathComponent("\(reportID).json"),
            options: .atomic
        )
        let outbox = MobileIssueReportOutbox(
            directory: directory,
            endpoint: nil,
            infoDictionary: [:]
        )

        await outbox.flush()

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("\(reportID).json").path
            ),
            "the report is kept, exportable, and not thrown away"
        )
        XCTAssertTrue(
            MobileDiagnostics.journal.records().allSatisfy {
                $0.fields[RemoteDiagnosticField.trace.rawValue] != reportID
            },
            "no attempt was made, so there is no delivery record to write"
        )
    }

    func testShareArchiveContainsEveryPreparedReportFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mobile-issue-archive-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let diagnostics = directory.appendingPathComponent("source-diagnostics.json")
        let note = directory.appendingPathComponent("source-note.txt")
        let screenshot = directory.appendingPathComponent("source-screenshot.png")
        let expected: [(String, Data)] = [
            (MobileIssueReportArchive.diagnosticsFileName, Data("{\"records\":[]}".utf8)),
            (MobileIssueReportArchive.reporterNoteFileName, Data("The screen froze".utf8)),
            (MobileIssueReportArchive.screenshotFileName, Data([0x89, 0x50, 0x4e, 0x47])),
        ]
        for (url, item) in zip([diagnostics, note, screenshot], expected) {
            try item.1.write(to: url)
        }

        let entries = try MobileIssueReportArchive.entries(
            diagnosticsURL: diagnostics,
            reporterNoteURL: note,
            screenshotURL: screenshot
        )
        let archiveURL = try MobileIssueReportArchive.write(
            diagnosticsURL: diagnostics,
            reporterNoteURL: note,
            screenshotURL: screenshot,
            modified: Date(timeIntervalSince1970: 1_700_000_000),
            outputDirectory: directory
        )

        XCTAssertEqual(entries.map(\.path), expected.map { $0.0 })
        XCTAssertEqual(entries.map(\.data), expected.map { $0.1 })
        XCTAssertEqual(archiveURL.lastPathComponent, "threading-report.zip")
        XCTAssertTrue(try Data(contentsOf: archiveURL).starts(with: [0x50, 0x4b, 0x03, 0x04]))
    }
}

import XCTest
import ThreadingRemoteKit
@testable import ThreadingMobile

final class MobileIssueReportOutboxTests: XCTestCase {
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

import XCTest
@testable import SkalmanRemoteKit

final class RemoteDiagnosticsTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-diagnostics-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil
        try super.tearDownWithError()
    }

    func testJournalRoundTripsTypedRecordsInOrder() {
        let journal = RemoteDiagnosticJournal(directory: directory, source: .iOSClient)
        journal.record(.socketConnecting, fields: [.session: "session-a"])
        journal.record(.socketConnected, fields: [.transport: "websocket"])

        XCTAssertEqual(journal.records().map(\.event), [.socketConnecting, .socketConnected])
        XCTAssertEqual(journal.records().last?.fields["transport"], "websocket")
    }

    func testJournalBoundsAndStripsFieldValues() {
        let journal = RemoteDiagnosticJournal(directory: directory, source: .iOSClient)
        journal.record(.socketFailed, fields: [
            .code: "line-one\nline-two\u{0000}" + String(repeating: "x", count: 300)
        ])

        let value = journal.records().first?.fields["code"] ?? ""
        XCTAssertFalse(value.contains("\n"))
        XCTAssertFalse(value.contains("\u{0000}"))
        XCTAssertLessThanOrEqual(value.utf8.count, 160)
        XCTAssertTrue(value.hasSuffix("…"))
    }

    func testSupportReportCarriesBuildAndProtocolWithoutInventingContentFields() throws {
        let journal = RemoteDiagnosticJournal(directory: directory, source: .iOSClient)
        journal.record(.notificationReceived, fields: [
            .trace: "event-1",
            .kind: "permissionRequest",
        ])

        let url = try journal.writeSupportReport(
            appVersion: "1.2",
            appBuild: "34",
            operatingSystem: "iOS 18",
            protocolVersion: 4,
            minimumProtocolVersion: 3,
            to: directory
        )
        let report = try JSONDecoder().decode(
            RemoteDiagnosticReport.self,
            from: Data(contentsOf: url)
        )

        XCTAssertEqual(report.schemaVersion, 1)
        XCTAssertEqual(report.appVersion, "1.2")
        XCTAssertEqual(report.protocolVersion, 4)
        XCTAssertEqual(report.records.first?.fields["trace"], "event-1")
        XCTAssertNil(report.records.first?.fields["message"])
        XCTAssertNil(report.records.first?.fields["token"])
    }

    func testAdditionalDetailsRequireTypedOptInAndRemainBounded() throws {
        let journal = RemoteDiagnosticJournal(directory: directory, source: .iOSClient)
        let url = try journal.writeSupportReport(
            appVersion: "1",
            appBuild: "2",
            operatingSystem: "iOS",
            protocolVersion: 3,
            minimumProtocolVersion: 2,
            additionalDetails: [
                .deviceModel: String(repeating: "x", count: 300),
                .connectionState: "online",
            ],
            to: directory
        )
        let report = try JSONDecoder().decode(
            RemoteDiagnosticReport.self,
            from: Data(contentsOf: url)
        )

        XCTAssertEqual(report.additionalDetails?["connectionState"], "online")
        XCTAssertEqual(report.additionalDetails?["deviceModel"]?.utf8.count, 160)
        XCTAssertNil(report.additionalDetails?["deviceName"])
        XCTAssertNil(report.additionalDetails?["message"])
    }
}

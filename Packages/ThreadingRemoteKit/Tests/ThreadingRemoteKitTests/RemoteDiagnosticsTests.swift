import XCTest
@testable import ThreadingRemoteKit

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

    func testExplicitUploadImportsClientRecordsWithTheirSourceAndTimestamp() {
        let journal = RemoteDiagnosticJournal(directory: directory, source: .macOSHost)
        let host = journal.record(.appLaunched)
        let timestamp = ISO8601DateFormatter().string(
            from: Date().addingTimeInterval(-60)
        )
        let record = RemoteDiagnosticRecord(
            timestamp: timestamp,
            source: .iOSClient,
            level: .warning,
            event: .socketFailed,
            fields: ["code": "url.-1009"]
        )

        XCTAssertTrue(journal.importRecords([record], from: .iOSClient))
        XCTAssertEqual(journal.records().first, record)
        XCTAssertEqual(journal.records().last, host)
    }

    func testUploadPolicyRejectsRawFieldsWrongSourcesAndUnboundedBatches() {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        func record(
            source: RemoteDiagnosticSource = .iOSClient,
            fields: [String: String] = ["code": "url.-1009"]
        ) -> RemoteDiagnosticRecord {
            RemoteDiagnosticRecord(
                timestamp: timestamp,
                source: source,
                level: .error,
                event: .socketFailed,
                fields: fields
            )
        }

        XCTAssertTrue(RemoteDiagnosticUploadPolicy.accepts(
            RemoteDiagnosticUploadRequestDTO(
                source: .browserClient,
                records: [
                    RemoteDiagnosticRecord(
                        timestamp: timestamp,
                        source: .browserClient,
                        level: .info,
                        event: .socketConnecting,
                        fields: [
                            "transport": "websocket",
                            "protocolVersion": "7",
                        ]
                    )
                ]
            )
        ))
        XCTAssertFalse(RemoteDiagnosticUploadPolicy.accepts(
            RemoteDiagnosticUploadRequestDTO(
                source: .iOSClient,
                records: [record(fields: ["message": "a prompt must not become a log"])]
            )
        ))
        XCTAssertFalse(RemoteDiagnosticUploadPolicy.accepts(
            RemoteDiagnosticUploadRequestDTO(
                source: .iOSClient,
                records: [record(fields: ["reason": "/Users/person/private-project"])]
            )
        ))
        XCTAssertFalse(RemoteDiagnosticUploadPolicy.accepts(
            RemoteDiagnosticUploadRequestDTO(
                source: .iOSClient,
                records: [record(fields: ["code": "terminal contents"])]
            )
        ))
        XCTAssertFalse(RemoteDiagnosticUploadPolicy.accepts(
            RemoteDiagnosticUploadRequestDTO(
                source: .iOSClient,
                records: [record(source: .browserClient)]
            )
        ))
        XCTAssertFalse(RemoteDiagnosticUploadPolicy.accepts(
            RemoteDiagnosticUploadRequestDTO(
                source: .macOSHost,
                records: [record(source: .macOSHost)]
            )
        ))
        XCTAssertFalse(RemoteDiagnosticUploadPolicy.accepts(
            RemoteDiagnosticUploadRequestDTO(
                source: .iOSClient,
                records: Array(
                    repeating: record(),
                    count: RemoteDiagnosticUploadPolicy.maximumRecordsPerUpload + 1
                )
            )
        ))
        XCTAssertFalse(RemoteDiagnosticUploadPolicy.accepts(
            RemoteDiagnosticUploadRequestDTO(
                source: .iOSClient,
                records: [
                    RemoteDiagnosticRecord(
                        timestamp: timestamp,
                        source: .iOSClient,
                        level: .info,
                        event: .diagnosticUploadReceived,
                        fields: [:]
                    )
                ]
            )
        ))
    }
}

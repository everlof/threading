import XCTest
@testable import ThreadingRemoteKit

final class RemoteDiagnosticsTests: XCTestCase {
    private final class StorageEvents: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [RemoteDiagnosticJournalStorageEvent] = []

        func append(_ event: RemoteDiagnosticJournalStorageEvent) {
            lock.lock()
            events.append(event)
            lock.unlock()
        }

        var snapshot: [RemoteDiagnosticJournalStorageEvent] {
            lock.lock()
            defer { lock.unlock() }
            return events
        }
    }

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

    /// The `origin` field exists so a report can say which address a client aimed at. It is a
    /// hash by contract, and the contract is enforced here rather than trusted: an address in
    /// this field would put a routable location of someone's machine into a shareable file.
    func testOriginFieldAcceptsOnlyAHashAndNeverAnAddress() {
        XCTAssertTrue(RemoteDiagnosticUploadPolicy.accepts(uploadRequest(fields: [
            .origin: "origin-a1b2c3d4e5f6",
            .transport: "relay",
        ])))
        XCTAssertFalse(RemoteDiagnosticUploadPolicy.accepts(uploadRequest(fields: [
            .origin: "192.168.1.42:8760",
        ])))
        XCTAssertFalse(RemoteDiagnosticUploadPolicy.accepts(uploadRequest(fields: [
            .origin: "mac.ts.net",
        ])))
        XCTAssertFalse(RemoteDiagnosticUploadPolicy.accepts(uploadRequest(fields: [
            .origin: "origin-192.168.1.42:8760",
        ])))
    }

    /// `detail` carries the values behind a refusal, and stays inside the same machine alphabet
    /// every other field is held to.
    func testDetailFieldStaysAMachineToken() {
        XCTAssertTrue(RemoteDiagnosticUploadPolicy.accepts(uploadRequest(fields: [
            .code: "invalidViewport",
            .reason: RemoteViewportRefusal.columnsOutOfRange.rawValue,
            .detail: "300x40",
        ])))
        XCTAssertFalse(RemoteDiagnosticUploadPolicy.accepts(uploadRequest(fields: [
            .detail: "the agent said hello",
        ])))
    }

    func testConnectivityLifecycleAcceptsOnlyNumericMeasurements() {
        XCTAssertTrue(RemoteDiagnosticUploadPolicy.accepts(uploadRequest(
            event: .hostRouteEnded,
            fields: [
                .trace: "trace-123",
                .transport: "hosted",
                .phase: "hosted.awaitingHost",
                .result: "failed",
                .durationMS: "15017",
                .timeoutMS: "15000",
                .networkStage: "tls",
                .dnsMS: "18",
                .tcpMS: "41",
                .tlsMS: "14958",
                .serverWaitMS: "0",
                .responseMS: "0",
                .networkProtocol: "h2",
                .networkPath: "cellular.expensive",
                .connectionReused: "false",
                .attempt: "1",
                .total: "2",
            ]
        )))
        XCTAssertFalse(RemoteDiagnosticUploadPolicy.accepts(uploadRequest(
            event: .hostRouteEnded,
            fields: [.durationMS: "fifteen-seconds"]
        )))
        XCTAssertFalse(RemoteDiagnosticUploadPolicy.accepts(uploadRequest(
            event: .hostRouteEnded,
            fields: [.tcpMS: "forty-one"]
        )))
    }

    func testIOSDiscoveryEvidenceCanBeSharedWithThePairedHost() {
        XCTAssertTrue(RemoteDiagnosticUploadPolicy.accepts(uploadRequest(
            event: .hostDiscoveryMatched,
            fields: [
                .peer: "peer-a1b2c3d4e5f6",
                .transport: "lan",
                .phase: "resolve",
                .result: "matched",
                .origin: "origin-a1b2c3d4e5f6",
            ]
        )))
    }

    func testIOSReportDeliveryEvidenceCanBeSharedWithThePairedHost() {
        XCTAssertTrue(RemoteDiagnosticUploadPolicy.accepts(uploadRequest(
            event: .issueReportSubmissionDeferred,
            fields: [
                .trace: UUID().uuidString.lowercased(),
                .transport: "https",
                .phase: "report.delivery",
                .result: "queued",
                .code: "url.-1001",
                .durationMS: "30004",
                .timeoutMS: "30000",
            ]
        )))
    }

    func testAttachmentPreviewFailuresCanOnlyBeUploadedByIOS() {
        let fields: [RemoteDiagnosticField: String] = [
            .kind: "image",
            .code: "url.-1009",
        ]
        XCTAssertTrue(RemoteDiagnosticUploadPolicy.accepts(uploadRequest(
            event: .attachmentPreviewFailed,
            fields: fields
        )))

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let browserRequest = RemoteDiagnosticUploadRequestDTO(
            source: .browserClient,
            records: [RemoteDiagnosticRecord(
                timestamp: formatter.string(from: Date()),
                source: .browserClient,
                level: .warning,
                event: .attachmentPreviewFailed,
                fields: Dictionary(uniqueKeysWithValues: fields.map {
                    ($0.key.rawValue, $0.value)
                })
            )]
        )
        XCTAssertFalse(RemoteDiagnosticUploadPolicy.accepts(browserRequest))
    }

    private func uploadRequest(
        event: RemoteDiagnosticEvent = .socketFailed,
        fields: [RemoteDiagnosticField: String]
    ) -> RemoteDiagnosticUploadRequestDTO {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return RemoteDiagnosticUploadRequestDTO(
            source: .iOSClient,
            records: [RemoteDiagnosticRecord(
                timestamp: formatter.string(from: Date()),
                source: .iOSClient,
                level: .error,
                event: event,
                fields: Dictionary(uniqueKeysWithValues: fields.map { ($0.key.rawValue, $0.value) })
            )]
        )
    }

    func testJournalRoundTripsTypedRecordsInOrder() {
        let journal = RemoteDiagnosticJournal(directory: directory, source: .iOSClient)
        journal.record(.socketConnecting, fields: [.session: "session-a"])
        journal.record(.socketConnected, fields: [.transport: "websocket"])

        XCTAssertEqual(journal.records().map(\.event), [.socketConnecting, .socketConnected])
        XCTAssertEqual(journal.records().last?.fields["transport"], "websocket")
    }

    func testJournalReportsContentFreeStorageFailureAndRecovery() throws {
        let blocked = directory.appendingPathComponent("blocked")
        try Data("not-a-directory".utf8).write(to: blocked)
        let events = StorageEvents()
        let journal = RemoteDiagnosticJournal(
            directory: blocked,
            source: .iOSClient,
            storageEventHandler: { event in events.append(event) }
        )

        journal.record(.socketConnecting)
        XCTAssertTrue(events.snapshot.contains {
            $0.outcome == .failed && $0.stage == .directory
        })

        try FileManager.default.removeItem(at: blocked)
        try FileManager.default.createDirectory(
            at: blocked,
            withIntermediateDirectories: true
        )
        journal.record(.socketConnected)

        XCTAssertTrue(events.snapshot.contains {
            $0.outcome == .recovered && $0.stage == .directory
        })
        XCTAssertEqual(journal.records().map(\.event), [.socketConnected])
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

    func testOversizedJournalReadsOnlyItsBoundedValidTail() throws {
        let file = directory.appendingPathComponent("remote-diagnostics-2026-08-10.jsonl")
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: Data()))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(
            atOffset: UInt64(RemoteDiagnosticJournal.maximumJournalReadBytes + 1_024)
        )
        try handle.seekToEnd()
        let expected = RemoteDiagnosticRecord(
            timestamp: "2026-08-10T00:00:00Z",
            source: .iOSClient,
            level: .warning,
            event: .socketFailed,
            fields: ["code": "url.-1009"]
        )
        try handle.write(contentsOf: Data([0x0A]))
        try handle.write(contentsOf: JSONEncoder().encode(expected))
        try handle.write(contentsOf: Data([0x0A]))
        try handle.close()

        let journal = RemoteDiagnosticJournal(directory: directory, source: .iOSClient)
        XCTAssertEqual(journal.records(), [expected])
    }

    func testDirectoryEnumerationRefusesBeforeAllocatingPastItsEntryBudget() throws {
        for index in 0..<4 {
            let url = directory.appendingPathComponent("entry-\(index)")
            XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data()))
        }

        XCTAssertThrowsError(
            try RemoteBoundedDirectoryReader.shallowContents(
                of: directory,
                maximumEntries: 3
            )
        ) { error in
            XCTAssertEqual(
                error as? RemoteDirectoryEnumerationError,
                .entryLimitExceeded(maximumEntries: 3)
            )
        }
    }

    func testJournalRejectsSymlinksAndFailsClosedWhenDirectoryBudgetIsExceeded() throws {
        let external = directory.deletingLastPathComponent()
            .appendingPathComponent("external-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: external) }
        let record = RemoteDiagnosticRecord(
            timestamp: "2026-08-10T00:00:00Z",
            source: .iOSClient,
            level: .warning,
            event: .socketFailed,
            fields: [:]
        )
        try (JSONEncoder().encode(record) + Data([0x0A])).write(to: external)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("remote-diagnostics-2026-08-10.jsonl"),
            withDestinationURL: external
        )

        let journal = RemoteDiagnosticJournal(directory: directory, source: .iOSClient)
        XCTAssertTrue(journal.records().isEmpty)

        for index in 0...RemoteDiagnosticJournal.maximumJournalDirectoryEntries {
            let url = directory.appendingPathComponent("unrecognized-\(index)")
            XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data()))
        }
        XCTAssertTrue(journal.records().isEmpty)
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
        XCTAssertEqual(try RemoteDiagnosticJournal.readSupportReport(at: url), report)
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

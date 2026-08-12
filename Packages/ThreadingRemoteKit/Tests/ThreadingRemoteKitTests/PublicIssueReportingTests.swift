import XCTest
@testable import ThreadingRemoteKit

final class PublicIssueReportingTests: XCTestCase {
    func testSubmissionAcceptsBoundedTypedReport() throws {
        let submission = makeSubmission()

        XCTAssertTrue(PublicIssueReportPolicy.accepts(submission))
        XCTAssertLessThanOrEqual(
            try JSONEncoder().encode(submission).count,
            PublicIssueReportPolicy.maximumRequestBytes
        )
    }

    func testSubmissionRejectsEmptyDescriptionAndUnpairedScreenshotFields() {
        XCTAssertFalse(PublicIssueReportPolicy.accepts(makeSubmission(description: "  \n")))

        let report = makeReport(recordCount: 1)
        let submission = PublicIssueReportSubmissionDTO(
            id: UUID().uuidString.lowercased(),
            createdAt: ISO8601DateFormatter().string(from: Date()),
            trigger: "shake",
            description: "The composer stopped responding.",
            diagnostics: PublicIssueReportDiagnosticsDTO(bounding: report),
            screenshotPreviewBase64: Data([0xff, 0xd8, 0xff]).base64EncodedString()
        )
        XCTAssertFalse(PublicIssueReportPolicy.accepts(submission))

        let fakeJPEG = PublicIssueReportSubmissionDTO(
            id: UUID().uuidString.lowercased(),
            createdAt: ISO8601DateFormatter().string(from: Date()),
            trigger: "shake",
            description: "The composer stopped responding.",
            diagnostics: PublicIssueReportDiagnosticsDTO(bounding: report),
            screenshotPreviewBase64: Data("not a jpeg".utf8).base64EncodedString(),
            screenshotMediaType: "image/jpeg"
        )
        XCTAssertFalse(PublicIssueReportPolicy.accepts(fakeJPEG))
    }

    func testSubmissionAcceptsMacManualAndCrashTriggers() {
        for trigger in ["manual", "postCrash"] {
            XCTAssertTrue(PublicIssueReportPolicy.accepts(makeSubmission(
                trigger: trigger,
                source: .macOSHost
            )))
        }
    }

    func testBoundingDropsContentInMachineFieldsAndPolicyRejectsACraftedBypass() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "public-report-\(UUID().uuidString)",
            isDirectory: true
        )
        let journal = RemoteDiagnosticJournal(directory: directory, source: .iOSClient)
        journal.record(.socketFailed, fields: [.reason: "a private path /Users/person/project"])
        let url = try! journal.writeSupportReport(
            appVersion: "1.0",
            appBuild: "1",
            operatingSystem: "iOS 19",
            protocolVersion: RemoteProtocol.current,
            minimumProtocolVersion: RemoteProtocol.minimumSupported,
            to: directory
        )
        let report = try! RemoteDiagnosticJournal.readSupportReport(at: url)
        let submission = PublicIssueReportSubmissionDTO(
            id: UUID().uuidString.lowercased(),
            createdAt: ISO8601DateFormatter().string(from: Date()),
            trigger: "diagnostics",
            description: "The connection failed.",
            diagnostics: PublicIssueReportDiagnosticsDTO(bounding: report)
        )

        XCTAssertTrue(submission.diagnostics.records.isEmpty)
        XCTAssertTrue(PublicIssueReportPolicy.accepts(submission))

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(submission))
                as? [String: Any]
        )
        var diagnostics = try XCTUnwrap(object["diagnostics"] as? [String: Any])
        diagnostics["records"] = [[
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "source": "iOSClient",
            "level": "error",
            "event": "socketFailed",
            "fields": ["reason": "a private path /Users/person/project"],
        ]]
        object["diagnostics"] = diagnostics
        let crafted = try JSONDecoder().decode(
            PublicIssueReportSubmissionDTO.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertFalse(PublicIssueReportPolicy.accepts(crafted))
    }

    func testMacReportAcceptsAJoinedTimelineFromValidatedClients() {
        let now = ISO8601DateFormatter().string(from: Date())
        let sources: [RemoteDiagnosticSource] = [.macOSHost, .iOSClient, .browserClient]
        let report = RemoteDiagnosticReport(
            schemaVersion: RemoteDiagnosticReport.currentSchemaVersion,
            generatedAt: now,
            source: .macOSHost,
            appVersion: "1.0",
            appBuild: "1",
            operatingSystem: "macOS_26.5",
            protocolVersion: RemoteProtocol.current,
            minimumProtocolVersion: RemoteProtocol.minimumSupported,
            additionalDetails: nil,
            records: sources.map { source in
                RemoteDiagnosticRecord(
                    timestamp: now,
                    source: source,
                    level: .info,
                    event: .socketConnected,
                    fields: ["transport": "webrtc"]
                )
            }
        )
        let submission = PublicIssueReportSubmissionDTO(
            id: UUID().uuidString.lowercased(),
            createdAt: now,
            trigger: "manual",
            description: "A paired client disconnected.",
            diagnostics: PublicIssueReportDiagnosticsDTO(bounding: report)
        )

        XCTAssertEqual(submission.diagnostics.records.map(\.source), sources)
        XCTAssertTrue(PublicIssueReportPolicy.accepts(submission))
    }

    func testDurableSubmissionReadUsesTheRequestByteBoundary() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("public-report-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("report.json")
        let submission = makeSubmission(description: "A bounded report")
        try JSONEncoder().encode(submission).write(to: url)
        XCTAssertEqual(PublicIssueReportPolicy.submission(at: url), submission)

        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(
            atOffset: UInt64(PublicIssueReportPolicy.maximumRequestBytes + 1)
        )
        try handle.close()
        XCTAssertNil(PublicIssueReportPolicy.submission(at: url))
    }

    func testDiagnosticsKeepNewestRecordsWithinBodyBudget() throws {
        let source = makeReport(recordCount: 800)
        let bounded = PublicIssueReportDiagnosticsDTO(bounding: source)

        XCTAssertLessThan(bounded.records.count, source.records.count)
        XCTAssertEqual(bounded.records.last?.fields["trace"], "record-799")
        XCTAssertLessThanOrEqual(
            try JSONEncoder().encode(bounded).count,
            PublicIssueReportPolicy.maximumDiagnosticsBytes
        )
    }

    private func makeSubmission(
        description: String = "The composer stopped responding.",
        trigger: String = "diagnostics",
        source: RemoteDiagnosticSource = .iOSClient
    ) -> PublicIssueReportSubmissionDTO {
        PublicIssueReportSubmissionDTO(
            id: UUID().uuidString.lowercased(),
            createdAt: ISO8601DateFormatter().string(from: Date()),
            trigger: trigger,
            description: description,
            diagnostics: PublicIssueReportDiagnosticsDTO(bounding: makeReport(
                recordCount: 4,
                source: source
            )),
            screenshotPreviewBase64: Data([0xff, 0xd8, 0xff]).base64EncodedString(),
            screenshotMediaType: "image/jpeg"
        )
    }

    private func makeReport(
        recordCount: Int,
        source: RemoteDiagnosticSource = .iOSClient
    ) -> RemoteDiagnosticReport {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "public-report-\(UUID().uuidString)",
            isDirectory: true
        )
        let journal = RemoteDiagnosticJournal(directory: directory, source: source)
        for index in 0..<recordCount {
            journal.record(.socketConnected, fields: [
                .trace: "record-\(index)",
                .transport: String(repeating: "w", count: 120),
            ])
        }
        let url = try! journal.writeSupportReport(
            appVersion: "1.0",
            appBuild: "1",
            operatingSystem: "iOS 19",
            protocolVersion: RemoteProtocol.current,
            minimumProtocolVersion: RemoteProtocol.minimumSupported,
            to: directory
        )
        return try! JSONDecoder().decode(
            RemoteDiagnosticReport.self,
            from: Data(contentsOf: url)
        )
    }
}

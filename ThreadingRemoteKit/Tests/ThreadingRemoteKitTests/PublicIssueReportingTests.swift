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
        description: String = "The composer stopped responding."
    ) -> PublicIssueReportSubmissionDTO {
        PublicIssueReportSubmissionDTO(
            id: UUID().uuidString.lowercased(),
            createdAt: ISO8601DateFormatter().string(from: Date()),
            trigger: "diagnostics",
            description: description,
            diagnostics: PublicIssueReportDiagnosticsDTO(bounding: makeReport(recordCount: 4)),
            screenshotPreviewBase64: Data([0xff, 0xd8, 0xff]).base64EncodedString(),
            screenshotMediaType: "image/jpeg"
        )
    }

    private func makeReport(recordCount: Int) -> RemoteDiagnosticReport {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "public-report-\(UUID().uuidString)",
            isDirectory: true
        )
        let journal = RemoteDiagnosticJournal(directory: directory, source: .iOSClient)
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

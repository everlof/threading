import Foundation
import XCTest
@testable import ThreadingRemoteKit

final class ReportDeploymentContractTests: XCTestCase {
    /// Deployment probes are encoded by the shipping DTO, not a second JavaScript wire model.
    func testShippingReportContract() throws {
        let now = ISO8601DateFormatter().string(from: Date())
        let fields = Dictionary(uniqueKeysWithValues: RemoteDiagnosticField.allCases.map { field in
            let value: String
            switch field.validation {
            case .originDigest: value = "origin-0123456789ab"
            case .peerPseudonym: value = "peer-0123456789ab"
            case .sessionPseudonym: value = "session-0123456789ab"
            case .unsignedInteger: value = "1"
            case .token: value = "probe"
            }
            return (field.rawValue, value)
        })
        let image = Data([0xff, 0xd8, 0xff] + Array(
            repeating: UInt8(0), count: PublicIssueReportPolicy.maximumScreenshotPreviewBytes - 3
        )).base64EncodedString()
        let description = String(repeating: "x", count: PublicIssueReportPolicy.maximumDescriptionBytes)
        let sources: [RemoteDiagnosticSource] = [.macOSHost, .iOSClient, .browserClient]
        let submissions = sources.map { source in
            let reportSource: RemoteDiagnosticSource = source == .iOSClient ? .iOSClient : .macOSHost
            let events = RemoteDiagnosticEvent.allCases.filter {
                source == .macOSHost || $0.allowsClientUpload(from: source)
            }
            let details = Dictionary(uniqueKeysWithValues: RemoteDiagnosticExtraField.allCases
                .filter { $0.allowsReportSource(reportSource) }.map { ($0.rawValue, "probe") })
            let report = RemoteDiagnosticReport(
                schemaVersion: RemoteDiagnosticReport.currentSchemaVersion,
                generatedAt: now, source: reportSource, appVersion: "0.2.0", appBuild: "0.2.0",
                operatingSystem: "contract-probe", protocolVersion: RemoteProtocol.current,
                minimumProtocolVersion: RemoteProtocol.minimumSupported, additionalDetails: details,
                records: events.enumerated().map { index, event in
                    RemoteDiagnosticRecord(timestamp: now, source: source, level: .info,
                                           event: event, fields: index == 0 ? fields : [:])
                }
            )
            let submission = PublicIssueReportSubmissionDTO(
                id: UUID().uuidString.lowercased(), createdAt: now, trigger: .manual,
                description: description,
                diagnostics: PublicIssueReportDiagnosticsDTO(bounding: report),
                screenshotPreviewBase64: image, screenshotMediaType: "image/jpeg",
                imagePreviews: Array(repeating: PublicIssueReportImagePreviewDTO(jpegBase64: image), count: 3)
            )
            XCTAssertEqual(submission.diagnostics.records.count, events.count, "Probe must cover every event")
            XCTAssertEqual(submission.diagnostics.records.first?.fields, fields)
            XCTAssertTrue(PublicIssueReportPolicy.accepts(submission))
            return submission
        }
        if let path = ProcessInfo.processInfo.environment["THREADING_REPORT_CONTRACT_FIXTURE_PATH"] {
            try JSONEncoder().encode(submissions).write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
}

import XCTest
import ThreadingRemoteKit
@testable import ThreadingMobile

final class MobileDeveloperReportHandoffTests: XCTestCase {
    func testAtomicHandoffKeepsBase64OutOfThePrompt() throws {
        let jpeg = Data([0xff, 0xd8, 0xff, 0x10, 0x20, 0x30])
        let submission = makeSubmission(screenshot: jpeg)

        let launch = try MobileDeveloperReportHandoff.prepare(
            submission,
            supportsAtomicReportOpening: true
        )

        XCTAssertEqual(launch.legacyPrompt, "")
        let opening = try XCTUnwrap(launch.reportOpening)
        XCTAssertEqual(
            opening.screenshot.flatMap { RemoteReportScreenshotPolicy.jpegData(from: $0) },
            jpeg
        )
        XCTAssertTrue(opening.prompt.contains("attached as a normal image file"))
        XCTAssertTrue(opening.prompt.contains(submission.description))
        XCTAssertFalse(opening.prompt.contains(jpeg.base64EncodedString()))
        XCTAssertFalse(opening.prompt.contains("screenshotPreviewBase64"))
    }

    func testScreenshotRefusesLegacyMacInsteadOfFallingBackToPromptBytes() throws {
        let submission = makeSubmission(screenshot: Data([0xff, 0xd8, 0xff]))

        XCTAssertThrowsError(try MobileDeveloperReportHandoff.prepare(
            submission,
            supportsAtomicReportOpening: false
        )) { error in
            guard case RemoteClientError.upgradeRequired(.host) = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testTextOnlyReportStillUsesTheLegacyPromptOnAnOlderMac() throws {
        let submission = makeSubmission(screenshot: nil)

        let launch = try MobileDeveloperReportHandoff.prepare(
            submission,
            supportsAtomicReportOpening: false
        )

        XCTAssertNil(launch.reportOpening)
        XCTAssertTrue(launch.legacyPrompt.contains(submission.description))
        XCTAssertTrue(launch.legacyPrompt.contains("No screenshot is attached."))
    }

    private func makeSubmission(screenshot: Data?) -> PublicIssueReportSubmissionDTO {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mobile-report-handoff-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = RemoteDiagnosticJournal(directory: directory, source: .iOSClient)
        journal.record(.socketConnected, fields: [.transport: "lan"])
        let reportURL = try! journal.writeSupportReport(
            appVersion: "1.0",
            appBuild: "1",
            operatingSystem: "iOS",
            protocolVersion: RemoteProtocol.current,
            minimumProtocolVersion: RemoteProtocol.minimumSupported,
            to: directory
        )
        let report = try! JSONDecoder().decode(
            RemoteDiagnosticReport.self,
            from: Data(contentsOf: reportURL)
        )
        return PublicIssueReportSubmissionDTO(
            id: UUID().uuidString.lowercased(),
            createdAt: ISO8601DateFormatter().string(from: Date()),
            trigger: .shake,
            description: "The report receipt covered the wrong screen.",
            diagnostics: PublicIssueReportDiagnosticsDTO(bounding: report),
            screenshotPreviewBase64: screenshot?.base64EncodedString(),
            screenshotMediaType: screenshot == nil ? nil : "image/jpeg"
        )
    }
}

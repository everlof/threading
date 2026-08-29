import XCTest
@testable import ThreadingRemoteKit

final class RemoteReportSessionOpeningTests: XCTestCase {
    func testReportOpeningRoundTripsSeparatelyFromLegacyPrompt() throws {
        let jpeg = Data([0xff, 0xd8, 0xff, 0x01, 0x02])
        let request = RemoteCreateSessionRequestDTO(
            projectID: UUID().uuidString,
            agentKind: "codex",
            surface: .conversation,
            reportOpening: RemoteReportSessionOpeningDTO(
                prompt: "Investigate this report",
                screenshot: RemoteReportScreenshotDTO(
                    jpegBase64: jpeg.base64EncodedString()
                )
            ),
            prompt: ""
        )

        let decoded = try JSONDecoder().decode(
            RemoteCreateSessionRequestDTO.self,
            from: JSONEncoder().encode(request)
        )

        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.prompt, "")
        XCTAssertEqual(decoded.reportOpening?.prompt, "Investigate this report")
        XCTAssertEqual(
            decoded.reportOpening?.screenshot.flatMap(
                RemoteReportScreenshotPolicy.jpegData(from:)
            ),
            jpeg
        )
    }

    func testReportScreenshotPolicyRejectsMalformedAndOversizedBytes() {
        XCTAssertNil(RemoteReportScreenshotPolicy.jpegData(from: .init(
            jpegBase64: "not base64"
        )))
        XCTAssertNil(RemoteReportScreenshotPolicy.jpegData(from: .init(
            jpegBase64: Data("not jpeg".utf8).base64EncodedString()
        )))

        var oversized = Data([0xff, 0xd8, 0xff])
        oversized.append(Data(
            repeating: 0,
            count: PublicIssueReportPolicy.maximumScreenshotPreviewBytes
        ))
        XCTAssertNil(RemoteReportScreenshotPolicy.jpegData(from: .init(
            jpegBase64: oversized.base64EncodedString()
        )))
    }

    func testLegacyCreateRequestStillDecodesWithoutReportOpening() throws {
        let data = Data(
            #"{"projectID":"project","agentKind":"codex","surface":"terminal","prompt":"hello"}"#.utf8
        )

        let decoded = try JSONDecoder().decode(RemoteCreateSessionRequestDTO.self, from: data)

        XCTAssertNil(decoded.reportOpening)
        XCTAssertEqual(decoded.prompt, "hello")
    }
}

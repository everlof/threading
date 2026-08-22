#if DEBUG
import Foundation
import ThreadingRemoteKit
import XCTest
@testable import Threading

final class MobileDebugCaptureStoreTests: XCTestCase {
    func testCapturePolicyAcceptsBoundedLANEvidence() {
        let now = Date()
        XCTAssertTrue(MobileDebugCaptureStore.accepts(capture(now: now), now: now))
    }

    func testCapturePolicyRejectsNonLANAndContentBearingDiagnostics() {
        let now = Date()
        XCTAssertFalse(MobileDebugCaptureStore.accepts(
            capture(now: now, endpointKind: RemoteHostEndpointKind.tailscale),
            now: now
        ))
        XCTAssertFalse(MobileDebugCaptureStore.accepts(
            capture(now: now, fields: ["message": "terminal contents"]),
            now: now
        ))
    }

    func testCapturePolicyRejectsInvalidOrOversizedScreenshots() {
        let now = Date()
        XCTAssertFalse(MobileDebugCaptureStore.accepts(
            capture(now: now, screenshot: Data("not a jpeg".utf8), screenshotKind: "incident"),
            now: now
        ))

        var oversized = Data([0xFF, 0xD8])
        oversized.append(Data(repeating: 0, count: MobileDebugCaptureStore.maximumScreenshotBytes))
        oversized.append(contentsOf: [0xFF, 0xD9])
        XCTAssertFalse(MobileDebugCaptureStore.accepts(
            capture(now: now, screenshot: oversized, screenshotKind: "incident"),
            now: now
        ))
    }

    func testStoreRejectsCaptureWithoutMatchingLiveRequest() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MobileDebugCaptureStore(directory: directory)

        XCTAssertThrowsError(try store.accept(
            capture(now: Date()),
            from: UUID().uuidString,
            deviceName: "Test iPhone"
        )) { error in
            XCTAssertEqual(error as? MobileDebugCaptureStore.StoreError, .unsolicited)
        }
        XCTAssertNil(store.latestCapture())
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    private func capture(
        now: Date,
        endpointKind: String = RemoteHostEndpointKind.lan,
        fields: [String: String] = ["transport": "websocket"],
        screenshot: Data? = nil,
        screenshotKind: String? = nil
    ) -> RemoteMobileDebugCaptureDTO {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: now)
        return RemoteMobileDebugCaptureDTO(
            captureID: UUID().uuidString.lowercased(),
            requestID: UUID().uuidString.lowercased(),
            capturedAt: timestamp,
            appVersion: "1.0",
            appBuild: "1",
            operatingSystem: "iOS Test",
            deviceModel: "iPhone-test",
            applicationState: "active",
            connectionState: "online",
            activeEndpointKind: endpointKind,
            pairedHostCount: 1,
            visibleSessionCount: 2,
            diagnostics: [
                RemoteDiagnosticRecord(
                    timestamp: timestamp,
                    source: .iOSClient,
                    level: .info,
                    event: .socketConnected,
                    fields: fields
                )
            ],
            screenshotJPEGBase64: screenshot?.base64EncodedString(),
            screenshotKind: screenshotKind
        )
    }
}
#endif

import Foundation
import Network
import ThreadingRemoteKit
import XCTest
@testable import Threading

/// The opt-in, nonce, evidence, persistence, and live-toggle contract of the shipping store.
final class MobileDiagnosticsCaptureStoreTests: XCTestCase {
    func testCapturePolicyAcceptsBoundedLANEvidence() {
        let now = Date()
        XCTAssertTrue(MobileDiagnosticsCaptureStore.accepts(capture(now: now), now: now))
    }

    func testCapturePolicyRejectsNonLANAndContentBearingDiagnostics() {
        let now = Date()
        XCTAssertFalse(MobileDiagnosticsCaptureStore.accepts(
            capture(now: now, endpointKind: RemoteHostEndpointKind.tailscale),
            now: now
        ))
        XCTAssertFalse(MobileDiagnosticsCaptureStore.accepts(
            capture(now: now, fields: ["message": "terminal contents"]),
            now: now
        ))
    }

    func testCapturePolicyRejectsInvalidOrOversizedScreenshots() {
        let now = Date()
        XCTAssertFalse(MobileDiagnosticsCaptureStore.accepts(
            capture(now: now, screenshot: Data("not a jpeg".utf8), screenshotKind: "incident"),
            now: now
        ))

        var oversized = Data([0xFF, 0xD8])
        oversized.append(Data(
            repeating: 0,
            count: MobileDiagnosticsCaptureStore.maximumScreenshotBytes
        ))
        oversized.append(contentsOf: [0xFF, 0xD9])
        XCTAssertFalse(MobileDiagnosticsCaptureStore.accepts(
            capture(now: now, screenshot: oversized, screenshotKind: "incident"),
            now: now
        ))
    }

    func testStoreRejectsCaptureWithoutMatchingLiveRequest() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MobileDiagnosticsCaptureStore(
            directory: directory,
            isEnabled: true,
            observesSettings: false
        )

        XCTAssertThrowsError(try store.accept(
            capture(now: Date()),
            from: UUID().uuidString,
            deviceName: "Test iPhone"
        )) { error in
            XCTAssertEqual(error as? MobileDiagnosticsCaptureStore.StoreError, .unsolicited)
        }
        XCTAssertNil(store.latestCapture())
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testTurningOffRevokesPendingRequestsAndTurningOnReusesTheLivePhone() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MobileDiagnosticsCaptureStore(
            directory: directory,
            isEnabled: true,
            observesSettings: false
        )
        let queue = DispatchQueue(label: "mobile-diagnostics-toggle-test")
        let connection = RemoteConnection(
            connection: NWConnection(host: "127.0.0.1", port: 9, using: .tcp),
            queue: queue,
            delegate: MobileDiagnosticsConnectionDelegate()
        )
        let deviceID = UUID().uuidString.lowercased()
        store.register(connection, deviceID: deviceID, deviceName: "Test iPhone")

        let firstRequestID = try XCTUnwrap(store.requestCapture(
            deviceID: deviceID,
            screenshotPolicy: .none,
            automatic: false
        ))
        store.setEnabled(false)
        XCTAssertFalse(store.isEnabled)
        XCTAssertThrowsError(try store.accept(
            capture(now: Date(), requestID: firstRequestID),
            from: deviceID,
            deviceName: "Test iPhone"
        )) { error in
            XCTAssertEqual(error as? MobileDiagnosticsCaptureStore.StoreError, .disabled)
        }

        store.setEnabled(true)
        XCTAssertTrue(store.isEnabled)
        XCTAssertNotNil(store.requestCapture(
            deviceID: deviceID,
            screenshotPolicy: .none,
            automatic: false
        ), "the advertised phone remains available after the Mac switch is turned back on")
    }

    func testTurningOffDuringPersistencePreventsPublicationAndDeletesTheFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let reference = MobileDiagnosticsStoreReference()
        let store = MobileDiagnosticsCaptureStore(
            directory: directory,
            isEnabled: true,
            observesSettings: false,
            beforePublishingCapture: { reference.value?.setEnabled(false) }
        )
        reference.value = store
        let connection = RemoteConnection(
            connection: NWConnection(host: "127.0.0.1", port: 9, using: .tcp),
            queue: DispatchQueue(label: "mobile-diagnostics-publication-test"),
            delegate: MobileDiagnosticsConnectionDelegate()
        )
        let deviceID = UUID().uuidString.lowercased()
        store.register(connection, deviceID: deviceID, deviceName: "Test iPhone")
        let requestID = try XCTUnwrap(store.requestCapture(
            deviceID: deviceID,
            screenshotPolicy: .none,
            automatic: false
        ))
        let evidence = capture(now: Date(), requestID: requestID)

        XCTAssertThrowsError(try store.accept(
            evidence,
            from: deviceID,
            deviceName: "Test iPhone"
        )) { error in
            XCTAssertEqual(error as? MobileDiagnosticsCaptureStore.StoreError, .disabled)
        }
        XCTAssertNil(store.latestCapture())
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("\(evidence.captureID).json").path
        ))
    }

    private func capture(
        now: Date,
        requestID: String = UUID().uuidString.lowercased(),
        endpointKind: String = RemoteHostEndpointKind.lan,
        fields: [String: String] = ["transport": "websocket"],
        screenshot: Data? = nil,
        screenshotKind: String? = nil
    ) -> RemoteMobileDiagnosticsCaptureDTO {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: now)
        return RemoteMobileDiagnosticsCaptureDTO(
            captureID: UUID().uuidString.lowercased(),
            requestID: requestID,
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

private final class MobileDiagnosticsStoreReference: @unchecked Sendable {
    weak var value: MobileDiagnosticsCaptureStore?
}

private final class MobileDiagnosticsConnectionDelegate: RemoteConnection.Delegate,
    @unchecked Sendable {
    func route(
        _ request: HTTPRequest,
        from connection: RemoteConnection,
        respond: @escaping @Sendable (RemoteRouteDecision) -> Void
    ) {}

    func handleMessage(_ message: RemoteWebSocket.Message, from connection: RemoteConnection) {}
    func didClose(_ connection: RemoteConnection) {}
}

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
            capture(now: now, screenshot: Data("not a jpeg".utf8), screenshotKind: .incident),
            now: now
        ))

        var oversized = Data([0xFF, 0xD8])
        oversized.append(Data(
            repeating: 0,
            count: MobileDiagnosticsCaptureStore.maximumScreenshotBytes
        ))
        oversized.append(contentsOf: [0xFF, 0xD9])
        XCTAssertFalse(MobileDiagnosticsCaptureStore.accepts(
            capture(now: now, screenshot: oversized, screenshotKind: .incident),
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

    func testManualRequestWaitsForPublishedCaptureWithoutPolling() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MobileDiagnosticsCaptureStore(
            directory: directory,
            isEnabled: true,
            observesSettings: false
        )
        let (connection, deviceID) = registeredConnection(in: store, label: "capture-wait")
        _ = connection
        let requestID = try XCTUnwrap(store.requestCapture(
            deviceID: deviceID,
            screenshotPolicy: .none,
            automatic: false
        ))
        let evidence = capture(now: Date(), requestID: requestID)

        async let outcome = store.waitForCapture(
            requestID: requestID,
            timeout: .seconds(1)
        )
        let stored = try store.accept(evidence, from: deviceID, deviceName: "Test iPhone")

        let waitedOutcome = await outcome
        XCTAssertEqual(waitedOutcome, .captured(stored))
        XCTAssertThrowsError(try store.accept(
            evidence,
            from: deviceID,
            deviceName: "Test iPhone"
        )) { error in
            XCTAssertEqual(error as? MobileDiagnosticsCaptureStore.StoreError, .unsolicited)
        }
    }

    func testManualRequestTimeoutRevokesNonceBeforeLateCapture() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MobileDiagnosticsCaptureStore(
            directory: directory,
            isEnabled: true,
            observesSettings: false
        )
        let (connection, deviceID) = registeredConnection(in: store, label: "capture-timeout")
        _ = connection
        let requestID = try XCTUnwrap(store.requestCapture(
            deviceID: deviceID,
            screenshotPolicy: .none,
            automatic: false
        ))

        let outcome = await store.waitForCapture(
            requestID: requestID,
            timeout: .milliseconds(20)
        )

        XCTAssertEqual(outcome, .timedOut)
        XCTAssertThrowsError(try store.accept(
            capture(now: Date(), requestID: requestID),
            from: deviceID,
            deviceName: "Test iPhone"
        )) { error in
            XCTAssertEqual(error as? MobileDiagnosticsCaptureStore.StoreError, .unsolicited)
        }
    }

    func testCancellingManualWaitRevokesNonceBeforeLateCapture() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MobileDiagnosticsCaptureStore(
            directory: directory,
            isEnabled: true,
            observesSettings: false
        )
        let (connection, deviceID) = registeredConnection(in: store, label: "capture-cancel")
        _ = connection
        let requestID = try XCTUnwrap(store.requestCapture(
            deviceID: deviceID,
            screenshotPolicy: .none,
            automatic: false
        ))
        let waiter = Task {
            await store.waitForCapture(requestID: requestID, timeout: .seconds(1))
        }

        waiter.cancel()
        let outcome = await waiter.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertThrowsError(try store.accept(
            capture(now: Date(), requestID: requestID),
            from: deviceID,
            deviceName: "Test iPhone"
        )) { error in
            XCTAssertEqual(error as? MobileDiagnosticsCaptureStore.StoreError, .unsolicited)
        }
    }

    func testCrossDeviceAttemptDoesNotConsumeMatchingDeviceNonce() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MobileDiagnosticsCaptureStore(
            directory: directory,
            isEnabled: true,
            observesSettings: false
        )
        let (connection, deviceID) = registeredConnection(in: store, label: "capture-device")
        _ = connection
        let requestID = try XCTUnwrap(store.requestCapture(
            deviceID: deviceID,
            screenshotPolicy: .none,
            automatic: false
        ))
        let evidence = capture(now: Date(), requestID: requestID)

        XCTAssertThrowsError(try store.accept(
            evidence,
            from: UUID().uuidString.lowercased(),
            deviceName: "Other iPhone"
        )) { error in
            XCTAssertEqual(error as? MobileDiagnosticsCaptureStore.StoreError, .unsolicited)
        }
        XCTAssertNoThrow(try store.accept(
            evidence,
            from: deviceID,
            deviceName: "Test iPhone"
        ))
    }

    func testDisableAndDisconnectResolveManualRequestsAcrossRegistrationRace() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MobileDiagnosticsCaptureStore(
            directory: directory,
            isEnabled: true,
            observesSettings: false
        )
        let (connection, deviceID) = registeredConnection(in: store, label: "capture-terminal")
        let disabledRequestID = try XCTUnwrap(store.requestCapture(
            deviceID: deviceID,
            screenshotPolicy: .none,
            automatic: false
        ))

        store.setEnabled(false)
        let disabledOutcome = await store.waitForCapture(
            requestID: disabledRequestID,
            timeout: .seconds(1)
        )
        XCTAssertEqual(disabledOutcome, .disabled)

        store.setEnabled(true)
        let disconnectedRequestID = try XCTUnwrap(store.requestCapture(
            deviceID: deviceID,
            screenshotPolicy: .none,
            automatic: false
        ))
        store.unregister(connection)
        let disconnectedOutcome = await store.waitForCapture(
            requestID: disconnectedRequestID,
            timeout: .seconds(1)
        )
        XCTAssertEqual(disconnectedOutcome, .disconnected)
    }

    @MainActor
    func testInspectionCompletionSurvivesServiceDeinitExactlyOnce() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MobileDiagnosticsCaptureStore(
            directory: directory,
            isEnabled: true,
            observesSettings: false
        )
        let (connection, _) = registeredConnection(in: store, label: "inspection-cancel")
        _ = connection
        var service: MobileDiagnosticsInspectionService? = MobileDiagnosticsInspectionService(
            captures: store,
            waitTimeout: .seconds(1)
        )
        let completed = expectation(description: "inspection completion")
        var completionCount = 0
        service?.inspect(IOSDiagnosticsInspectionArguments()) { _ in
            completionCount += 1
            completed.fulfill()
        }

        service = nil
        await fulfillment(of: [completed], timeout: 1)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(completionCount, 1)
    }

    private func capture(
        now: Date,
        requestID: String = UUID().uuidString.lowercased(),
        endpointKind: RemoteHostEndpointKind = .lan,
        fields: [String: String] = ["transport": "websocket"],
        screenshot: Data? = nil,
        screenshotKind: RemoteMobileDiagnosticsScreenshotKind? = nil
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
            applicationState: .active,
            connectionState: .online,
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

    private func registeredConnection(
        in store: MobileDiagnosticsCaptureStore,
        label: String
    ) -> (RemoteConnection, String) {
        let connection = RemoteConnection(
            connection: NWConnection(host: "127.0.0.1", port: 9, using: .tcp),
            queue: DispatchQueue(label: "mobile-diagnostics-\(label)"),
            delegate: MobileDiagnosticsConnectionDelegate()
        )
        let deviceID = UUID().uuidString.lowercased()
        store.register(connection, deviceID: deviceID, deviceName: "Test iPhone")
        return (connection, deviceID)
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

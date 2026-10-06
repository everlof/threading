import AppKit
import XCTest
@testable import Threading

@MainActor
final class BrowserNetworkCaptureTests: XCTestCase {
    func testCaptureDefaultsToMetadataAndPersistsIndependentOptions() throws {
        let suite = "BrowserNetworkCapture-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = BrowserNetworkCaptureSettings(defaults: defaults)
        XCTAssertEqual(settings.options, .metadataOnly)
        settings.options = .init(requestHeaders: true, responseBody: true)
        let reopened = BrowserNetworkCaptureSettings(defaults: defaults)
        XCTAssertTrue(reopened.options.requestHeaders)
        XCTAssertTrue(reopened.options.responseBody)
        XCTAssertFalse(reopened.options.responseHeaders)
        XCTAssertFalse(reopened.options.requestBody)
    }

    func testConfigurationIsDiscoverableAndChangesRequireApproval() throws {
        let suite = "BrowserNetworkPermission-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = BrowserNetworkCaptureSettings(defaults: defaults)
        let coordinator = AgentToolCoordinator(
            displayPaneController: DisplayPaneController(),
            visibleSessionID: { nil }, setPaneVisible: { _ in }, windowProvider: { nil },
            browserNetworkCaptureSettings: settings
        )
        let sessionID = SessionID()
        let configuration = coordinator.handle(.browserNetwork(.init(
            kind: nil, errorsOnly: nil, clear: nil, configuration: true
        )), for: sessionID)
        XCTAssertFalse(configuration.isError)
        XCTAssertTrue(configuration.text.contains("response_body: false"))
        let proposal = MCPToolCall.browserNetwork(.init(
            kind: nil, errorsOnly: nil, clear: nil,
            requestCapture: .init(requestHeaders: true, responseHeaders: nil,
                                 requestBody: nil, responseBody: true)
        ))
        var decide: (@MainActor (Bool) -> Void)?
        coordinator.browserNetworkCaptureDecision = { _, answer in decide = answer }
        var result: MCPToolResult?
        coordinator.handle(proposal, for: sessionID) { result = $0 }
        XCTAssertNil(result)
        XCTAssertEqual(settings.options, .metadataOnly)
        try XCTUnwrap(decide)(false)
        XCTAssertTrue(try XCTUnwrap(result).isError)
        XCTAssertEqual(settings.options, .metadataOnly)

        coordinator.handle(proposal, for: sessionID) { result = $0 }
        try XCTUnwrap(decide)(true)
        XCTAssertFalse(try XCTUnwrap(result).isError)
        XCTAssertTrue(settings.options.requestHeaders)
        XCTAssertTrue(settings.options.responseBody)
        XCTAssertFalse(settings.options.requestBody)

        let capabilities = coordinator.browserCapabilities(for: sessionID)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(capabilities.text.utf8)) as? [String: Any])
        let capture = try XCTUnwrap(json["network_capture"] as? [String: Bool])
        XCTAssertEqual(capture["response_body"], true)

        coordinator.handle(.browserNetwork(.init(
            kind: nil, errorsOnly: nil, clear: nil,
            requestCapture: .init(requestHeaders: nil, responseHeaders: true,
                                 requestBody: nil, responseBody: nil)
        )), for: sessionID) { result = $0 }
        settings.options = .metadataOnly
        try XCTUnwrap(decide)(true)
        XCTAssertTrue(try XCTUnwrap(result).isError)
        XCTAssertEqual(settings.options, .metadataOnly, "A stale approval must not restore old options")
    }

    func testNativeBoundaryFiltersAndBoundsPayloadsAndGlobalRetention() {
        let payload = BrowserNetworkPayload(message: [
            "request_headers": [["Authorization", "private-token"], ["Cookie", "private-cookie"], ["X-Debug", "visible"]],
            "response_headers": [["Set-Cookie", "private-session"]],
            "request_body": String(repeating: "large", count: 5_000),
            "response_body": "response-data"
        ], options: .init(requestHeaders: true, responseHeaders: true, requestBody: true))
        let text = payload.agentText(options: .init(requestHeaders: true, responseHeaders: true, requestBody: true, responseBody: true))
        XCTAssertTrue(text.contains("visible"))
        XCTAssertFalse(text.contains("private-token"))
        XCTAssertFalse(text.contains("private-cookie"))
        XCTAssertFalse(text.contains("private-session"))
        XCTAssertFalse(text.contains("response-data"))
        XCTAssertLessThanOrEqual(payload.requestBody?.utf8.count ?? 0, BrowserNetworkPayload.maximumBodyBytes)

        let buffer = BrowserNetworkPayloadBuffer.shared
        buffer.clear()
        defer { buffer.clear() }
        let owner = UUID()
        for index in 0...BrowserNetworkPayloadBuffer.maximumRecords {
            buffer.record(payload, owner: owner, request: String(index))
        }
        XCTAssertNil(buffer.payload(owner: owner, request: "0"))
        XCTAssertNotNil(buffer.payload(owner: owner, request: "64"))
        XCTAssertNil(buffer.payload(owner: UUID(), request: "64"))
        buffer.clear(owner: owner)
        XCTAssertNil(buffer.payload(owner: owner, request: "64"))
    }
}

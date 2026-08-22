import Foundation
import XCTest
@testable import Threading

/// The launch registry consumes an explicit transport snapshot; it never recovers process
/// settings or the shared listener behind an apparently injectable API.
final class MCPTransportDecisionTests: XCTestCase {
    @MainActor
    func testLiveDecisionReadsTheInjectedSettingsStore() throws {
        let suiteName = "MCPTransportDecisionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        settings.usesMCPStdioBridge = true
        let server = MCPServer(socketPath: nil)

        let decision = MCPBridgeDecision.live(
            settings: settings,
            server: server,
            bundle: .main
        )

        XCTAssertTrue(decision.isEnabled)
        XCTAssertNil(decision.httpPort)
        XCTAssertNil(decision.socketPath)
    }

    @MainActor
    func testHTTPBindingUsesTheInjectedPort() throws {
        let sessionID = SessionID()
        defer { MCPSessionRegistry.remove(sessionID: sessionID) }
        let decision = MCPBridgeDecision(
            isEnabled: false,
            helperURL: URL(fileURLWithPath: "/missing/threading-mcp-bridge"),
            socketPath: nil,
            httpPort: 43_210
        )

        let binding = try XCTUnwrap(MCPSessionRegistry.binding(
            for: sessionID,
            decision: decision
        ))

        guard case .http(let url) = binding else {
            return XCTFail("an off bridge with an injected port must select HTTP")
        }
        XCTAssertTrue(url.hasPrefix("http://127.0.0.1:43210"))
        XCTAssertTrue(url.contains(MCPDefaults.pathPrefix))
    }
}

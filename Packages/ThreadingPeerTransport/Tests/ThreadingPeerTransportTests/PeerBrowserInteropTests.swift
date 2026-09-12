import Foundation
import XCTest
@testable import ThreadingPeerTransport

/// Opt-in shipping-native/browser interop. The loopback fixture serves the real browser assets,
/// coordinates signaling, and checks authenticated REST and WebSocket bytes at the far end.
final class PeerBrowserInteropTests: XCTestCase {
    func testBrowserUsesNativeHostedTunnel() async throws {
        guard let raw = ProcessInfo.processInfo.environment["THREADING_BROWSER_PROOF_URL"],
              let url = URL(string: raw), url.host == "127.0.0.1",
              let port = url.port, let targetPort = UInt16(exactly: port + 1) else {
            throw XCTSkip("Run Service/ThreadingControlPlane/scripts/browser-native-proof.mjs and open its URL.")
        }
        let listener = PeerHostedHostListener(
            endpoint: try PeerRendezvousServiceEndpoint(url),
            hostID: "browser-proof-host",
            credential: try PeerRendezvousCredential("browser-proof-host-credential"),
            targetPort: targetPort
        )
        try await listener.start()
        do {
            let deadline = Date().addingTimeInterval(180)
            while Date() < deadline {
                let (data, _) = try await URLSession.shared.data(from: url.appendingPathComponent("proof-result"))
                let result = String(decoding: data, as: UTF8.self)
                if result == "passed" {
                    await listener.stop()
                    return
                }
                if result.hasPrefix("failed") { XCTFail(result); break }
                try await Task.sleep(for: .milliseconds(500))
            }
            XCTFail("Browser interop did not complete before its deadline.")
            await listener.stop()
        } catch {
            await listener.stop()
            throw error
        }
    }
}

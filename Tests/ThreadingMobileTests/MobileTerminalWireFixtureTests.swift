#if DEBUG
import XCTest
@testable import ThreadingMobile

final class MobileTerminalWireFixtureTests: XCTestCase {
    func testAcceptsOnlyAnAuthenticatedCleartextLoopbackLink() throws {
        let configuration = try XCTUnwrap(MobileTerminalWireFixtureConfiguration.resolve(
            environment: [
                MobileTerminalWireFixtureConfiguration.environmentKey:
                    "http://127.0.0.1:49152/#fixture-token",
            ]
        ))

        XCTAssertEqual(configuration.link.baseURL.absoluteString, "http://127.0.0.1:49152/")
        XCTAssertEqual(configuration.link.token, "fixture-token")
    }

    func testRejectsLANPublicAndTLSOrigins() {
        for raw in [
            "http://192.168.1.181:8760/#token",
            "http://example.com:8760/#token",
            "https://127.0.0.1:8760/#token",
            "http://127.0.0.1:8760/",
        ] {
            XCTAssertNil(MobileTerminalWireFixtureConfiguration.resolve(environment: [
                MobileTerminalWireFixtureConfiguration.environmentKey: raw,
            ]), raw)
        }
    }
}
#endif

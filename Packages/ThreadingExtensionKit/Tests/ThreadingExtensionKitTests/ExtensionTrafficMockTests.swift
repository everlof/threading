import Foundation
import XCTest
@testable import ThreadingExtensionKit

final class ExtensionTrafficMockTests: XCTestCase {
    private func manifest(_ rules: [ExtensionTrafficMock], capability: Bool = true) -> ExtensionManifest {
        ExtensionManifest(
            identifier: "com.example.fixture", name: "Fixture", version: "1.0",
            runtime: .webAssembly, executable: "bin/fixture.wasm",
            capabilities: capability ? [.trafficMockResponses] : [], trafficMocks: rules
        )
    }

    func testFixtureRoundTripAndCapability() throws {
        let rule = ExtensionTrafficMock(
            host: "api.example.test", port: 443, method: "GET", path: "/v1/items?case=empty",
            status: 200, headers: ["Content-Type": "application/json"], body: "{\"items\":[]}"
        )
        let value = manifest([rule])
        try value.validate()
        XCTAssertEqual(try JSONDecoder().decode(ExtensionManifest.self, from: JSONEncoder().encode(value)), value)
        XCTAssertTrue(ThreadingExtensionAPI.safeCapabilities.contains(.trafficMockResponses))
        XCTAssertThrowsError(try manifest([rule], capability: false).validate())
    }

    func testFixtureRejectsAmbiguityAndUnsafeFraming() {
        let rule = ExtensionTrafficMock(host: "api.example.test", port: 443, method: "GET", path: "/v1",
                                        status: 200, headers: ["Content-Length": "999"], body: "small")
        XCTAssertThrowsError(try manifest([rule]).validate())
        let valid = ExtensionTrafficMock(host: "api.example.test", port: 443, method: "GET", path: "/v1",
                                         status: 200, body: "small")
        XCTAssertThrowsError(try manifest([valid, valid]).validate())
        let fragment = ExtensionTrafficMock(host: "api.example.test", port: 443, method: "GET", path: "/v1#other",
                                            status: 200)
        XCTAssertThrowsError(try manifest([fragment]).validate())
    }
}

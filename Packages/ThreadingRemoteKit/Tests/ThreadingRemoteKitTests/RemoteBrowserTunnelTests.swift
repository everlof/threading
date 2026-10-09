import XCTest
@testable import ThreadingRemoteKit

final class RemoteBrowserTunnelTests: XCTestCase {
    func testOnlyLiteralLoopbackOrReservedLocalhostNamesQualify() throws {
        for value in ["http://localhost:3000/a", "http://app.localhost:8080", "http://127.0.0.1:5000", "https://[::1]:8443"] {
            let origin = try XCTUnwrap(RemoteBrowserLocalOrigin(url: XCTUnwrap(URL(string: value))))
            XCTAssertTrue(origin.accepts(authority: origin.authority))
            XCTAssertFalse(origin.accepts(authority: origin.authority + ".evil.com"))
            XCTAssertFalse(origin.accepts(authority: "localhost:9999"))
        }
        for value in ["http://127.evil.com:3000", "http://localhost.evil.com", "http://192.168.1.1", "https://example.com", "ftp://localhost", "http://user:password@localhost:3000", "http://localhost:0"] {
            XCTAssertNil(RemoteBrowserLocalOrigin(url: try XCTUnwrap(URL(string: value))), value)
        }
    }
}

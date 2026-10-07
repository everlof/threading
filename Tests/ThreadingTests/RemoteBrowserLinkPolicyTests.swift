import XCTest
@testable import Threading

final class RemoteBrowserLinkPolicyTests: XCTestCase {
    func testOnlyACompleteSharedWebURLCanBeExported() throws {
        let exact = try XCTUnwrap(URL(string: "https://example.com/path?token=secret#section"))
        XCTAssertEqual(
            RemoteBrowserLinkPolicy.exportableURL(exact, contextKind: .shared),
            exact,
            "an explicit owner action needs the exact URL, not the redacted display value"
        )
        XCTAssertNil(RemoteBrowserLinkPolicy.exportableURL(exact, contextKind: .private))
        XCTAssertNil(RemoteBrowserLinkPolicy.exportableURL(nil, contextKind: .shared))
        XCTAssertNil(RemoteBrowserLinkPolicy.exportableURL(
            URL(string: "file:///Users/me/private.html"), contextKind: .shared
        ))
        XCTAssertNil(RemoteBrowserLinkPolicy.exportableURL(
            URL(string: "https://example.com/?value=\(String(repeating: "x", count: 16_384))"),
            contextKind: .shared
        ))
    }
}

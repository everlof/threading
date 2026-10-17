import XCTest
@testable import Threading

@MainActor
final class ApplicationOpenURLDeliveryTests: XCTestCase {
    func testColdLaunchWaitsForTheOwnerAndPreservesEveryDestination() throws {
        let urls = try [
            "https://example.com/a%2Fb?name=a%26b&value=one+two#part%202",
            "http://localhost:8080/path?next=https%3A%2F%2Fexample.com",
            "file:///tmp/note.md"
        ].map { try XCTUnwrap(URL(string: $0)) }
        var received: [URL] = []
        let delivery = ApplicationOpenURLDelivery { received += $0 }
        delivery.receive(Array(urls.prefix(1)))
        delivery.receive(Array(urls.dropFirst()))
        XCTAssertTrue(received.isEmpty, "No windows or stores may be touched before startup owns state")
        delivery.becomeReady()
        XCTAssertEqual(received.map(\.absoluteString), urls.map(\.absoluteString))
        delivery.becomeReady()
        XCTAssertEqual(received, urls, "Opening the gate again must not replay URLs")
    }

    func testWarmLaunchDeliversImmediately() throws {
        var received: [URL] = []
        let delivery = ApplicationOpenURLDelivery { received += $0 }
        delivery.becomeReady()
        let url = try XCTUnwrap(URL(string: "https://example.com/warm"))
        delivery.receive([url])
        XCTAssertEqual(received, [url])
    }

    func testOnlyHTTPAndHTTPSWithHostsAreWebDestinations() throws {
        for text in ["https://example.com", "HTTP://localhost:8080/a", "https://[::1]/"] {
            XCTAssertTrue(ApplicationOpenURLDelivery.isWebURL(try XCTUnwrap(URL(string: text))))
        }
        for text in ["file:///tmp/a", "javascript:alert(1)", "mailto:a@example.com", "https:/missing-host"] {
            XCTAssertFalse(ApplicationOpenURLDelivery.isWebURL(try XCTUnwrap(URL(string: text))))
        }
    }

    func testShippingBundleAdvertisesBothWebSchemes() throws {
        let types = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]])
        let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        XCTAssertTrue(schemes.contains("http"))
        XCTAssertTrue(schemes.contains("https"))
        let transport = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "NSAppTransportSecurity") as? [String: Any])
        XCTAssertEqual(transport["NSAllowsArbitraryLoadsInWebContent"] as? Bool, true)
        XCTAssertNil(transport["NSAllowsArbitraryLoads"], "Native app services must retain ATS")
    }
}

import AppKit
import Network
import WebKit
import XCTest
@testable import DeviceLogsPlugin

final class BluetoothProfileDownloadTests: XCTestCase {
    @MainActor
    func testRealWebKitDownloadSurvivesNavigationHandoffAndPreservesBytes() async throws {
        let bytes = Data("synthetic profile download".utf8)
        let server = try ProfileHTTPFixture(body: bytes)
        let url = try await server.start()
        defer { server.stop() }
        let complete = expectation(description: "profile download")
        var result: Result<URL, Error>?
        let browser = BluetoothProfileDownloadView(dataStore: .nonPersistent(), allowsURL: { $0 == url }) {
            result = $0
            complete.fulfill()
        }
        browser.webView.load(URLRequest(url: url))
        await fulfillment(of: [complete], timeout: 10)
        let downloaded = try XCTUnwrap(result).get()
        defer { BluetoothProfileDownloadView.removeDownload(downloaded) }
        XCTAssertEqual(try Data(contentsOf: downloaded), bytes)
        XCTAssertNil(browser.webView.navigationDelegate)
    }

    @MainActor
    func testHTTPFailureReportsItsStatusInsteadOfWaitingOnAnErrorPage() async throws {
        let server = try ProfileHTTPFixture(status: 503, body: Data("unavailable".utf8))
        let url = try await server.start()
        defer { server.stop() }
        let complete = expectation(description: "HTTP failure")
        let browser = BluetoothProfileDownloadView(dataStore: .nonPersistent(), allowsURL: { $0 == url }) { result in
            guard case .failure(let error) = result,
                  case .httpStatus(503) = error as? BluetoothProfileDownloadFailure else {
                return XCTFail("Expected a specific HTTP failure")
            }
            complete.fulfill()
        }
        browser.webView.load(URLRequest(url: url))
        await fulfillment(of: [complete], timeout: 10)
    }

    @MainActor
    func testWrongProfileFilenameIsRejectedByRealDownload() async throws {
        let server = try ProfileHTTPFixture(filename: "different.mobileconfig", body: Data("fixture".utf8))
        let url = try await server.start()
        defer { server.stop() }
        let complete = expectation(description: "unexpected profile")
        let browser = BluetoothProfileDownloadView(dataStore: .nonPersistent(), allowsURL: { $0 == url }) { result in
            guard case .failure(let error) = result,
                  case .unexpectedProfile = error as? BluetoothProfileDownloadFailure else {
                return XCTFail("Expected rejection of an unrelated file")
            }
            complete.fulfill()
        }
        browser.webView.load(URLRequest(url: url))
        await fulfillment(of: [complete], timeout: 10)
    }

    @MainActor
    func testPolicyInterruptionWithoutDownloadIsStillAFailureAndSettlesOnce() {
        var completions = 0
        let browser = BluetoothProfileDownloadView(dataStore: .nonPersistent()) { result in
            completions += 1
            guard case .failure(let error) = result else { return XCTFail("Expected failure") }
            XCTAssertEqual((error as NSError).code, 102)
        }
        let interruption = NSError(domain: "WebKitErrorDomain", code: 102)
        browser.webView(browser.webView, didFailProvisionalNavigation: nil, withError: interruption)
        browser.cancel()
        browser.webViewWebContentProcessDidTerminate(browser.webView)
        XCTAssertEqual(completions, 1)
    }

    func testFailureMessagesDoNotExposeAuthenticationDetails() {
        let secret = "account-and-token-must-not-be-displayed"
        for domain in [NSURLErrorDomain, "WebKitErrorDomain", secret] {
            let error = NSError(domain: domain, code: 999, userInfo: [
                NSLocalizedDescriptionKey: secret, NSURLErrorFailingURLStringErrorKey: "https://apple.com/?token=\(secret)",
            ])
            let message = BluetoothProfileDownloadFailure.message(for: error)
            XCTAssertFalse(message.contains(secret))
            XCTAssertTrue(message.contains("999"))
        }
    }

    @MainActor
    func testDedicatedPersistentStoreReusesSignInAndCanForgetIt() async throws {
        guard #available(macOS 14.0, *) else { throw XCTSkip("Named persistent stores require macOS 14") }
        let identifier = UUID()
        XCTAssertNotEqual(identifier, BluetoothProfileWebsiteData.identifier)
        try await verifyRememberAndForget(identifier: identifier)
        try await WKWebsiteDataStore.remove(forIdentifier: identifier)
    }

    @available(macOS 14.0, *)
    @MainActor
    private func verifyRememberAndForget(identifier: UUID) async throws {
        let first = WKWebsiteDataStore(forIdentifier: identifier)
        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .name: "synthetic-sign-in", .value: "fixture", .domain: "example.test", .path: "/",
            .expires: Date().addingTimeInterval(3600), .secure: "TRUE",
        ]))
        await first.httpCookieStore.setCookie(cookie)
        let reopened = WKWebsiteDataStore(forIdentifier: identifier)
        XCTAssertTrue(reopened.isPersistent)
        XCTAssertEqual(reopened.identifier, identifier)
        let remembered = await reopened.httpCookieStore.allCookies()
        XCTAssertEqual(remembered.map(\.name), [cookie.name])
        let otherCookies = await WKWebsiteDataStore.nonPersistent().httpCookieStore.allCookies()
        XCTAssertTrue(otherCookies.isEmpty)
        await withCheckedContinuation { continuation in
            BluetoothProfileWebsiteData.forget(in: reopened) { continuation.resume() }
        }
        let forgotten = await first.httpCookieStore.allCookies()
        XCTAssertTrue(forgotten.isEmpty)
    }
}

/// One small loopback response through real HTTP/WebKit, not a mocked WKDownload. No Apple
/// traffic, credentials, persistent production store or phone installation enters these tests.
private final class ProfileHTTPFixture: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "BluetoothProfileHTTPFixture")
    private let response: Data

    init(status: Int = 200, filename: String = "iOSBluetoothLogging.mobileconfig", body: Data) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        response = Data(("HTTP/1.1 \(status) Fixture\r\nContent-Type: application/x-apple-aspen-config\r\n"
            + "Content-Disposition: attachment; filename=\"\(filename)\"\r\n"
            + "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n").utf8) + body
    }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [self] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/profile")!)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [response, queue] connection in
                connection.start(queue: queue)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, _, _ in
                    connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }
}

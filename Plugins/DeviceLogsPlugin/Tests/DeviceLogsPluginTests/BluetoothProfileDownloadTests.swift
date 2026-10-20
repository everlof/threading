import AppKit
import Network
import WebKit
import XCTest
@testable import DeviceLogsPlugin

final class BluetoothProfileDownloadTests: XCTestCase {
    @MainActor
    func testSignInPopupPreservesPOSTAndOpenerThroughAuthenticatedDownload() async throws {
        let bytes = Data("profile after synthetic sign-in".utf8)
        let posted = expectation(description: "sign-in POST keeps its body")
        let server = try ProfileHTTPFixture(body: bytes) { request in
            if request.hasPrefix("GET /signin ") {
                return ProfileHTTPFixture.html("""
                    <form method="post" target="apple-sign-in" action="/authenticate">
                        <input name="synthetic" value="fixture">
                    </form>
                    <script>
                    addEventListener('message', event => {
                        if (event.origin === location.origin && event.data === 'signed-in')
                            location.href = '/profile';
                    });
                    document.forms[0].submit();
                    </script>
                    """)
            }
            if request.hasPrefix("POST /authenticate "), request.contains("synthetic=fixture") {
                posted.fulfill()
                return ProfileHTTPFixture.html("""
                    <script>
                    if (window.opener) {
                        window.opener.postMessage('signed-in', location.origin);
                        window.close();
                    }
                    </script>
                    """, headers: "Set-Cookie: synthetic-sign-in=fixture; Path=/; HttpOnly\r\n")
            }
            if request.hasPrefix("GET /profile "), request.contains("synthetic-sign-in=fixture") {
                return nil // the fixture's profile response
            }
            return ProfileHTTPFixture.html("Sign in again")
        }
        let url = try await server.start()
        defer { server.stop() }
        let complete = expectation(description: "authenticated profile download")
        var result: Result<URL, Error>?
        let browser = BluetoothProfileDownloadView(dataStore: .nonPersistent(), allowsURL: {
            $0?.host == url.host && $0?.port == url.port && $0?.scheme == url.scheme
        }) {
            result = $0
            complete.fulfill()
        }
        defer { browser.cancel() }
        // Only the synthetic fixture opens without a user gesture. Production keeps WebKit's
        // normal popup policy, and never injects or reads authentication-page JavaScript.
        browser.webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        browser.webView.load(URLRequest(url: url.deletingLastPathComponent().appendingPathComponent("signin")))
        await fulfillment(of: [posted, complete], timeout: 5)
        let downloaded = try XCTUnwrap(result).get()
        defer { BluetoothProfileDownloadView.removeDownload(downloaded) }
        XCTAssertEqual(try Data(contentsOf: downloaded), bytes)
        XCTAssertEqual(browser.webView.url?.path, "/signin", "The opener must survive the child sign-in window")
        XCTAssertNil(browser.webView.navigationDelegate)
    }

    @MainActor
    func testSignInWindowsAreBoundedAndCancelRetiresEveryBrowser() async throws {
        let children = expectation(description: "bounded child pages")
        children.expectedFulfillmentCount = BluetoothProfileDownloadView.Metrics.maximumSignInWindows
        let server = try ProfileHTTPFixture(body: Data()) { request in
            if request.hasPrefix("GET /signin ") {
                return ProfileHTTPFixture.html("""
                    <script>
                    for (let i = 0; i < 10; i++) window.open('/child', 'sign-in-' + i);
                    </script>
                    """)
            }
            children.fulfill()
            return ProfileHTTPFixture.html("Synthetic sign-in")
        }
        let url = try await server.start()
        defer { server.stop() }
        var completions = 0
        let store = WKWebsiteDataStore.nonPersistent()
        let browser = BluetoothProfileDownloadView(dataStore: store, allowsURL: {
            $0?.host == url.host && $0?.port == url.port
        }) { result in
            completions += 1
            guard case .failure(let error) = result else { return XCTFail("Cancellation cannot send a profile") }
            XCTAssertEqual((error as NSError).code, NSURLErrorCancelled)
        }
        browser.webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        browser.webView.load(URLRequest(url: url.deletingLastPathComponent().appendingPathComponent("signin")))
        await fulfillment(of: [children], timeout: 5)
        let views = try XCTUnwrap(browser.webView.superview).subviews.compactMap { $0 as? WKWebView }
        XCTAssertEqual(views.count, 1 + BluetoothProfileDownloadView.Metrics.maximumSignInWindows)
        XCTAssertTrue(browser.webView.isHidden)
        XCTAssertFalse(browser.presentedWebView.isHidden)
        for view in views {
            XCTAssertTrue(view.configuration.websiteDataStore === store)
            XCTAssertTrue(view.configuration.userContentController.userScripts.isEmpty)
        }
        browser.cancel()
        browser.cancel()
        let stopped = Date().addingTimeInterval(2)
        while views.contains(where: \.isLoading), Date() < stopped {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        for view in views {
            XCTAssertNil(view.navigationDelegate)
            XCTAssertNil(view.uiDelegate)
            XCTAssertFalse(view.isLoading)
            browser.webViewDidClose(view) // late framework callbacks cannot complete twice
        }
        XCTAssertEqual(completions, 1)
        XCTAssertTrue(browser.presentedWebView === browser.webView)
        XCTAssertEqual(browser.webView.superview?.subviews.count, 1)
    }

    @MainActor
    func testDownloadFromChildWindowCompletesAndReleasesIt() async throws {
        let bytes = Data("profile in child window".utf8)
        let server = try ProfileHTTPFixture(body: bytes) { request in
            guard request.hasPrefix("GET /signin ") else { return nil }
            return ProfileHTTPFixture.html("<script>window.open('/profile', 'download')</script>")
        }
        let url = try await server.start()
        defer { server.stop() }
        let complete = expectation(description: "child profile download")
        var result: Result<URL, Error>?
        let browser = BluetoothProfileDownloadView(dataStore: .nonPersistent(), allowsURL: {
            $0?.host == url.host && $0?.port == url.port
        }) {
            result = $0
            complete.fulfill()
        }
        defer { browser.cancel() }
        browser.webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        browser.webView.load(URLRequest(url: url.deletingLastPathComponent().appendingPathComponent("signin")))
        await fulfillment(of: [complete], timeout: 5)
        let downloaded = try XCTUnwrap(result).get()
        defer { BluetoothProfileDownloadView.removeDownload(downloaded) }
        XCTAssertEqual(try Data(contentsOf: downloaded), bytes)
        XCTAssertTrue(browser.presentedWebView === browser.webView)
        XCTAssertEqual(browser.webView.superview?.subviews.count, 1)
    }

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
    private let route: (@Sendable (String) -> Data?)?

    init(status: Int = 200, filename: String = "iOSBluetoothLogging.mobileconfig", body: Data,
         route: (@Sendable (String) -> Data?)? = nil) throws {
        self.route = route
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        response = Data(("HTTP/1.1 \(status) Fixture\r\nContent-Type: application/x-apple-aspen-config\r\n"
            + "Content-Disposition: attachment; filename=\"\(filename)\"\r\n"
            + "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n").utf8) + body
    }

    static func html(_ body: String, headers: String = "") -> Data {
        Data(("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n"
            + headers + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body).utf8)
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
            listener.newConnectionHandler = { [self] connection in
                connection.start(queue: queue)
                receiveRequest(on: connection, collected: Data())
            }
            listener.start(queue: queue)
        }
    }

    private func receiveRequest(on connection: NWConnection, collected: Data) {
        let maximumBytes = 16_384
        guard collected.count < maximumBytes else { connection.cancel(); return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: maximumBytes - collected.count) { [self] data, _, complete, error in
            let requestBytes = collected + (data ?? Data())
            let request = String(decoding: requestBytes, as: UTF8.self)
            if let boundary = request.range(of: "\r\n\r\n") {
                let headers = request[..<boundary.lowerBound].components(separatedBy: "\r\n")
                let length = headers.first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                if request[boundary.upperBound...].utf8.count >= length {
                    let answer = route?(request) ?? response
                    connection.send(content: answer, completion: .contentProcessed { _ in connection.cancel() })
                    return
                }
            }
            guard error == nil, !complete else { connection.cancel(); return }
            receiveRequest(on: connection, collected: requestBytes)
        }
    }

    func stop() { listener.cancel() }
}

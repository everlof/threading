import Network
import XCTest

@MainActor
final class StandaloneBrowserJourneyUITests: XCTestCase {
    func testLaunchProvidesAnAddressAndBrowserCommandNeedsNoConversation() throws {
        continueAfterFailure = false
        let sandbox = try UIScenarioSandbox.make()
        let app = XCUIApplication()
        sandbox.configure(app)
        defer { app.terminate(); try? sandbox.remove() }
        app.launch()
        app.activate()
        let address = app.textFields["browser.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 20))
        try recordScenarioScreenshot(
            checkpoint: "standalone-browser-launch", order: 1, title: "Browser without a conversation",
            description: "A fresh profile offers an address and search field immediately, without agent setup.",
            journey: "Standalone browsing", in: sandbox,
            of: app.windows.containing(.textField, identifier: "browser.address").firstMatch
        )
        app.typeKey("w", modifierFlags: .command)
        XCTAssertFalse(address.exists)
        app.typeKey("b", modifierFlags: [.command, .shift])
        XCTAssertTrue(address.waitForExistence(timeout: 5))
    }

    func testColdAndWarmExternalURLsRenderTheirExactDestinations() throws {
        guard #available(macOS 13.3, *) else { throw XCTSkip("XCUITest URL launch requires macOS 13.3") }
        continueAfterFailure = false
        let sandbox = try UIScenarioSandbox.make()
        let app = XCUIApplication()
        sandbox.configure(app)
        // Exercise real first launch, including the still-unfinished setup walkthrough.
        let onboardingArgument = try XCTUnwrap(app.launchArguments.firstIndex(of: "-onboardingCompletedVersion"))
        app.launchArguments[onboardingArgument + 1] = "0"
        let server = try StandaloneBrowserPageServer()
        defer { app.terminate(); server.stop(); try? sandbox.remove() }

        let coldPath = "/cold/a%2Fb?name=a%26b&value=one+two"
        app.open(server.url(path: coldPath + "#part%202"))
        app.activate()
        XCTAssertTrue(app.staticTexts[coldPath].waitForExistence(timeout: 20))
        XCTAssertTrue(app.windows["Welcome to Threading"].exists,
                      "The cold URL must work while first-launch setup is still unfinished")
        let coldWindow = app.windows.containing(.staticText, identifier: coldPath).firstMatch
        XCTAssertEqual(coldWindow.textFields["browser.address"].value as? String,
                       server.url(path: coldPath + "#part%202").absoluteString)

        let warmPath = "/warm?value=two%2Fthree"
        app.open(server.url(path: warmPath))
        app.activate()
        XCTAssertTrue(app.staticTexts[warmPath].waitForExistence(timeout: 10))
        XCTAssertTrue(coldWindow.exists, "A warm URL must keep the existing browser window alive")
        XCTAssertEqual(app.windows.containing(.textField, identifier: "browser.address").count, 2)
        try recordScenarioScreenshot(
            checkpoint: "standalone-browser-external-link", order: 2, title: "External link opened",
            description: "Launch Services opens the exact requested URL in a user-owned browser, including before setup is complete.",
            journey: "Standalone browsing", in: sandbox,
            of: app.windows.containing(.staticText, identifier: warmPath).firstMatch
        )
    }
}

/// A loopback page echoes the HTTP request target, so decoding or normalizing an incoming URL
/// would fail the journey without depending on a public website or signing into an account.
private final class StandaloneBrowserPageServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "StandaloneBrowserPageServer")

    func url(path: String) -> URL {
        URL(string: "http://127.0.0.1:\(listener.port!.rawValue)\(path)")!
    }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.newConnectionHandler = { connection in
            connection.start(queue: DispatchQueue.global(qos: .utility))
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, error in
                guard error == nil, let data else { connection.cancel(); return }
                let target = String(decoding: data, as: UTF8.self).split(separator: " ").dropFirst().first ?? ""
                let escaped = target.replacingOccurrences(of: "&", with: "&amp;")
                    .replacingOccurrences(of: "<", with: "&lt;")
                    .replacingOccurrences(of: ">", with: "&gt;")
                let body = Data("<!doctype html><title>External link</title><h1>\(escaped)</h1>".utf8)
                var response = Data("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
                response.append(body)
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success,
              let port = listener.port, port.rawValue != 0 else {
            listener.cancel()
            throw NSError(domain: "StandaloneBrowserPageServer", code: 1)
        }
    }

    func stop() { listener.cancel() }
}

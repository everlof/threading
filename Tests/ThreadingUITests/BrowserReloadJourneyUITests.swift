import Network
import XCTest

@MainActor
final class BrowserReloadJourneyUITests: XCTestCase {
    private var application: XCUIApplication?
    private var sandbox: UIScenarioSandbox?

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        sandbox = try UIScenarioSandbox.make()
    }

    override func tearDown() async throws {
        application?.terminate()
        application = nil
        try sandbox?.remove()
        sandbox = nil
        try await super.tearDown()
    }

    func testCommandRReloadsWithBrowserFocusAndRenamesWithComposerFocus() throws {
        let server = try ReloadJourneyServer()
        defer { server.stop() }
        let sandbox = try XCTUnwrap(sandbox)
        let app = XCUIApplication()
        application = app
        let fixture = try sandbox.prepareCodexBrowserAnnotationsFixture()
        _ = sandbox.configure(app)
        fixture.configure(app, scenarioRoot: sandbox.root)
        sandbox.launch(app)
        let composer = app.textViews["composer.prompt.text"]
        XCTAssertTrue(composer.waitForExistence(timeout: 20))

        app.typeKey("b", modifierFlags: [.command, .shift])
        let address = app.textFields["browser.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        address.click()
        address.typeKey("a", modifierFlags: .command)
        address.typeText(server.url.absoluteString + "\n")
        XCTAssertTrue(app.staticTexts["Load 1"].waitForExistence(timeout: 10))

        app.buttons["Focus page"].click()
        app.typeKey("r", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Load 2"].waitForExistence(timeout: 5),
                      "Cmd+R must reload after clicking the page")

        let input = app.textFields["Page input"]
        input.click()
        input.typeText("draft")
        input.typeKey("r", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Load 3"].waitForExistence(timeout: 5),
                      "Cmd+R must reload while editing a page field")

        composer.click()
        app.radioButtons["Reload fixture"].click()
        app.typeKey("r", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Load 4"].waitForExistence(timeout: 5),
                      "Cmd+R must reload when the browser tab itself has keyboard focus")

        address.click()
        address.typeKey("r", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Load 5"].waitForExistence(timeout: 5),
                      "Cmd+R must reload while editing the address")
        try recordScenarioScreenshot(
            checkpoint: "browser-reloaded", order: 1, title: "Focused browser reloaded",
            description: "Command-R reloads from page, page input, browser tab, and address field focus.",
            journey: "Focused browser reload", in: sandbox, of: app.windows.firstMatch
        )

        composer.click()
        composer.typeKey("r", modifierFlags: .command)
        XCTAssertTrue(app.buttons["Rename"].waitForExistence(timeout: 5),
                      "Cmd+R outside the browser must still open Rename Session")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["Load 5"].exists)
    }
}

/// A fresh loopback origin gives the shipping WebKit page a reload counter without external I/O.
private final class ReloadJourneyServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "BrowserReloadJourneyServer")

    var url: URL {
        URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/reload")!
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
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { _, _, _, error in
                guard error == nil else { connection.cancel(); return }
                let page = """
                <!doctype html><title>Reload fixture</title>
                <h1 id="count"></h1><button>Focus page</button><input aria-label="Page input">
                <script>
                const count = Number(sessionStorage.getItem('loads') || 0) + 1;
                sessionStorage.setItem('loads', String(count));
                document.getElementById('count').textContent = 'Load ' + count;
                </script>
                """
                let body = Data(page.utf8)
                var response = Data("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nCache-Control: no-store\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
                response.append(body)
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, listener.port != nil else {
            listener.cancel()
            throw NSError(domain: "BrowserReloadJourneyServer", code: 1)
        }
    }

    func stop() { listener.cancel() }
}

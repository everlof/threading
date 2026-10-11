import Darwin
import XCTest

@MainActor
final class ProxyClientApprovalJourneyUITests: XCTestCase {
    func testApproveWaitingClientRememberRelaunchAndRevoke() throws {
        continueAfterFailure = false
        let sandbox = try UIScenarioSandbox.make()
        let app = XCUIApplication()
        sandbox.configure(app)
        app.launchEnvironment["THREADING_UI_SCENARIO_PROXY"] = "1"
        defer { app.terminate(); try? sandbox.remove() }

        func launch() throws -> Int {
            let endpoint = sandbox.root.appendingPathComponent("proxy-endpoint.json")
            try? FileManager.default.removeItem(at: endpoint)
            sandbox.launch(app)
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                FileManager.default.fileExists(atPath: endpoint.path)
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
            let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: endpoint)) as? [String: Any])
            return try XCTUnwrap(value["port"] as? Int)
        }
        func quit() {
            app.activate()
            app.typeKey("q", modifierFlags: .command)
            XCTAssertTrue(app.wait(for: .notRunning, timeout: 10), "Quit must finish before relaunch")
        }
        func capture(_ name: String, _ order: Int) throws {
            try recordScenarioScreenshot(checkpoint: name, order: order,
                title: "Proxy client approval", description: "A real bundled proxy holds this connection until a choice is made in the shipping dialog.",
                journey: "Proxy client access", in: sandbox, of: app.windows.firstMatch)
        }
        func answer(_ title: String) {
            let button = app.buttons[title].firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 10))
            button.click()
        }
        var port = try launch()
        let first = try ProxyJourneyClient(port: port)
        XCTAssertTrue(app.buttons["Allow Once"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertNil(first.receive(timeout: 0.1), "Client bytes must remain unread before approval")
        try capture("proxy-client-waiting", 1)
        answer("Allow Once")
        XCTAssertTrue(first.receive()?.contains("400") == true)
        let second = try ProxyJourneyClient(port: port)
        answer("This Capture")
        XCTAssertTrue(second.receive()?.contains("400") == true)
        let third = try ProxyJourneyClient(port: port)
        XCTAssertTrue(third.receive()?.contains("400") == true)
        XCTAssertFalse(app.buttons["Allow Once"].firstMatch.exists)

        quit()
        port = try launch()
        let remembered = try ProxyJourneyClient(port: port)
        answer("Always Allow This IP")
        XCTAssertTrue(remembered.receive()?.contains("400") == true)
        // Relaunch is the durable result; preferences belong to the target app’s isolated home.
        quit()
        port = try launch()
        let restored = try ProxyJourneyClient(port: port)
        XCTAssertTrue(restored.receive()?.contains("400") == true, "Remembered grant survives app relaunch")
        XCTAssertFalse(app.buttons["Allow Once"].firstMatch.exists)

        app.typeKey(",", modifierFlags: .command)
        let tools = app.radioButtons["Tools"].firstMatch
        XCTAssertTrue(tools.waitForExistence(timeout: 10))
        tools.click()
        let search = app.textFields["settings.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click()
        search.typeText("Proxy Client Access")
        let destination = app.buttons["Proxy Client Access"].firstMatch
        XCTAssertTrue(destination.waitForExistence(timeout: 5))
        destination.click()
        let forget = app.buttons["Forget Saved IPs"].firstMatch
        XCTAssertTrue(forget.waitForExistence(timeout: 5))
        XCTAssertTrue(forget.isHittable, "Search must reveal the virtual settings row")
        try capture("proxy-client-revoke", 2)
        forget.click()
        XCTAssertTrue(app.staticTexts["Saved IPs forgotten. Device captures stopped."].firstMatch.waitForExistence(timeout: 5))
        // The next launch must ask again and denial must also cover automatic retries.
        quit()
        port = try launch()
        let denied = try ProxyJourneyClient(port: port)
        answer("Deny")
        XCTAssertEqual(denied.receive(), "")
        let retry = try ProxyJourneyClient(port: port)
        XCTAssertEqual(retry.receive(), "")
        XCTAssertFalse(app.buttons["Allow Once"].firstMatch.exists)
    }
}

private final class ProxyJourneyClient {
    private let descriptor: Int32

    init(port: Int) throws {
        descriptor = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = UInt16(port).bigEndian
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard descriptor >= 0, connected == 0 else { throw NSError(domain: "ProxyJourney", code: Int(errno)) }
        _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
        let bytes = Data("invalid\r\n\r\n".utf8)
        _ = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
    }

    deinit { close(descriptor) }

    func receive(timeout: TimeInterval = 10) -> String? {
        var ready = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        guard poll(&ready, 1, Int32(timeout * 1000)) > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: 4096)
        let count = read(descriptor, &bytes, bytes.count)
        if count < 0, errno == ECONNRESET { return "" }
        guard count >= 0 else { return nil }
        return String(decoding: bytes.prefix(count), as: UTF8.self)
    }
}

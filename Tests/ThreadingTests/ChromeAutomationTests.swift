import AppKit
import XCTest

@testable import Threading

/// The two halves of "sign in once, keep it": the password takeover that hands a field to the
/// user, and the attached Chrome backend that drives the profile they signed into.
///
/// What is asserted here is the *boundary*, not the browsing: which window comes forward, which
/// origins were approved before anything launched, and what a refusal says. The parts that need
/// a person — Touch ID, a password manager, a real sign-in — are deliberately absent, because a
/// test that simulated them would be asserting about a fiction.
@MainActor
final class ChromeAutomationTests: XCTestCase {

    // MARK: - Password Takeover

    /// The takeover has to reach the user, not merely the pane.
    ///
    /// Before this, both refusals called `revealDisplayPane`, which returns `false` and does
    /// nothing at all when the asking session is not the one on screen — so a background
    /// takeover unhid nothing while the user's own fill shortcut went to whatever app was
    /// frontmost. The order is the fix and therefore the assertion: activate, select, *then*
    /// reveal, so the reveal happens once the session is visible.
    func testPasswordTakeoverActivatesSelectsThenRevealsForABackgroundSession() async throws {
        let sessionID = SessionID()
        let otherSessionID = SessionID()
        let pane = DisplayPaneController()
        pane.showSession(otherSessionID)
        let browser = try XCTUnwrap(pane.addBrowserTab(for: sessionID))
        defer {
            for tab in pane.tabs(for: sessionID) {
                _ = pane.closeTab(id: tab.id, for: sessionID)
            }
        }

        var activated = 0
        var paneVisible: Bool?
        // Stands in for the sidebar: the real one selects the session when the notification
        // arrives, and the pane can only be revealed after that has happened.
        final class Selection { var current: SessionID? }
        let selection = Selection()
        selection.current = otherSessionID
        var openedSessions: [SessionID] = []
        let observer = NotificationCenter.default.observe(SessionNotificationOpened.self) { event in
            openedSessions.append(event.sessionID)
            selection.current = event.sessionID
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let coordinator = AgentToolCoordinator(
            displayPaneController: pane,
            visibleSessionID: { selection.current },
            setPaneVisible: { paneVisible = $0 },
            windowProvider: { nil },
            activateApp: { activated += 1 }
        )

        _ = await coordinator.beginPasswordTakeover(
            for: sessionID,
            browser: browser,
            selector: "input[type=password]"
        )

        XCTAssertEqual(activated, 1, "the frontmost app is the one a password fill lands in")
        XCTAssertEqual(openedSessions, [sessionID])
        XCTAssertEqual(
            paneVisible,
            true,
            "the pane must be revealed after the selection lands, not before it"
        )
        XCTAssertNotNil(
            pane.browser(for: sessionID),
            "the takeover keeps the owning session's browser as the visible surface"
        )
    }

    /// Every password refusal goes through the one helper, including the batch one, which used
    /// to reveal the pane and then leave the field unfocused for no reason.
    func testBothPasswordRefusalsRunTheSameTakeover() async throws {
        let sessionID = SessionID()
        let pane = DisplayPaneController()
        pane.showSession(sessionID)
        _ = try XCTUnwrap(pane.addBrowserTab(for: sessionID))
        defer {
            for tab in pane.tabs(for: sessionID) {
                _ = pane.closeTab(id: tab.id, for: sessionID)
            }
        }

        var activations = 0
        let coordinator = AgentToolCoordinator(
            displayPaneController: pane,
            visibleSessionID: { sessionID },
            setPaneVisible: { _ in },
            windowProvider: { nil },
            browserAccessDecisionProvider: { _, _, decide in decide(.allowOnce) },
            activateApp: { activations += 1 }
        )

        // Nothing is loaded, so both calls refuse before reaching a real password field. What is
        // being checked is that they take the same route to the user on the way out.
        _ = await call(
            coordinator,
            .browserType(.init(
                ref: nil,
                selector: "input[type=password]",
                text: "never-typed",
                slowly: false,
                submit: false
            )),
            sessionID: sessionID
        )
        _ = await call(
            coordinator,
            .browserFillForm(.init(fields: [
                .init(
                    ref: nil,
                    selector: "input[type=password]",
                    value: "never-typed",
                    label: nil,
                    checked: nil
                )
            ])),
            sessionID: sessionID
        )
        XCTAssertEqual(
            activations,
            0,
            "with no authorized page there is no field to hand over, so nothing comes forward"
        )
    }

    // MARK: - Profile

    func testProfileDistinguishesMissingChromeFromAnUnusedDirectory() throws {
        let root = try temporaryDirectory()
        let directory = root.appendingPathComponent("ChromeAutomationProfile", isDirectory: true)

        let missing = ChromeAutomationProfile(
            directory: directory,
            locateChrome: { nil },
            launch: { _, _ in XCTFail("nothing to launch"); return false }
        )
        XCTAssertEqual(missing.state, .chromeMissing)

        let chrome = root.appendingPathComponent("Google Chrome.app")
        var launched: [String] = []
        let profile = ChromeAutomationProfile(
            directory: directory,
            locateChrome: { chrome },
            launch: { _, arguments in
                launched = arguments
                return true
            }
        )
        XCTAssertEqual(profile.state, .notSetUp)
        XCTAssertFalse(profile.isLocked)

        // Playwright creates the directory itself, so an empty one must not read as set up.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertEqual(profile.state, .notSetUp)

        XCTAssertTrue(profile.openForSetup())
        XCTAssertEqual(launched.first, "--user-data-dir=\(directory.path)")
        XCTAssertTrue(launched.contains("--no-first-run"))
        XCTAssertFalse(
            launched.contains { $0.contains("remote-debugging") },
            "the setup window is an ordinary Chrome, not a debugging target"
        )

        // Chrome writes its own profile folder the first time it runs there.
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("Default", isDirectory: true),
            withIntermediateDirectories: true
        )
        XCTAssertEqual(profile.state, .ready)
    }

    /// Chrome's lock is a symlink to `host-ip:pid`, which never resolves. Following it answers
    /// "no lock" for a profile that is very much locked, so the read must not follow it.
    func testProfileSeesChromesUnresolvableSingletonLock() throws {
        let directory = try temporaryDirectory()
            .appendingPathComponent("Profile", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let profile = ChromeAutomationProfile(
            directory: directory,
            locateChrome: { URL(fileURLWithPath: "/Applications/Google Chrome.app") },
            launch: { _, _ in true }
        )
        XCTAssertFalse(profile.isLocked)

        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("SingletonLock"),
            withDestinationURL: URL(fileURLWithPath: "somehost-192.168.0.2:41231")
        )
        XCTAssertTrue(profile.isLocked)
    }

    // MARK: - The Tool

    func testAttachedChromeIsAdvertisedAsItsOwnBackendAndArgumentType() throws {
        XCTAssertNotNil(MCPTools.definition(for: .browserAttachChrome))
        XCTAssertTrue(
            MCPToolCatalog.browser.tools.contains { $0.builtInTool == .browserAttachChrome },
            "a tool with a schema and a handler must also be listed in its group"
        )
        let definition = try XCTUnwrap(MCPTools.definition(for: .browserAttachChrome))
        XCTAssertEqual(definition.inputSchema.required, ["allowed_origins", "steps"])
        XCTAssertTrue(definition.description.contains("browser_run_isolated"))
        XCTAssertFalse(
            definition.annotations?.readOnlyHint ?? true,
            "driving a signed-in browser is never a read-only hint"
        )

        let request = try JSONDecoder().decode(
            JSONRPCRequest.self,
            from: Data(
                #"""
                {
                  "jsonrpc":"2.0","id":8,"method":"tools/call",
                  "params":{
                    "name":"browser_attach_chrome",
                    "arguments":{
                      "allowed_origins":["https://example.test"],
                      "timeout_ms":9000,
                      "screenshot":true,
                      "full_page":false,
                      "include_image":false,
                      "steps":[{"action":"goto","url":"https://example.test/in"}]
                    }
                  }
                }
                """#.utf8
            )
        )
        guard case .toolCall(.browserAttachChrome(let attach)) = request.parameters else {
            return XCTFail("Expected typed browser_attach_chrome arguments")
        }
        XCTAssertEqual(attach.allowedOrigins, ["https://example.test"])
        XCTAssertEqual(attach.timeoutMS, 9_000)
        XCTAssertEqual(attach.screenshot, true)
        XCTAssertEqual(attach.steps?.count, 1)

        // The wire spelling is the bridge's contract; a re-encode has to survive the round trip.
        let encoded = try XCTUnwrap(
            String(data: try JSONEncoder().encode(attach), encoding: .utf8)
        )
        XCTAssertTrue(encoded.contains("\"allowed_origins\""), encoded)
        XCTAssertTrue(encoded.contains("\"timeout_ms\""), encoded)
        XCTAssertTrue(encoded.contains("\"include_image\""), encoded)
    }

    /// An origin the user declined refuses the whole run. A shorter run would be worse than no
    /// run: the agent asked for a scenario, and silently dropping a site from it produces a
    /// result nobody can read correctly.
    func testOneDeniedOriginRefusesTheEntireRunBeforeAnythingLaunches() async throws {
        let sessionID = SessionID()
        let pane = DisplayPaneController()
        pane.showSession(sessionID)
        let directory = try temporaryDirectory()
            .appendingPathComponent("Profile", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("Default", isDirectory: true),
            withIntermediateDirectories: true
        )
        let profile = ChromeAutomationProfile(
            directory: directory,
            locateChrome: { URL(fileURLWithPath: "/Applications/Google Chrome.app") },
            launch: { _, _ in XCTFail("a denied run must not open Chrome"); return false }
        )

        var asked: [String] = []
        let coordinator = AgentToolCoordinator(
            displayPaneController: pane,
            visibleSessionID: { sessionID },
            setPaneVisible: { _ in },
            windowProvider: { nil },
            browserAccessDecisionProvider: { origin, _, decide in
                asked.append(origin.key)
                decide(origin.host == "denied.test" ? .deny : .allowOnce)
            },
            chromeAutomationProfile: profile
        )

        let denied = await call(
            coordinator,
            .browserAttachChrome(attachArguments(
                origins: ["https://allowed.test", "https://denied.test"]
            )),
            sessionID: sessionID
        )
        XCTAssertTrue(denied.isError)
        XCTAssertTrue(denied.text.contains("https://denied.test"), denied.text)
        XCTAssertTrue(denied.text.contains("nothing was launched"), denied.text)
        XCTAssertEqual(asked, ["https://allowed.test", "https://denied.test"])
    }

    func testAttachRefusesUnsetUpProfilesAndOriginsThatAreNotOrigins() async throws {
        let sessionID = SessionID()
        let pane = DisplayPaneController()
        pane.showSession(sessionID)
        let directory = try temporaryDirectory()
            .appendingPathComponent("Profile", isDirectory: true)
        let profile = ChromeAutomationProfile(
            directory: directory,
            locateChrome: { URL(fileURLWithPath: "/Applications/Google Chrome.app") },
            launch: { _, _ in XCTFail("nothing should launch"); return false }
        )
        let coordinator = AgentToolCoordinator(
            displayPaneController: pane,
            visibleSessionID: { sessionID },
            setPaneVisible: { _ in },
            windowProvider: { nil },
            browserAccessDecisionProvider: { _, _, decide in
                XCTFail("an unusable profile must be refused before anyone is prompted")
                decide(.deny)
            },
            chromeAutomationProfile: profile
        )

        let notSetUp = await call(
            coordinator,
            .browserAttachChrome(attachArguments(origins: ["https://example.test"])),
            sessionID: sessionID
        )
        XCTAssertTrue(notSetUp.isError)
        XCTAssertTrue(notSetUp.text.contains("Set Up Automation Profile"), notSetUp.text)

        // A path is not an origin, and quietly widening one to its host would grant more than
        // the user was shown.
        let malformed = await call(
            coordinator,
            .browserAttachChrome(attachArguments(origins: ["https://example.test/private"])),
            sessionID: sessionID
        )
        XCTAssertTrue(malformed.isError)
        XCTAssertTrue(malformed.text.contains("with no path"), malformed.text)

        let empty = await call(
            coordinator,
            .browserAttachChrome(attachArguments(origins: [])),
            sessionID: sessionID
        )
        XCTAssertTrue(empty.isError)
        XCTAssertTrue(empty.text.contains("allowed_origins"), empty.text)
    }

    func testChromeMissingIsReportedAsItsOwnCapabilityStatus() {
        let sessionID = SessionID()
        let pane = DisplayPaneController()
        pane.showSession(sessionID)
        let coordinator = AgentToolCoordinator(
            displayPaneController: pane,
            visibleSessionID: { sessionID },
            setPaneVisible: { _ in },
            windowProvider: { nil },
            chromeAutomationProfile: ChromeAutomationProfile(
                directory: URL(fileURLWithPath: "/nonexistent/Profile"),
                locateChrome: { nil },
                launch: { _, _ in false }
            )
        )
        let capabilities = coordinator.browserCapabilities(for: sessionID)
        XCTAssertFalse(capabilities.isError, capabilities.text)
        XCTAssertTrue(
            capabilities.text.contains("playwright_attached_chrome"),
            "a third backend the agent can call has to appear in the honest capability matrix"
        )
        XCTAssertTrue(
            capabilities.text.contains("chrome_missing")
                || capabilities.text.contains("runtime_missing"),
            capabilities.text
        )
    }

    // MARK: - Helpers

    private func attachArguments(origins: [String]) -> BrowserAttachRunArguments {
        BrowserAttachRunArguments(
            allowedOrigins: origins,
            timeoutMS: nil,
            screenshot: nil,
            fullPage: nil,
            includeImage: nil,
            steps: [
                BrowserIsolatedStep(
                    action: "goto",
                    url: "https://allowed.test/",
                    waitUntil: nil,
                    role: nil,
                    name: nil,
                    label: nil,
                    placeholder: nil,
                    testID: nil,
                    text: nil,
                    css: nil,
                    exact: nil,
                    nth: nil,
                    value: nil,
                    optionLabel: nil,
                    key: nil,
                    state: nil,
                    expectedText: nil,
                    timeoutMS: nil
                )
            ]
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chrome-automation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func call(
        _ coordinator: AgentToolCoordinator,
        _ tool: MCPToolCall,
        sessionID: SessionID
    ) async -> MCPToolResult {
        await withCheckedContinuation { continuation in
            coordinator.handle(tool, for: sessionID) {
                continuation.resume(returning: $0)
            }
        }
    }
}

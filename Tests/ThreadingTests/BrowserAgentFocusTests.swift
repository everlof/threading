import AppKit
import WebKit
import XCTest
@testable import Threading

@MainActor
final class BrowserAgentFocusTests: HostedStoreTestCase {
    func testAgentNavigationKeepsTheComposerFocused() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }

        await fixture.navigate()
        fixture.assertComposerFocus()
        let newTab = await fixture.call(.browserTabs(.init(action: "new", tab: nil, context: nil)))
        XCTAssertFalse(newTab.isError, newTab.text)
        fixture.assertComposerFocus()
        fixture.typeInComposer()

        XCTAssertTrue(fixture.pane.performPanelCommand(.browser, title: "Browser", for: fixture.sessionID))
        let opened = try XCTUnwrap(fixture.pane.browser(for: fixture.sessionID))
        let responder = fixture.window.firstResponder
        let focusedView = ((responder as? NSText)?.delegate as? NSView) ?? responder as? NSView
        XCTAssertTrue(focusedView?.isDescendant(of: opened.view) == true,
                      "The user's own new-browser command still takes focus")
    }

    func testAgentInteractionsKeepDOMFocusSeparateFromComposerFocus() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        await fixture.navigate()
        fixture.focusComposer()
        let browser = try XCTUnwrap(fixture.pane.browser(for: fixture.sessionID))

        let actions: [MCPToolCall] = [
            .browserClick(.init(ref: nil, selector: "#next", x: nil, y: nil,
                                button: nil, clickCount: nil)),
            .browserClick(.init(ref: nil, selector: "#name", x: nil, y: nil,
                                button: nil, clickCount: nil)),
            .browserType(.init(ref: nil, selector: "#name", text: "agent text",
                               slowly: true, submit: false)),
            .browserPressKey(.init(key: "Tab", ref: nil, selector: nil,
                                  shift: nil, control: nil, option: nil, command: nil)),
        ]
        for action in actions {
            let result = await fixture.call(action)
            XCTAssertFalse(result.isError, result.text)
            fixture.assertComposerFocus()
        }
        let value = try await browser.evaluate("document.querySelector('#name').value") as? String
        XCTAssertEqual(value, "agent text")
        let focused = try await browser.evaluate("document.activeElement.id") as? String
        XCTAssertEqual(focused, "next", "Agent Tab still moves focus within the page")
        fixture.typeInComposer()
    }

    @MainActor
    private final class Fixture {
        let sessionID = SessionID()
        let pane = DisplayPaneController(browserFactory: { _, _ in
            BrowserViewController(websiteDataStore: .nonPersistent())
        })
        let composer = PromptView()
        let window = BrowserFocusKeyPanel(
            contentRect: NSRect(x: 120, y: 120, width: 800, height: 500),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        let server: BrowserLoopbackHTTPServer
        var editor: NSResponder?
        lazy var coordinator = AgentToolCoordinator(
            displayPaneController: pane,
            visibleSessionID: { [weak self] in self?.sessionID },
            setPaneVisible: { _ in },
            windowProvider: { [weak self] in self?.window }
        )

        init() throws {
            server = try BrowserLoopbackHTTPServer(pages: [
                "/focus": """
                    <!doctype html><title>Focus fixture</title>
                    <label>Name <input id="name"></label><button id="next">Next</button>
                    """
            ])
            let root = NSViewController()
            root.view = NSView()
            root.addChild(pane)
            root.view.addSubview(pane.view)
            root.view.addSubview(composer)
            pane.view.translatesAutoresizingMaskIntoConstraints = false
            composer.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                composer.leadingAnchor.constraint(equalTo: root.view.leadingAnchor, constant: 12),
                composer.bottomAnchor.constraint(equalTo: root.view.bottomAnchor, constant: -12),
                composer.widthAnchor.constraint(equalToConstant: 300),
                pane.view.leadingAnchor.constraint(equalTo: composer.trailingAnchor, constant: 12),
                pane.view.trailingAnchor.constraint(equalTo: root.view.trailingAnchor),
                pane.view.topAnchor.constraint(equalTo: root.view.topAnchor),
                pane.view.bottomAnchor.constraint(equalTo: root.view.bottomAnchor),
            ])
            pane.showSessionTabs(sessionID)
            window.isReleasedWhenClosed = false
            window.animationBehavior = .none
            window.contentViewController = root
            window.makeKeyAndOrderFront(nil)
            root.view.layoutSubtreeIfNeeded()
            let deadline = Date().addingTimeInterval(2)
            while !window.isKeyWindow, Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            guard window.isKeyWindow else {
                tearDown()
                throw XCTSkip("The test host could not obtain a key window")
            }
            composer.stringValue = "draft"
            focusComposer()
        }

        func focusComposer() {
            composer.focusAtEnd()
            editor = window.firstResponder
            XCTAssertTrue((editor as? NSView)?.isDescendant(of: composer) == true)
            window.focusChanges.removeAll()
        }

        func navigate() async {
            let result = await call(.browserNavigate(.init(
                url: server.url(host: "localhost", path: "/focus").absoluteString
            )))
            XCTAssertFalse(result.isError, result.text)
        }

        func call(_ tool: MCPToolCall) async -> MCPToolResult {
            await withCheckedContinuation { continuation in
                coordinator.handle(tool, for: sessionID) { continuation.resume(returning: $0) }
            }
        }

        func assertComposerFocus(file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertTrue(window.isKeyWindow, file: file, line: line)
            XCTAssertTrue(window.firstResponder === editor,
                          "Native focus moved to \(String(describing: window.firstResponder))",
                          file: file, line: line)
            XCTAssertTrue(window.focusChanges.allSatisfy { $0 === editor },
                          "Focus must stay in the composer throughout the operation", file: file, line: line)
        }

        func typeInComposer() {
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "x",
                charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7
            )!
            NSApp.sendEvent(event)
            XCTAssertEqual(composer.stringValue, "draftx", "Physical keyboard input still reaches the draft")
        }

        func tearDown() {
            window.makeFirstResponder(nil)
            window.orderOut(nil)
            window.contentViewController = nil
            for tab in pane.tabs(for: sessionID) { _ = pane.closeTab(id: tab.id, for: sessionID) }
            server.stop()
        }
    }
}

private final class BrowserFocusKeyPanel: NSPanel {
    var focusChanges: [NSResponder?] = []
    override var canBecomeKey: Bool { true }

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        guard BrowserKeyboardFocus.allows(responder, in: self) else { return false }
        let accepted = super.makeFirstResponder(responder)
        if accepted { focusChanges.append(firstResponder) }
        return accepted
    }
}

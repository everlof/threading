import AppKit
import WebKit
import XCTest
@testable import Threading

final class BrowserAgentFrameValueTests: XCTestCase {
    func testOnlyAFrameRefNamesAFrame() {
        XCTAssertEqual(BrowserAgentFrameRef.frameID(of: "f12e3"), 12)
        XCTAssertNil(BrowserAgentFrameRef.frameID(of: "e3"))
        XCTAssertNil(BrowserAgentFrameRef.frameID(of: nil))
        XCTAssertNil(BrowserAgentFrameRef.frameID(of: ""))
        XCTAssertNil(BrowserAgentFrameRef.frameID(of: "f12"))
        XCTAssertNil(BrowserAgentFrameRef.frameID(of: "fe3"))
        XCTAssertNil(BrowserAgentFrameRef.frameID(of: "f1e"))
        XCTAssertNil(BrowserAgentFrameRef.frameID(of: "f1ex"))
        XCTAssertNil(BrowserAgentFrameRef.frameID(of: "footer"))
    }

    func testPlacementStatesAFramesCoordinatesInThePagesTerms() {
        let placement = BrowserFramePlacement(
            x: 400, y: 40, scaleX: 2, scaleY: 0.5,
            clip: CGRect(x: 400, y: 40, width: 360, height: 480),
            covered: false
        )
        XCTAssertEqual(
            placement.project(BrowserSnapshot.Node.Box(x: 10, y: 20, width: 30, height: 40)),
            BrowserSnapshot.Node.Box(x: 420, y: 50, width: 60, height: 20)
        )
    }

    func testANestedPlacementComposesThroughItsParent() {
        let outer = BrowserFramePlacement(
            x: 100, y: 200, scaleX: 2, scaleY: 2,
            clip: CGRect(x: 100, y: 200, width: 400, height: 400),
            covered: false
        )
        let inner = BrowserFramePlacement(
            x: 10, y: 20, scaleX: 0.5, scaleY: 0.5,
            clip: CGRect(x: 10, y: 20, width: 1_000, height: 50),
            covered: true
        )
        let composed = outer.composing(inner)
        XCTAssertEqual(composed.x, 120)
        XCTAssertEqual(composed.y, 240)
        XCTAssertEqual(composed.scaleX, 1)
        XCTAssertEqual(composed.scaleY, 1)
        XCTAssertEqual(composed.clip, CGRect(x: 120, y: 240, width: 380, height: 100))
        XCTAssertTrue(composed.covered, "A frame covered anywhere in its chain receives no events")
    }

    func testACaptureClippedByTheFrameSaysSo() {
        let placement = BrowserFramePlacement(
            x: 100, y: 100, scaleX: 1, scaleY: 1,
            clip: CGRect(x: 100, y: 100, width: 50, height: 50),
            covered: false
        )
        let inside = placement.project(BrowserScreenshotTarget(
            ok: true, message: "", x: 10, y: 10, width: 20, height: 20, clipped: false
        ))
        XCTAssertEqual(inside.x, 110)
        XCTAssertEqual(inside.width, 20)
        XCTAssertFalse(inside.clipped)

        let cut = placement.project(BrowserScreenshotTarget(
            ok: true, message: "", x: 40, y: 10, width: 20, height: 20, clipped: false
        ))
        XCTAssertEqual(cut.width, 10)
        XCTAssertTrue(cut.clipped)

        let outside = placement.project(BrowserScreenshotTarget(
            ok: true, message: "", x: 80, y: 10, width: 20, height: 20, clipped: false
        ))
        XCTAssertFalse(outside.ok)
    }

    @MainActor
    func testThePromptNamesTheFrameAndThePageHoldingIt() throws {
        let url = try XCTUnwrap(URL(string: "https://widget.example/chat"))
        let request = AgentToolCoordinator.browserAccessChoiceRequest(
            to: url,
            origin: try XCTUnwrap(BrowserOrigin(url: url)),
            purpose: "read the frame at",
            embeddedIn: try XCTUnwrap(BrowserOrigin(url: try XCTUnwrap(URL(string: "https://shop.example/"))))
        )
        XCTAssertTrue(request.title.contains("widget.example"), request.title)
        XCTAssertTrue(request.message.contains("https://widget.example/chat"), request.message)
        XCTAssertTrue(request.message.contains("shop.example"), request.message)

        let page = AgentToolCoordinator.browserAccessChoiceRequest(
            to: url,
            origin: try XCTUnwrap(BrowserOrigin(url: url)),
            purpose: "read"
        )
        XCTAssertFalse(page.message.contains("shop.example"), page.message)
    }

    func testOnlyASnapshotHoldingAnOpaqueFrameExplainsThem() throws {
        func snapshot(states: [String]) -> BrowserSnapshot {
            BrowserSnapshot(
                url: "https://example.test/",
                title: "Fixture",
                viewport: .init(
                    width: 100, height: 100, scrollX: 0, scrollY: 0,
                    documentWidth: 100, documentHeight: 100
                ),
                nodes: [.init(depth: 0, role: "document", name: nil, ref: "e1", states: states, box: nil)],
                truncated: false,
                visitedElements: 1,
                truncationReason: nil,
                scope: nil,
                scopeError: nil,
                isPopup: false
            )
        }
        XCTAssertTrue(snapshot(states: ["frame=opaque"]).agentText.contains("browser_snapshot with a frame's ref"))
        XCTAssertFalse(snapshot(states: ["frame=same-origin"]).agentText.contains("browser_snapshot with a frame's ref"))
    }
}

/// Everything here drives the real tool coordinator against two loopback origins, which differ by
/// port. What a frame actually received is reported by the frame itself over the page's own
/// `postMessage`, and read from the top page in its own world: it has to be evidence that does not
/// pass through the machinery being tested.
///
/// The window is borderless and parked, so WebKit treats it as real and nothing reaches a display.
@MainActor
final class BrowserAgentFrameTests: HostedStoreTestCase {
    func testASnapshotShowsTheFrameWithARefAndAsksNothing() async throws {
        let fixture = try await FrameFixture(path: "/host")
        defer { fixture.tearDown() }

        let snapshot = await fixture.call(.browserSnapshot(.init(maximumNodes: nil, ref: nil, selector: nil)))
        XCTAssertFalse(snapshot.isError, snapshot.text)
        XCTAssertTrue(snapshot.text.contains("frame=opaque"), snapshot.text)
        XCTAssertTrue(snapshot.text.contains("src-origin=\(fixture.widgetOrigin)"), snapshot.text)
        XCTAssertNotNil(FrameFixture.ref(of: "document \"Support Widget\"", in: snapshot.text), snapshot.text)
        XCTAssertFalse(snapshot.text.contains("Send it"), "A frame's content needs its own grant")
        XCTAssertFalse(fixture.wasAsked(about: fixture.widgetOrigin))
        let events = try await fixture.events(named: "saw-message")
        XCTAssertTrue(events.isEmpty, "An ordinary snapshot must not touch the frame: \(events)")
    }

    func testScopingToTheFrameAsksForItsOriginAndReadsInside() async throws {
        let fixture = try await FrameFixture(path: "/host")
        defer { fixture.tearDown() }

        let inner = try await fixture.enterWidget()
        XCTAssertTrue(inner.contains("Frame: f1"), inner)
        XCTAssertTrue(inner.contains("Send it"), inner)
        XCTAssertEqual(fixture.purposes(for: fixture.widgetOrigin).first, "read the frame at")
        let send = try XCTUnwrap(FrameFixture.ref(of: "button \"Send it\"", in: inner), inner)
        XCTAssertTrue(send.hasPrefix("f1e"), send)
        // The frame sits at (400, 40) with a 1px border and the button at (20, 60) inside it.
        XCTAssertTrue(inner.contains("[box=421,101,200,60]"), inner)
    }

    func testASelectorScopeLandingOnTheFrameEntersItToo() async throws {
        let fixture = try await FrameFixture(path: "/host")
        defer { fixture.tearDown() }

        let inner = await fixture.call(.browserSnapshot(.init(
            maximumNodes: nil, ref: nil, selector: "iframe#chat"
        )))
        XCTAssertFalse(inner.isError, inner.text)
        XCTAssertTrue(inner.text.contains("Send it"), inner.text)
    }

    func testRefusingTheOriginReachesNothing() async throws {
        let fixture = try await FrameFixture(path: "/host")
        defer { fixture.tearDown() }
        fixture.deniedOrigins = [fixture.widgetOrigin]

        let frameRef = try await fixture.widgetFrameRef()
        let read = await fixture.call(.browserSnapshot(.init(maximumNodes: nil, ref: frameRef, selector: nil)))
        XCTAssertTrue(read.isError)
        XCTAssertTrue(read.text.contains("did not allow"), read.text)
        XCTAssertFalse(read.text.contains("Send it"), read.text)

        let click = await fixture.call(.browserClick(.init(
            ref: nil, selector: nil, x: 521, y: 131, button: nil, clickCount: nil
        )))
        XCTAssertTrue(click.isError)
        XCTAssertTrue(click.text.contains("did not allow"), click.text)

        let key = await fixture.call(.browserPressKey(.init(
            key: "a", ref: frameRef, selector: nil, shift: nil, control: nil, option: nil, command: nil
        )))
        XCTAssertTrue(key.isError)
        XCTAssertTrue(key.text.contains("did not allow"), key.text)

        let scroll = await fixture.call(.browserScroll(.init(
            direction: "down", amount: 200, ref: frameRef, selector: nil
        )))
        XCTAssertTrue(scroll.isError)
        XCTAssertTrue(scroll.text.contains("did not allow"), scroll.text)

        for name in ["pointerdown", "click", "keydown", "input"] {
            let events = try await fixture.events(named: name)
            XCTAssertTrue(events.isEmpty, "\(name) reached a frame the user refused: \(events)")
        }
    }

    /// The false success this replaced: every one of these used to report that it had happened.
    func testAnActionAimedAtTheFrameElementRefusesInsteadOfClaimingSuccess() async throws {
        let fixture = try await FrameFixture(path: "/host")
        defer { fixture.tearDown() }
        let frameRef = try await fixture.widgetFrameRef()

        let click = await fixture.call(.browserClick(.init(
            ref: frameRef, selector: nil, x: nil, y: nil, button: nil, clickCount: nil
        )))
        XCTAssertTrue(click.isError, click.text)
        XCTAssertTrue(click.text.contains("would not reach"), click.text)

        let hover = await fixture.call(.browserHover(.init(ref: frameRef, selector: nil)))
        XCTAssertTrue(hover.isError, hover.text)
        XCTAssertTrue(hover.text.contains("would not reach"), hover.text)

        let type = await fixture.call(.browserType(.init(
            ref: frameRef, selector: nil, text: "hej", slowly: nil, submit: nil
        )))
        XCTAssertTrue(type.isError, type.text)
        XCTAssertTrue(type.text.contains("would not reach"), type.text)

        let wholeFrame = try await fixture.allEvents()
        XCTAssertEqual(wholeFrame.filter { $0.name != "ready" }.count, 0, "\(wholeFrame)")
    }

    func testRefsActInsideTheFrame() async throws {
        let fixture = try await FrameFixture(path: "/host")
        defer { fixture.tearDown() }
        let inner = try await fixture.enterWidget()

        let send = try XCTUnwrap(FrameFixture.ref(of: "button \"Send it\"", in: inner), inner)
        let click = await fixture.call(.browserClick(.init(
            ref: send, selector: nil, x: nil, y: nil, button: nil, clickCount: nil
        )))
        XCTAssertFalse(click.isError, click.text)
        XCTAssertTrue(click.text.contains("Clicked inside"), "The result shows the frame: \(click.text)")
        XCTAssertTrue(click.text.contains("Frame: f1"), click.text)
        let clicks = try await fixture.events(named: "click")
        XCTAssertEqual(clicks.map(\.detail), ["send"])

        let reply = try XCTUnwrap(FrameFixture.ref(of: "textbox \"Write a reply\"", in: inner), inner)
        let type = await fixture.call(.browserType(.init(
            ref: reply, selector: nil, text: "hej från agenten", slowly: nil, submit: nil
        )))
        XCTAssertFalse(type.isError, type.text)
        XCTAssertTrue(type.text.contains("value=hej från agenten"), type.text)
        let inputs = try await fixture.events(named: "input")
        XCTAssertEqual(inputs.map(\.detail), ["reply"])
    }

    func testACoordinateClickCrossesIntoTheFrame() async throws {
        let fixture = try await FrameFixture(path: "/host")
        defer { fixture.tearDown() }

        let click = await fixture.call(.browserClick(.init(
            ref: nil, selector: nil, x: 521, y: 131, button: nil, clickCount: nil
        )))
        XCTAssertFalse(click.isError, click.text)
        XCTAssertTrue(click.text.contains("Clicked button \"Send it\" at (521, 131)"), click.text)
        XCTAssertEqual(fixture.purposes(for: fixture.widgetOrigin).first, "interact with the frame at")
        let clicks = try await fixture.events(named: "click")
        XCTAssertEqual(clicks.map(\.detail), ["send"])
    }

    func testAKeyFollowsFocusIntoTheFrame() async throws {
        let fixture = try await FrameFixture(path: "/host")
        defer { fixture.tearDown() }
        let inner = try await fixture.enterWidget()
        let reply = try XCTUnwrap(FrameFixture.ref(of: "textbox \"Write a reply\"", in: inner), inner)
        let focus = await fixture.call(.browserClick(.init(
            ref: reply, selector: nil, x: nil, y: nil, button: nil, clickCount: nil
        )))
        XCTAssertFalse(focus.isError, focus.text)

        let key = await fixture.call(.browserPressKey(.init(
            key: "a", ref: nil, selector: nil, shift: nil, control: nil, option: nil, command: nil
        )))
        XCTAssertFalse(key.isError, key.text)
        XCTAssertTrue(key.text.contains("Pressed a"), key.text)
        let keys = try await fixture.events(named: "keydown")
        XCTAssertEqual(keys.map(\.detail), ["reply"], "The key belongs to the focused field inside")
    }

    func testScrollingTheFrameMovesItsDocumentAndSaysWhenNothingMoved() async throws {
        let fixture = try await FrameFixture(path: "/host")
        defer { fixture.tearDown() }
        let frameRef = try await fixture.widgetFrameRef()

        let down = await fixture.call(.browserScroll(.init(
            direction: "down", amount: 300, ref: frameRef, selector: nil
        )))
        XCTAssertFalse(down.isError, down.text)
        XCTAssertTrue(down.text.hasPrefix("Scrolled down"), down.text)
        XCTAssertTrue(down.text.contains("at (0, 300)"), "Viewport of the frame: \(down.text)")

        let up = await fixture.call(.browserScroll(.init(
            direction: "up", amount: 300, ref: frameRef, selector: nil
        )))
        XCTAssertTrue(up.text.hasPrefix("Scrolled up"), up.text)
        let limit = await fixture.call(.browserScroll(.init(
            direction: "up", amount: 300, ref: frameRef, selector: nil
        )))
        XCTAssertFalse(limit.isError, limit.text)
        XCTAssertTrue(limit.text.hasPrefix("Nothing scrolled"), limit.text)
    }

    /// Widgets commonly keep their document still and scroll an inner list, which has no ref.
    func testScrollFindsTheInnerScrollerOfAnApplicationShell() async throws {
        let fixture = try await FrameFixture(path: "/shell-host")
        defer { fixture.tearDown() }
        let frameRef = try await fixture.widgetFrameRef()

        let down = await fixture.call(.browserScroll(.init(
            direction: "down", amount: 300, ref: frameRef, selector: nil
        )))
        XCTAssertFalse(down.isError, down.text)
        XCTAssertTrue(down.text.hasPrefix("Scrolled down"), down.text)
        let scrolled = try await fixture.events(named: "list-scroll")
        XCTAssertFalse(scrolled.isEmpty, "The shell's own list has to move")
    }

    func testAWaitLooksInsideEnteredFramesAndSaysWhatItDidNotSearch() async throws {
        let fixture = try await FrameFixture(path: "/host")
        defer { fixture.tearDown() }

        let before = await fixture.call(.browserWait(.init(
            time: nil, text: "Widget ready", textGone: nil, urlContains: nil,
            ref: nil, selector: nil, state: nil, timeout: 0.4
        )))
        XCTAssertTrue(before.isError, before.text)
        XCTAssertTrue(before.text.contains("frames from another origin"), before.text)

        _ = try await fixture.enterWidget()
        let after = await fixture.call(.browserWait(.init(
            time: nil, text: "Widget ready", textGone: nil, urlContains: nil,
            ref: nil, selector: nil, state: nil, timeout: 2
        )))
        XCTAssertFalse(after.isError, after.text)
        XCTAssertTrue(after.text.contains("Frame: f1"), "The result shows where it was found: \(after.text)")
    }

    /// A ref outlives the answer that produced it, so the answer is asked for again on every use.
    func testRevokingAccessStopsARefAlreadyIssued() async throws {
        let fixture = try await FrameFixture(path: "/host")
        defer { fixture.tearDown() }
        let inner = try await fixture.enterWidget()
        let send = try XCTUnwrap(FrameFixture.ref(of: "button \"Send it\"", in: inner), inner)

        fixture.deniedOrigins = [fixture.widgetOrigin]
        let click = await fixture.call(.browserClick(.init(
            ref: send, selector: nil, x: nil, y: nil, button: nil, clickCount: nil
        )))
        XCTAssertTrue(click.isError, click.text)
        XCTAssertTrue(click.text.contains("did not allow"), click.text)
        let clicks = try await fixture.events(named: "click")
        XCTAssertTrue(clicks.isEmpty, "\(clicks)")

        let read = await fixture.call(.browserSnapshot(.init(maximumNodes: nil, ref: send, selector: nil)))
        XCTAssertTrue(read.isError, read.text)
        XCTAssertFalse(read.text.contains("Send it"), read.text)
    }

    /// Guarantee 4: the browser is shared, and the user can navigate it while the sheet is up.
    func testThePageChangingUnderAnOpenPromptIsRefused() async throws {
        let fixture = try await FrameFixture(path: "/host")
        defer { fixture.tearDown() }
        let frameRef = try await fixture.widgetFrameRef()
        let browser = try fixture.browser
        let elsewhere = fixture.host.url(host: "127.0.0.1", path: "/same-origin").absoluteString
        let widgetOrigin = fixture.widgetOrigin
        fixture.onAsked = { origin, decide in
            guard origin == widgetOrigin else { return false }
            Task { @MainActor in
                _ = try? await browser.evaluate(
                    "location.href = \(BrowserAgentScripts.jsLiteral(elsewhere)); true;"
                )
                let deadline = Date().addingTimeInterval(5)
                while browser.currentURL?.absoluteString != elsewhere, Date() < deadline {
                    try? await Task.sleep(nanoseconds: 20_000_000)
                }
                decide(.allowOnce)
            }
            return true
        }

        let read = await fixture.call(.browserSnapshot(.init(maximumNodes: nil, ref: frameRef, selector: nil)))
        XCTAssertTrue(read.isError, read.text)
        XCTAssertFalse(read.text.contains("Send it"), read.text)
    }

    func testACoveredFrameRefusesAnActionInsteadOfClaimingIt() async throws {
        let fixture = try await FrameFixture(path: "/covered")
        defer { fixture.tearDown() }
        let inner = try await fixture.enterWidget()
        let send = try XCTUnwrap(FrameFixture.ref(of: "button \"Send it\"", in: inner), inner)

        let click = await fixture.call(.browserClick(.init(
            ref: send, selector: nil, x: nil, y: nil, button: nil, clickCount: nil
        )))
        XCTAssertTrue(click.isError, click.text)
        XCTAssertTrue(click.text.contains("cover"), click.text)
        let clicks = try await fixture.events(named: "click")
        XCTAssertTrue(clicks.isEmpty, "\(clicks)")
    }

    /// A reveal inside a frame stops at the frame, so the page has to be scrolled from outside.
    func testActingInAFrameBelowTheFoldRevealsIt() async throws {
        let fixture = try await FrameFixture(path: "/below-fold")
        defer { fixture.tearDown() }
        let inner = try await fixture.enterWidget()
        let send = try XCTUnwrap(FrameFixture.ref(of: "button \"Send it\"", in: inner), inner)
        let before = try await fixture.browser.evaluate("window.scrollY") as? Double
        XCTAssertEqual(before, 0)

        let click = await fixture.call(.browserClick(.init(
            ref: send, selector: nil, x: nil, y: nil, button: nil, clickCount: nil
        )))
        XCTAssertFalse(click.isError, click.text)
        let after = try await fixture.browser.evaluate("window.scrollY") as? Double
        XCTAssertGreaterThan(after ?? 0, 0, "The frame has to be on screen when it is acted in")
    }

    func testABatchSpanningDocumentsChangesNothing() async throws {
        let fixture = try await FrameFixture(path: "/host")
        defer { fixture.tearDown() }
        let inner = try await fixture.enterWidget()
        let reply = try XCTUnwrap(FrameFixture.ref(of: "textbox \"Write a reply\"", in: inner), inner)

        let fill = await fixture.call(.browserFillForm(.init(fields: [
            .init(ref: nil, selector: "#host-field", value: "here", label: nil, checked: nil),
            .init(ref: reply, selector: nil, value: "there", label: nil, checked: nil)
        ])))
        XCTAssertTrue(fill.isError, fill.text)
        XCTAssertTrue(fill.text.contains("same frame"), fill.text)
        let inputs = try await fixture.events(named: "input")
        XCTAssertTrue(inputs.isEmpty, "\(inputs)")
        let hostValue = try await fixture.browser.evaluate(
            "document.getElementById('host-field').value"
        ) as? String
        XCTAssertEqual(hostValue, "")
    }

    /// A payment frame exists to keep these from its embedder, and a grant must not undo that for
    /// text an agent gets back.
    func testACardFieldsValueIsNotReturned() async throws {
        let fixture = try await FrameFixture(path: "/host")
        defer { fixture.tearDown() }
        let inner = try await fixture.enterWidget()
        XCTAssertTrue(inner.contains("textbox \"Card number\""), inner)
        XCTAssertFalse(inner.contains("4242424242424242"), inner)
        XCTAssertTrue(inner.contains("value=[redacted]"), inner)
    }

    func testASandboxThatRunsScriptsIsAskedAboutByItsURL() async throws {
        let fixture = try await FrameFixture(path: "/sandboxed-scripts")
        defer { fixture.tearDown() }

        let inner = try await fixture.enterWidget()
        XCTAssertTrue(inner.contains("Send it"), inner)
        XCTAssertTrue(fixture.wasAsked(about: fixture.widgetOrigin))
    }

    func testAQuerySaysWhichFramesItDidNotSearch() async throws {
        let fixture = try await FrameFixture(path: "/host")
        defer { fixture.tearDown() }

        let query = await fixture.call(.browserQuery(.init(selector: "#send")))
        XCTAssertFalse(query.isError, query.text)
        XCTAssertTrue(query.text.contains("\"opaque_frames_not_searched\": 1"), query.text)
    }

    func testASelectorThatMissesSaysFramesWereNotSearched() async throws {
        let fixture = try await FrameFixture(path: "/host")
        defer { fixture.tearDown() }

        let click = await fixture.call(.browserClick(.init(
            ref: nil, selector: "#send", x: nil, y: nil, button: nil, clickCount: nil
        )))
        XCTAssertTrue(click.isError)
        XCTAssertTrue(click.text.contains("1 frame from another origin"), click.text)
    }

    /// `WKFrameInfo` names the frame, not its document, so a handle kept across a navigation runs
    /// in whatever loaded next. A grant for one origin must not be spent on its replacement.
    func testAFrameThatNavigatedCannotSpendItsOldGrant() async throws {
        let fixture = try await FrameFixture(path: "/host")
        defer { fixture.tearDown() }
        let inner = try await fixture.enterWidget()
        let send = try XCTUnwrap(FrameFixture.ref(of: "button \"Send it\"", in: inner), inner)

        fixture.deniedOrigins = [fixture.thirdOrigin]
        try await fixture.navigateFrame(to: fixture.third.url(host: "127.0.0.1", path: "/leaf"))

        let click = await fixture.call(.browserClick(.init(
            ref: send, selector: nil, x: nil, y: nil, button: nil, clickCount: nil
        )))
        XCTAssertTrue(click.isError, click.text)
        XCTAssertTrue(click.text.contains("take a new snapshot"), click.text)
        let clicks = try await fixture.events(named: "click")
        XCTAssertTrue(clicks.isEmpty, "\(clicks)")

        let frameRef = try await fixture.widgetFrameRef()
        let reentry = await fixture.call(.browserSnapshot(.init(maximumNodes: nil, ref: frameRef, selector: nil)))
        XCTAssertTrue(reentry.isError, "The new origin gets its own question: \(reentry.text)")
        XCTAssertTrue(fixture.wasAsked(about: fixture.thirdOrigin))
        XCTAssertFalse(reentry.text.contains("Leaf content"), reentry.text)
    }

    func testAReenteredFrameKeepsItsIdWhileItsDocumentIsTheSame() async throws {
        let fixture = try await FrameFixture(path: "/host")
        defer { fixture.tearDown() }
        let first = try await fixture.enterWidget()
        let second = try await fixture.enterWidget()
        XCTAssertEqual(
            FrameFixture.ref(of: "button \"Send it\"", in: first),
            FrameFixture.ref(of: "button \"Send it\"", in: second),
            "Reading a frame twice must not invalidate the refs from the first read"
        )
    }

    func testTheProbeNeverReachesThePage() async throws {
        let fixture = try await FrameFixture(path: "/host")
        defer { fixture.tearDown() }

        _ = try await fixture.enterWidget()
        let seen = try await fixture.events(named: "saw-message")
        XCTAssertTrue(seen.isEmpty, "The page saw a probe: \(seen)")

        // The same listener does see an ordinary message, or the assertion above proves nothing.
        _ = try await fixture.browser.evaluate(
            "document.getElementById('chat').contentWindow.postMessage({ hello: 1 }, '*'); true;"
        )
        let control = try await fixture.waitForEvent(named: "saw-message")
        XCTAssertTrue(control.detail.contains("hello"), control.detail)
    }

    func testAFrameInsideAShadowRootCanBeEntered() async throws {
        let fixture = try await FrameFixture(path: "/shadow")
        defer { fixture.tearDown() }

        let inner = try await fixture.enterWidget()
        XCTAssertTrue(inner.contains("Send it"), inner)
    }

    func testAFrameInsideAFrameComposesAndCrosses() async throws {
        let fixture = try await FrameFixture(path: "/nested")
        defer { fixture.tearDown() }

        let outer = try await fixture.enterWidget()
        let innerRef = try XCTUnwrap(FrameFixture.ref(of: "document \"Leaf\"", in: outer), outer)
        XCTAssertTrue(innerRef.hasPrefix("f1e"), innerRef)

        let leaf = await fixture.call(.browserSnapshot(.init(maximumNodes: nil, ref: innerRef, selector: nil)))
        XCTAssertFalse(leaf.isError, leaf.text)
        XCTAssertTrue(leaf.text.contains("Leaf content"), leaf.text)
        XCTAssertTrue(fixture.wasAsked(about: fixture.thirdOrigin))
        // (400, 40) + 1px border, then (10, 10) in the middle frame + 1px border, then (5, 5).
        XCTAssertTrue(leaf.text.contains("[box=417,57,100,30]"), leaf.text)

        let button = try XCTUnwrap(FrameFixture.ref(of: "button \"Leaf button\"", in: leaf.text), leaf.text)
        XCTAssertTrue(button.hasPrefix("f2e"), button)
        let click = await fixture.call(.browserClick(.init(
            ref: button, selector: nil, x: nil, y: nil, button: nil, clickCount: nil
        )))
        XCTAssertFalse(click.isError, click.text)
        let clicks = try await fixture.events(named: "click")
        XCTAssertEqual(clicks.map(\.detail), ["leaf-button"])

        let viaPoint = await fixture.call(.browserClick(.init(
            ref: nil, selector: nil, x: 450, y: 70, button: nil, clickCount: nil
        )))
        XCTAssertFalse(viaPoint.isError, viaPoint.text)
        XCTAssertTrue(viaPoint.text.contains("Clicked button \"Leaf button\" at (450, 70)"), viaPoint.text)
    }

    func testASandboxedSrcdocHasNoOriginToAskAbout() async throws {
        let fixture = try await FrameFixture(path: "/sandboxed-srcdoc", awaitsReady: false)
        defer { fixture.tearDown() }

        let snapshot = await fixture.call(.browserSnapshot(.init(maximumNodes: nil, ref: nil, selector: nil)))
        let frameRef = try XCTUnwrap(FrameFixture.ref(of: "document \"Sandboxed\"", in: snapshot.text), snapshot.text)
        let read = await fixture.call(.browserSnapshot(.init(maximumNodes: nil, ref: frameRef, selector: nil)))
        XCTAssertTrue(read.isError, read.text)
        XCTAssertTrue(read.text.contains("no origin"), read.text)
        XCTAssertFalse(read.text.contains("Inside srcdoc"), read.text)
    }

    func testASandboxWithoutScriptsSaysItCannotBeEntered() async throws {
        let fixture = try await FrameFixture(path: "/sandboxed-no-scripts", awaitsReady: false)
        defer { fixture.tearDown() }

        let snapshot = await fixture.call(.browserSnapshot(.init(maximumNodes: nil, ref: nil, selector: nil)))
        let frameRef = try XCTUnwrap(FrameFixture.ref(of: "document \"No scripts\"", in: snapshot.text), snapshot.text)
        let read = await fixture.call(.browserSnapshot(.init(maximumNodes: nil, ref: frameRef, selector: nil)))
        XCTAssertTrue(read.isError, read.text)
        XCTAssertTrue(read.text.contains("did not answer"), read.text)
    }

    func testAPasswordInsideAFrameStaysWithTheUser() async throws {
        let fixture = try await FrameFixture(path: "/host")
        defer { fixture.tearDown() }
        let inner = try await fixture.enterWidget()
        let password = try XCTUnwrap(FrameFixture.ref(of: "textbox \"Widget password\"", in: inner), inner)

        let type = await fixture.call(.browserType(.init(
            ref: password, selector: nil, text: "hunter2", slowly: nil, submit: nil
        )))
        XCTAssertTrue(type.isError, type.text)
        XCTAssertTrue(type.text.contains("Password fields require user control"), type.text)
        let inputs = try await fixture.events(named: "input")
        XCTAssertTrue(inputs.isEmpty, "\(inputs)")
        XCTAssertGreaterThan(fixture.activations, 0, "The field is handed to the user")
    }

    func testStoredCredentialsNeverEnterAFrame() async throws {
        let fixture = try await FrameFixture(path: "/host")
        defer { fixture.tearDown() }
        let inner = try await fixture.enterWidget()
        let password = try XCTUnwrap(FrameFixture.ref(of: "textbox \"Widget password\"", in: inner), inner)

        let fill = await fixture.call(.browserFillCredentials(.init(
            account: nil, ref: password, selector: nil
        )))
        XCTAssertTrue(fill.isError, fill.text)
        XCTAssertTrue(fill.text.contains("inside a frame"), fill.text)
    }

    /// The browser-level guard is what holds when target inspection cannot predict a handler.
    func testAnUnapprovedSubmissionInsideAFrameIsBlocked() async throws {
        let fixture = try await FrameFixture(path: "/host")
        defer { fixture.tearDown() }
        let inner = try await fixture.enterWidget()
        let sneaky = try XCTUnwrap(FrameFixture.ref(of: "button \"Looks harmless\"", in: inner), inner)

        let click = await fixture.call(.browserClick(.init(
            ref: sneaky, selector: nil, x: nil, y: nil, button: nil, clickCount: nil
        )))
        XCTAssertTrue(click.isError, click.text)
        XCTAssertTrue(click.text.contains("blocked it"), click.text)
    }

    func testAnApprovalForASubmissionIsScopedToTheFramesOrigin() async throws {
        let fixture = try await FrameFixture(path: "/host")
        defer { fixture.tearDown() }
        let inner = try await fixture.enterWidget()
        let submit = try XCTUnwrap(FrameFixture.ref(of: "button \"Go\"", in: inner), inner)
        let origin = try XCTUnwrap(BrowserOrigin(url: fixture.widget.url(host: "127.0.0.1", path: "/")))
        // Remembering the frame's origin is what lets this through without a sheet. Had the prompt
        // been keyed on the page, this would have raised one and never returned.
        BrowserSubmissionExemptions.shared.exempt(origin, for: fixture.sessionID)

        let click = await fixture.call(.browserClick(.init(
            ref: submit, selector: nil, x: nil, y: nil, button: nil, clickCount: nil
        )))
        XCTAssertFalse(click.isError, click.text)
        let loaded = try await fixture.waitForEvent(named: "submitted-page")
        XCTAssertEqual(loaded.name, "submitted-page")
    }

    func testAnElementCaptureInAFrameUsesPageCoordinates() async throws {
        let fixture = try await FrameFixture(path: "/host")
        defer { fixture.tearDown() }
        let inner = try await fixture.enterWidget()
        let send = try XCTUnwrap(FrameFixture.ref(of: "button \"Send it\"", in: inner), inner)

        let capture = await fixture.call(.browserScreenshot(.init(
            fullPage: nil, ref: send, selector: nil, show: nil, includeImage: false
        )))
        XCTAssertFalse(capture.isError, capture.text)
        XCTAssertTrue(capture.text.contains("Captured 200×60"), capture.text)
    }

    func testANavigationOfThePageRetiresItsFrames() async throws {
        let fixture = try await FrameFixture(path: "/host")
        defer { fixture.tearDown() }
        let inner = try await fixture.enterWidget()
        let send = try XCTUnwrap(FrameFixture.ref(of: "button \"Send it\"", in: inner), inner)

        let navigated = await fixture.call(.browserNavigate(.init(
            url: fixture.host.url(host: "127.0.0.1", path: "/host").absoluteString
        )))
        XCTAssertFalse(navigated.isError, navigated.text)

        let click = await fixture.call(.browserClick(.init(
            ref: send, selector: nil, x: nil, y: nil, button: nil, clickCount: nil
        )))
        XCTAssertTrue(click.isError, click.text)
        XCTAssertTrue(click.text.contains("no longer on this page"), click.text)
    }

    /// Opt-in: `TEST_RUNNER_THREADING_BROWSER_FRAME_STRESS=1 scripts/test.sh fast -only-testing:…`.
    /// The contract is that a page's frame count costs an ordinary snapshot almost nothing and costs
    /// an entry nothing at all, because only the frame being entered is ever touched.
    func testStressAPageFullOfFramesWhenEnabled() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["THREADING_BROWSER_FRAME_STRESS"] == "1",
            "Set THREADING_BROWSER_FRAME_STRESS=1 to run the frame-count stress fixture."
        )
        let frameCount = 200
        let fixture = try await FrameFixture(path: "/stress", stressFrames: frameCount, awaitsReady: false)
        defer { fixture.tearDown() }
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            let ready = try await fixture.allEvents().filter { $0.name == "ready" }.count
            if ready >= frameCount { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        func median(_ samples: [TimeInterval]) -> Double {
            samples.sorted()[samples.count / 2] * 1_000
        }
        func timed(_ tool: MCPToolCall) async -> (TimeInterval, MCPToolResult) {
            let start = Date()
            let result = await fixture.call(tool)
            return (Date().timeIntervalSince(start), result)
        }

        var snapshots: [TimeInterval] = []
        var page = ""
        for _ in 0..<7 {
            let (elapsed, result) = await timed(.browserSnapshot(.init(maximumNodes: 400, ref: nil, selector: nil)))
            XCTAssertFalse(result.isError, result.text)
            snapshots.append(elapsed)
            page = result.text
        }
        let frameRef = try XCTUnwrap(FrameFixture.ref(of: "document \"Frame 100\"", in: page), page)

        let (firstEntry, entered) = await timed(.browserSnapshot(.init(maximumNodes: 400, ref: frameRef, selector: nil)))
        XCTAssertFalse(entered.isError, entered.text)
        XCTAssertTrue(entered.text.contains("Send it"), entered.text)
        let send = try XCTUnwrap(FrameFixture.ref(of: "button \"Send it\"", in: entered.text), entered.text)

        var reads: [TimeInterval] = []
        for _ in 0..<7 {
            let (elapsed, result) = await timed(.browserSnapshot(.init(maximumNodes: 400, ref: frameRef, selector: nil)))
            XCTAssertFalse(result.isError, result.text)
            reads.append(elapsed)
        }
        var clicks: [TimeInterval] = []
        for _ in 0..<7 {
            let (elapsed, result) = await timed(.browserClick(.init(
                ref: send, selector: nil, x: nil, y: nil, button: nil, clickCount: nil
            )))
            XCTAssertFalse(result.isError, result.text)
            clicks.append(elapsed)
        }
        let seen = try await fixture.events(named: "saw-message")
        XCTAssertTrue(seen.isEmpty, "\(seen.count) pages saw a probe")
        print("""
            frame-stress frames=\(frameCount) \
            snapshot-median-ms=\(median(snapshots)) snapshot-max-ms=\((snapshots.max() ?? 0) * 1_000) \
            first-entry-ms=\(firstEntry * 1_000) \
            reread-median-ms=\(median(reads)) click-median-ms=\(median(clicks))
            """)
    }

    func testSameOriginFramesAreStillFoldedInWithoutAnyQuestion() async throws {
        let fixture = try await FrameFixture(path: "/same-origin", awaitsReady: false)
        defer { fixture.tearDown() }
        let snapshot = await fixture.call(.browserSnapshot(.init(maximumNodes: nil, ref: nil, selector: nil)))
        XCTAssertTrue(snapshot.text.contains("Same-origin content"), snapshot.text)
        XCTAssertTrue(snapshot.text.contains("frame=same-origin"), snapshot.text)
        XCTAssertFalse(snapshot.text.contains("frame=opaque"), snapshot.text)
    }
}

// MARK: - Fixture

@MainActor
private final class FrameFixture {
    struct Event: Decodable, CustomStringConvertible {
        let name: String
        let detail: String
        var description: String { "\(name):\(detail)" }
    }

    struct EventTimeout: Error {
        let name: String
    }

    let sessionID = SessionID()
    let pane = DisplayPaneController(browserFactory: { _, _ in
        BrowserViewController(websiteDataStore: .nonPersistent())
    })
    let window = NSWindow(
        contentRect: NSRect(x: -10_000, y: -10_000, width: 1_000, height: 800),
        styleMask: [.borderless], backing: .buffered, defer: false
    )
    let third: BrowserLoopbackHTTPServer
    let widget: BrowserLoopbackHTTPServer
    let host: BrowserLoopbackHTTPServer
    var deniedOrigins: Set<String> = []
    var activations = 0
    /// Takes over one decision when it returns true, for a test that has to act during the prompt.
    var onAsked: ((String, @escaping (BrowserAccessDecision) -> Void) -> Bool)?
    private var asked: [(origin: String, purpose: String)] = []

    lazy var coordinator = AgentToolCoordinator(
        displayPaneController: pane,
        visibleSessionID: { [weak self] in self?.sessionID },
        setPaneVisible: { _ in },
        windowProvider: { [weak self] in self?.window },
        browserAccessDecisionProvider: { [weak self] origin, purpose, decide in
            guard let self else {
                decide(.deny)
                return
            }
            self.asked.append((origin.key, purpose))
            if self.onAsked?(origin.key, decide) == true { return }
            decide(self.deniedOrigins.contains(origin.key) ? .deny : .allowOnce)
        },
        activateApp: { [weak self] in self?.activations += 1 }
    )

    var widgetOrigin: String { Self.origin(of: widget) }
    var thirdOrigin: String { Self.origin(of: third) }

    var browser: BrowserViewController {
        get throws { try XCTUnwrap(pane.browser(for: sessionID)) }
    }

    init(path: String, stressFrames: Int = 0, awaitsReady: Bool = true) async throws {
        third = try BrowserLoopbackHTTPServer(pages: [
            "/leaf": Self.leafPage
        ])
        let thirdURL = third.url(host: "127.0.0.1", path: "/leaf").absoluteString
        widget = try BrowserLoopbackHTTPServer(pages: [
            "/widget": Self.widgetPage,
            "/shell": Self.shellPage,
            "/submitted": Self.page(title: "Submitted", body: "<p>Submitted</p>", ready: "submitted-page"),
            "/nesting": Self.page(
                title: "Nesting",
                body: """
                    <iframe title="Leaf" src="\(thirdURL)"
                      style="position:absolute;left:10px;top:10px;width:300px;height:200px;border:1px solid #888"></iframe>
                    """,
                ready: "ready"
            )
        ])
        let widgetURL = widget.url(host: "127.0.0.1", path: "/widget").absoluteString
        let shellURL = widget.url(host: "127.0.0.1", path: "/shell").absoluteString
        let nestingURL = widget.url(host: "127.0.0.1", path: "/nesting").absoluteString
        host = try BrowserLoopbackHTTPServer(pages: [
            "/host": Self.hostPage(frameSource: widgetURL),
            "/shell-host": Self.hostPage(frameSource: shellURL),
            "/nested": Self.hostPage(frameSource: nestingURL),
            "/shadow": Self.shadowHostPage(frameSource: widgetURL),
            "/stress": """
                <!doctype html><title>Many frames</title>
                \(Self.collector)
                \((0..<stressFrames).map { index in
                    "<iframe title=\"Frame \(index)\" src=\"\(widgetURL)\" style=\"width:120px;height:60px\"></iframe>"
                }.joined(separator: "\n"))
                """,
            "/covered": Self.hostPage(frameSource: widgetURL) + """
                <div style="position:fixed;inset:0;z-index:5"></div>
                """,
            "/below-fold": """
                <!doctype html><title>Below the fold</title>
                \(Self.collector)
                <style>body{margin:0;height:5000px}</style>
                <iframe id="chat" title="Support Widget" src="\(widgetURL)"
                  style="position:absolute;left:0;top:3000px;width:360px;height:480px"></iframe>
                """,
            "/sandboxed-scripts": """
                <!doctype html><title>Scripted sandbox</title>
                \(Self.collector)
                <iframe id="chat" title="Support Widget" sandbox="allow-scripts" src="\(widgetURL)"
                  style="width:360px;height:480px"></iframe>
                """,
            "/sandboxed-srcdoc": """
                <!doctype html><title>Sandboxed</title>
                <iframe title="Sandboxed" sandbox="allow-scripts"
                  srcdoc="<p>Inside srcdoc</p>" style="width:300px;height:200px"></iframe>
                """,
            "/sandboxed-no-scripts": """
                <!doctype html><title>No scripts</title>
                <iframe title="No scripts" sandbox="" src="\(widgetURL)"
                  style="width:300px;height:200px"></iframe>
                """,
            "/same-origin": """
                <!doctype html><title>Same origin</title>
                <iframe title="Same" srcdoc="<p>Same-origin content</p>"
                  style="width:300px;height:200px"></iframe>
                """
        ])

        let root = NSViewController()
        root.view = NSView()
        root.addChild(pane)
        root.view.addSubview(pane.view)
        pane.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            pane.view.leadingAnchor.constraint(equalTo: root.view.leadingAnchor),
            pane.view.trailingAnchor.constraint(equalTo: root.view.trailingAnchor),
            pane.view.topAnchor.constraint(equalTo: root.view.topAnchor),
            pane.view.bottomAnchor.constraint(equalTo: root.view.bottomAnchor)
        ])
        pane.showSessionTabs(sessionID)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentViewController = root
        window.setFrame(NSRect(x: -10_000, y: -10_000, width: 1_000, height: 800), display: false)
        window.orderFront(nil)
        root.view.layoutSubtreeIfNeeded()

        let navigated = await call(.browserNavigate(.init(
            url: host.url(host: "127.0.0.1", path: path).absoluteString
        )))
        XCTAssertFalse(navigated.isError, navigated.text)
        if awaitsReady {
            _ = try await waitForEvent(named: "ready")
        }
    }

    func call(_ tool: MCPToolCall) async -> MCPToolResult {
        await withCheckedContinuation { continuation in
            coordinator.handle(tool, for: sessionID) { continuation.resume(returning: $0) }
        }
    }

    func wasAsked(about origin: String) -> Bool {
        asked.contains { $0.origin == origin }
    }

    func purposes(for origin: String) -> [String] {
        asked.filter { $0.origin == origin }.map(\.purpose)
    }

    func widgetFrameRef() async throws -> String {
        let snapshot = await call(.browserSnapshot(.init(maximumNodes: nil, ref: nil, selector: nil)))
        return try XCTUnwrap(
            Self.ref(of: "document \"Support Widget\"", in: snapshot.text),
            snapshot.text
        )
    }

    func enterWidget() async throws -> String {
        let frameRef = try await widgetFrameRef()
        let inner = await call(.browserSnapshot(.init(maximumNodes: nil, ref: frameRef, selector: nil)))
        XCTAssertFalse(inner.isError, inner.text)
        return inner.text
    }

    func navigateFrame(to url: URL) async throws {
        let before = try await allEvents().count
        _ = try await browser.evaluate(
            "document.getElementById('chat').src = \(BrowserAgentScripts.jsLiteral(url.absoluteString)); true;"
        )
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if try await allEvents().count > before { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("The frame did not finish navigating")
    }

    func allEvents() async throws -> [Event] {
        let raw = try await browser.evaluate("JSON.stringify(window.__frameEvents || [])") as? String
        return try JSONDecoder().decode([Event].self, from: Data((raw ?? "[]").utf8))
    }

    func events(named name: String) async throws -> [Event] {
        // Reports travel by postMessage, so give any in flight a moment before reading an absence.
        try await Task.sleep(nanoseconds: 80_000_000)
        return try await allEvents().filter { $0.name == name }
    }

    func waitForEvent(named name: String) async throws -> Event {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let event = try await allEvents().first(where: { $0.name == name }) {
                return event
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw EventTimeout(name: name)
    }

    func tearDown() {
        window.orderOut(nil)
        window.contentViewController = nil
        for tab in pane.tabs(for: sessionID) { _ = pane.closeTab(id: tab.id, for: sessionID) }
        host.stop()
        widget.stop()
        third.stop()
        BrowserSubmissionExemptions.shared.revokeAll()
    }

    // MARK: Pages

    static func ref(of label: String, in text: String) -> String? {
        for line in text.split(separator: "\n") where line.contains(label) {
            guard let range = line.range(of: #"\[ref=[^\]]+\]"#, options: .regularExpression) else {
                continue
            }
            return String(line[range].dropFirst(5).dropLast())
        }
        return nil
    }

    private static func origin(of server: BrowserLoopbackHTTPServer) -> String {
        BrowserOrigin(url: server.url(host: "127.0.0.1", path: "/"))?.key ?? ""
    }

    /// What a framed page reports to the top page, in the page's own world.
    private static let reporter = """
        <script>
        const report = (name, detail = '') =>
          top.postMessage({ frameEvent: { name, detail: String(detail) } }, '*');
        for (const name of ['pointerdown', 'click', 'keydown', 'input']) {
          document.addEventListener(name, event => report(name, event.target.id), true);
        }
        addEventListener('message', event => report('saw-message', JSON.stringify(event.data)));
        </script>
        """

    private static func page(title: String, body: String, ready: String) -> String {
        """
        <!doctype html><title>\(title)</title>
        \(reporter)
        <style>html,body{margin:0}body{font:16px sans-serif}</style>
        \(body)
        <script>report('\(ready)');</script>
        """
    }

    private static let widgetPage = page(
        title: "Support widget",
        body: """
            <style>
              body { height: 2000px; }
              #send, #reply, #secret, form { position: absolute; left: 20px; }
              #send { top: 60px; width: 200px; height: 60px; }
              #reply { top: 140px; width: 300px; height: 80px; }
              #secret { top: 240px; }
              form { top: 280px; }
            </style>
            <p id="status">Widget ready</p>
            <button id="send">Send it</button>
            <textarea id="reply" aria-label="Write a reply"></textarea>
            <input id="secret" type="password" aria-label="Widget password">
            <input id="card" autocomplete="cc-number" aria-label="Card number" value="4242424242424242"
              style="position:absolute;left:20px;top:330px">
            <form id="form" action="/submitted">
              <input id="field" name="q" aria-label="Form field">
              <button id="go">Go</button>
              <button id="sneaky" type="button"
                onclick="document.getElementById('form').requestSubmit()">Looks harmless</button>
            </form>
            <script>
              document.getElementById('send').addEventListener('click', () => {
                document.getElementById('status').textContent = 'Clicked inside';
              });
            </script>
            """,
        ready: "ready"
    )

    private static let shellPage = page(
        title: "Shell",
        body: """
            <style>
              html, body { height: 100%; overflow: hidden; }
              #list { height: 100%; overflow: auto; }
              #content { height: 3000px; }
            </style>
            <div id="list"><div id="content">Messages</div></div>
            <script>
              document.getElementById('list').addEventListener('scroll', () => report('list-scroll'));
            </script>
            """,
        ready: "ready"
    )

    private static let leafPage = page(
        title: "Leaf",
        body: """
            <p>Leaf content</p>
            <button id="leaf-button"
              style="position:absolute;left:5px;top:5px;width:100px;height:30px">Leaf button</button>
            """,
        ready: "leaf-ready"
    )

    private static let collector = """
        <script>
        window.__frameEvents = [];
        addEventListener('message', event => {
          if (event.data && event.data.frameEvent) window.__frameEvents.push(event.data.frameEvent);
        });
        </script>
        """

    private static func hostPage(frameSource: String) -> String {
        """
        <!doctype html><title>Host page</title>
        \(collector)
        <style>body{margin:0}</style>
        <h1>Host page</h1>
        <input id="host-field" aria-label="Host field">
        <iframe id="chat" title="Support Widget" src="\(frameSource)"
          style="position:fixed;left:400px;top:40px;width:360px;height:480px;border:1px solid #888"></iframe>
        """
    }

    private static func shadowHostPage(frameSource: String) -> String {
        """
        <!doctype html><title>Shadow host</title>
        \(collector)
        <div id="host"></div>
        <script>
        const frame = document.createElement('iframe');
        frame.id = 'chat';
        frame.title = 'Support Widget';
        frame.src = \(BrowserAgentScripts.jsLiteral(frameSource));
        frame.style.cssText = 'width:360px;height:480px';
        document.getElementById('host').attachShadow({ mode: 'open' }).appendChild(frame);
        </script>
        """
    }
}

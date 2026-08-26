import AppKit
import Foundation
import ThreadingDomain
import ThreadingPTYHostKit
import XCTest

@testable import Threading

/// The surface a wedged detached agent is found on.
///
/// Everything else about a host-backed session is invisible by design — that is the feature — so
/// this list is the one place that says a child exists, how long it has been running, which
/// process it is, and the one place that can end it. The count comes from another process, so the
/// viewport is capped and the table owns only the rows inside it.
///
/// Nothing here needs a window: the fixture host is built, laid out and `cacheDisplay`ed.
///
/// `HostedStoreTestCase` because the inventory joins the daemon's answer to the app's own
/// conversations, which means reading `ProjectStore.shared` — the singleton a hosted test bundle
/// shares with the developer's running copy.
@MainActor
final class BackgroundSessionsListTests: HostedStoreTestCase {

    // MARK: - Constants

    private enum Fixture {
        static let width: CGFloat = 560
        static let height: CGFloat = 420
        /// One row taller than the list's own cap, so the bound is exercised rather than assumed.
        static let manySessions = 20
    }

    private enum Render {
        static var directory: URL {
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"],
               !override.isEmpty {
                return URL(fileURLWithPath: override)
            }
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
        }

        static let appearances: [(name: String, appearance: NSAppearance.Name)] = [
            ("light", .aqua),
            ("dark", .darkAqua)
        ]
    }

    // MARK: - The list

    /// A row per held session, and a viewport that stops growing.
    ///
    /// Six rows then it scrolls inside itself: the daemon is expected to hold about eight and is
    /// stress-tested at forty, and a settings card that grows to forty rows is a page nobody can
    /// reach the bottom of.
    func testTheViewportIsCappedWhileTheModelIsNot() {
        let list = makeList()
        let sessions = (0..<Fixture.manySessions).map { index in
            held(name: "Session \(index)")
        }

        list.show(state(sessions: sessions))

        XCTAssertEqual(list.sessionCountForTesting, Fixture.manySessions)
        XCTAssertFalse(list.showsEmptyStateForTesting)
        XCTAssertLessThan(
            list.viewportHeightForTesting,
            CGFloat(Fixture.manySessions) * 54,
            "the list is a bounded surface over an externally sized set"
        )
    }

    /// The list hands the wheel back at its own content ends, because the page below it is the
    /// scroller the user is actually driving.
    func testTheListDoesNotSwallowThePagesScrolling() {
        XCTAssertEqual(makeList().verticalScrollHandoffForTesting, .atContentEnds)
    }

    /// An empty list is not a blank panel: it carries the reason, which is the whole point of
    /// `PTYHostAvailability` having separate cases.
    func testTheEmptyStateCarriesTheReasonItIsEmpty() {
        let list = makeList()

        list.show(state(status: .unavailable(.disabled)))

        XCTAssertTrue(list.showsEmptyStateForTesting)
        XCTAssertEqual(
            list.emptyMessageForTesting,
            PTYHostBackgroundSessionsStatus.unavailable(.disabled).sentence
        )
        XCTAssertFalse(
            list.showsLoginItemsActionForTesting,
            "there is nothing in System Settings to fix a switch that is simply off"
        )
    }

    /// Approval is the one reason with a fix the app cannot perform itself, so it is the one that
    /// grows a button.
    func testApprovalIsTheOneReasonWithAnAction() {
        let list = makeList()

        list.show(state(status: .unavailable(.requiresApproval)))

        XCTAssertTrue(list.showsLoginItemsActionForTesting)
    }

    /// Project, runtime, uptime and pid: what it is, what it is running, how long it has been,
    /// and the number a support answer needs.
    func testTheDetailLineIdentifiesTheProcessAndItsAge() {
        let now = Date()
        let line = BackgroundSessionsListView.detail(
            for: held(
                name: "Fix the sidebar",
                project: "Threading",
                agent: "Claude",
                startedAt: now.addingTimeInterval(-4 * 3600 - 12 * 60),
                pid: 5150
            ),
            at: now
        )

        XCTAssertTrue(line.contains("Threading"), line)
        XCTAssertTrue(line.contains("Claude"), line)
        XCTAssertTrue(line.contains("4"), "the question a wedged agent raises is how long: \(line)")
        XCTAssertTrue(line.contains("pid 5150"), line)
    }

    /// A child that started a moment ago says so rather than reporting "0m".
    ///
    /// The formatter's smallest unit is a minute, so the picture of a freshly held session read
    /// "Running for 0m" — a broken clock rather than a new agent. Found in the render, asserted
    /// here.
    func testAChildStartedAMomentAgoIsNotDescribedAsRunningForZeroMinutes() {
        let now = Date()
        let line = BackgroundSessionsListView.detail(
            for: held(name: "Fresh", startedAt: now.addingTimeInterval(-40)),
            at: now
        )

        XCTAssertTrue(line.contains("Just started"), line)
        XCTAssertFalse(line.contains("0m"), line)
    }

    /// An ended child says so rather than counting up forever.
    func testAnEndedChildReportsItsEndingRatherThanAnUptime() {
        let line = BackgroundSessionsListView.detail(
            for: held(name: "Done", exited: true),
            at: Date()
        )

        XCTAssertTrue(line.contains("Ended"), line)
    }

    /// The press reaches the row it was made on, not the row that index happened to hold.
    ///
    /// Target/action with the sender's tag rather than a captured closure, because a recycled
    /// cell holding a stale session in a closure is exactly the bug that costs.
    func testStopNamesTheRowThatWasPressed() throws {
        var stopped: [String] = []
        let list = makeList(stop: { stopped.append($0.name) })
        let host = layout(list)

        list.show(state(sessions: [
            held(name: "First"),
            held(name: "Second"),
            held(name: "Third")
        ]))
        host.layoutSubtreeIfNeeded()

        let buttons = stopButtons(in: list)
        // An unshown table still lays out and still makes the row views inside its viewport; if a
        // future AppKit stops doing that, say so rather than failing on a fixture's behaviour.
        try XCTSkipUnless(buttons.count >= 3, "the table materialised \(buttons.count) rows")
        // The component's own activation rather than `NSControl.performClick(_:)`: a themed
        // control is cell-less, so the cell-based path activates nothing, and this is the seam a
        // press, the space bar and VoiceOver all converge on.
        buttons[1].performClick()

        XCTAssertEqual(stopped, ["Second"])
    }

    /// An ended child has nothing left to stop. Disabled rather than dropped: a control that
    /// vanishes explains less than one that waits.
    func testStopIsDisabledForAChildThatHasAlreadyEnded() throws {
        let list = makeList()
        let host = layout(list)

        list.show(state(sessions: [held(name: "Done", exited: true)]))
        host.layoutSubtreeIfNeeded()

        let buttons = stopButtons(in: list)
        try XCTSkipUnless(!buttons.isEmpty, "the table materialised no rows")
        XCTAssertFalse(try XCTUnwrap(buttons.first).isEnabled)
    }

    // MARK: - The inventory

    /// The survey answers the status and the rows together, because they come from one round trip
    /// and splitting them would be two chances to disagree.
    func testTheInventoryPublishesWhatTheSurveyAnswered() {
        let sessionID = SessionID()
        let inventory = PTYHostBackgroundSessionsInventory(
            survey: .answering(PTYHostBackgroundSessionsSurveyResult(
                status: .holding(1),
                summaries: [summary(sessionID: sessionID)],
                socketPath: "/tmp/ptyd.sock"
            )),
            stopper: { _, _, _ in true }
        )

        let changed = expectation(description: "the survey answered")
        inventory.onChange = { changed.fulfill() }
        inventory.refresh()
        wait(for: [changed], timeout: 5)

        XCTAssertEqual(inventory.state.status, .holding(1))
        XCTAssertEqual(inventory.state.sessions.count, 1)
        XCTAssertEqual(inventory.state.socketPath, "/tmp/ptyd.sock")
    }

    /// A stop names the session on the rendezvous the survey answered on, and the list is
    /// re-surveyed afterwards rather than edited in place — the host's own list is the truth.
    func testStoppingASessionUsesTheRendezvousTheSurveyAnswered() {
        let sessionID = SessionID()
        let asked = Asked()
        let inventory = PTYHostBackgroundSessionsInventory(
            survey: .answering(PTYHostBackgroundSessionsSurveyResult(
                status: .holding(1),
                summaries: [summary(sessionID: sessionID)],
                socketPath: "/tmp/ptyd.sock"
            )),
            stopper: { identity, socketPath, _ in
                asked.record(identity: identity, socketPath: socketPath)
                return true
            }
        )

        let surveyed = expectation(description: "the survey answered")
        inventory.onChange = { surveyed.fulfill() }
        inventory.refresh()
        wait(for: [surveyed], timeout: 5)

        let stopped = expectation(description: "the stop answered")
        inventory.stop(inventory.state.sessions[0]) { _ in stopped.fulfill() }
        wait(for: [stopped], timeout: 5)

        XCTAssertEqual(asked.socketPaths, ["/tmp/ptyd.sock"])
        XCTAssertEqual(
            asked.identities,
            [PTYHostSessionIdentity(.agentSession(sessionID))]
        )
    }

    /// With no rendezvous there is nothing to name a session on, and the stop says so rather than
    /// guessing a path.
    func testAStopWithNothingListeningAnswersFalse() {
        let inventory = PTYHostBackgroundSessionsInventory(
            survey: .answering(
                PTYHostBackgroundSessionsSurveyResult(status: .unavailable(.notRunning))
            ),
            stopper: { _, _, _ in
                XCTFail("nothing to stop, and no socket to stop it on")
                return false
            }
        )

        let answered = expectation(description: "the stop answered")
        inventory.stop(held(name: "Nothing")) { stopped in
            XCTAssertFalse(stopped)
            answered.fulfill()
        }
        wait(for: [answered], timeout: 5)
    }

    // MARK: - Rendered

    /// The list drawn at a settings pane's width, holding sessions and then explaining why it is
    /// empty — both in light and dark.
    ///
    /// A picture is where the failures of this surface are visible: a row whose uptime meets the
    /// button that ends it, an empty state that reads as a rendering fault rather than as an
    /// answer, a card that sits at a third of the pane because a vertical stack gives each
    /// arranged view its *fitting* width.
    func testRendersTheBackgroundSessionsList() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let stories: [(name: String, state: PTYHostBackgroundSessionsState)] = [
            ("holding", state(status: .holding(3), sessions: [
                held(
                    name: "Fix the sidebar",
                    project: "Threading",
                    agent: "Claude",
                    startedAt: Date().addingTimeInterval(-4 * 3600 - 12 * 60),
                    pid: 5150
                ),
                held(
                    name: "Port the daemon",
                    project: "Threading",
                    agent: "Codex",
                    startedAt: Date().addingTimeInterval(-9 * 60),
                    pid: 5151
                ),
                held(name: "codex", startedAt: Date().addingTimeInterval(-40), pid: 5152)
            ])),
            ("disabled", state(status: .unavailable(.disabled))),
            ("approval", state(status: .unavailable(.requiresApproval)))
        ]

        var written = 0
        for (name, story) in stories {
            for (appearanceName, appearanceID) in Render.appearances {
                let data = try XCTUnwrap(
                    image(of: story, appearance: appearanceID),
                    "Failed to render \(name) in \(appearanceName)"
                )
                try data.write(
                    to: directory.appendingPathComponent(
                        "background-sessions-\(name)-\(appearanceName).png"
                    )
                )
                written += 1
            }
        }

        XCTAssertEqual(written, stories.count * Render.appearances.count)
        print("Rendered the Background Sessions list to \(directory.path)")
    }

    // MARK: - Private Methods

    private func makeList(
        stop: @escaping (PTYHostHeldSession) -> Void = { _ in },
        openLoginItems: @escaping () -> Void = {}
    ) -> BackgroundSessionsListView {
        BackgroundSessionsListView(
            actions: BackgroundSessionsListView.Actions(
                stop: stop,
                openLoginItems: openLoginItems
            )
        )
    }

    /// A fixture standing in for a settings pane states its width the way a split view does.
    /// A view with only a frame pins nothing, and a child may then come out wider than the view
    /// holding it with nothing to say so.
    @discardableResult
    private func layout(_ list: BackgroundSessionsListView) -> NSView {
        let host = ThemedSurfaceView()
        host.frame = NSRect(x: 0, y: 0, width: Fixture.width, height: Fixture.height)
        host.applySurface(fill: Design.Surface.ground, radius: .fixed(0))
        host.addSubview(list)
        NSLayoutConstraint.activate([
            host.widthAnchor.constraint(equalToConstant: Fixture.width),
            host.heightAnchor.constraint(equalToConstant: Fixture.height),
            list.leadingAnchor.constraint(
                equalTo: host.leadingAnchor,
                constant: Design.Spacing.inset
            ),
            list.trailingAnchor.constraint(
                equalTo: host.trailingAnchor,
                constant: -Design.Spacing.inset
            ),
            list.topAnchor.constraint(equalTo: host.topAnchor, constant: Design.Spacing.inset)
        ])
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func image(
        of state: PTYHostBackgroundSessionsState,
        appearance name: NSAppearance.Name
    ) -> Data? {
        var data: Data?
        let render: @MainActor () -> Void = {
            let list = self.makeList()
            let host = self.layout(list)
            // Without this the offscreen draw comes out blank: `cacheDisplay` resolves dynamic
            // colours against the host's appearance, and a host with none has nothing to resolve.
            host.appearance = NSAppearance(named: name)
            list.show(state)
            AppThemeRefresh.repaint(host)
            host.layoutSubtreeIfNeeded()

            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            data = rep.representation(using: .png, properties: [:])
        }

        if let appearance = NSAppearance(named: name) {
            appearance.performAsCurrentDrawingAppearance {
                MainActor.assumeIsolated(render)
            }
        }
        return data
    }

    private func stopButtons(in list: NSView) -> [ThemedButton] {
        var found: [(CGFloat, ThemedButton)] = []
        func walk(_ view: NSView) {
            if let button = view as? ThemedButton, button.title == "Stop" {
                let origin = view.convert(NSPoint.zero, to: list)
                found.append((origin.y, button))
            }
            for subview in view.subviews { walk(subview) }
        }
        walk(list)
        // Top to bottom, which is the order the model is in and the order a reader would press.
        return found.sorted { $0.0 < $1.0 }.map(\.1)
    }

    private func state(
        status: PTYHostBackgroundSessionsStatus = .holding(0),
        sessions: [PTYHostHeldSession] = []
    ) -> PTYHostBackgroundSessionsState {
        PTYHostBackgroundSessionsState(
            status: sessions.isEmpty ? status : .holding(sessions.count),
            sessions: sessions,
            socketPath: "/tmp/ptyd.sock",
            build: "test"
        )
    }

    private func held(
        name: String,
        project: String? = nil,
        agent: String? = nil,
        startedAt: Date = Date(),
        pid: Int32 = 1234,
        exited: Bool = false
    ) -> PTYHostHeldSession {
        PTYHostHeldSession(
            identity: PTYHostSessionIdentity(.agentSession(SessionID())),
            sessionID: nil,
            name: name,
            project: project,
            agent: agent,
            startedAt: startedAt,
            pid: pid,
            hasExited: exited
        )
    }

    private func summary(sessionID: SessionID) -> PTYHostSessionSummary {
        PTYHostSessionSummary(
            id: PTYHostSessionIdentity(.agentSession(sessionID)),
            pid: 4242,
            startedAt: Date(),
            executable: "/usr/local/bin/claude",
            grid: PTYHostGrid(cols: 80, rows: 24),
            isAttached: false
        )
    }
}

/// What the stopper was asked, from whichever queue it was asked on.
private final class Asked: @unchecked Sendable {
    private let lock = NSLock()
    private var identityStorage: [PTYHostSessionIdentity] = []
    private var socketStorage: [String] = []

    func record(identity: PTYHostSessionIdentity, socketPath: String) {
        lock.lock()
        identityStorage.append(identity)
        socketStorage.append(socketPath)
        lock.unlock()
    }

    var identities: [PTYHostSessionIdentity] {
        lock.lock()
        defer { lock.unlock() }
        return identityStorage
    }

    var socketPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return socketStorage
    }
}

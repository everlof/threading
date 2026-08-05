import AppKit
import XCTest
@testable import Threading

/// The plan behind relaunching, at startup, the sessions that were running at the last quit.
///
/// The pacing half — one launch per tick — is a timer walking this list; the judgement worth
/// pinning is which sessions get in line and in what order.
final class StartupSessionRelaunchTests: XCTestCase {

    // MARK: - Fixtures

    private func session(
        _ title: String,
        lastActiveAt: Date,
        archived: Bool = false
    ) -> AgentSession {
        var session = AgentSession(kind: .claude, title: title)
        session.lastActiveAt = lastActiveAt
        session.isArchived = archived
        return session
    }

    // MARK: - Tests

    func testMostRecentlyActiveLaunchesFirst() {
        let older = session("older", lastActiveAt: Date(timeIntervalSince1970: 100))
        let newest = session("newest", lastActiveAt: Date(timeIntervalSince1970: 300))
        let middle = session("middle", lastActiveAt: Date(timeIntervalSince1970: 200))

        let planned = StartupSessionRelaunch.plan(
            recorded: [older.id, newest.id, middle.id],
            sessions: [older, newest, middle],
            excluding: nil
        )

        XCTAssertEqual(
            planned,
            [newest.id, middle.id, older.id],
            "the stagger makes the last in line wait the whole line, so the freshest goes first"
        )
    }

    /// The record outlives the sessions it names: anything deleted or archived since the quit
    /// is dropped by lookup rather than trusted.
    func testDeletedAndArchivedSessionsAreDropped() {
        let kept = session("kept", lastActiveAt: Date(timeIntervalSince1970: 100))
        let archived = session(
            "archived",
            lastActiveAt: Date(timeIntervalSince1970: 200),
            archived: true
        )
        let deleted = SessionID()

        let planned = StartupSessionRelaunch.plan(
            recorded: [deleted, archived.id, kept.id],
            sessions: [kept, archived],
            excluding: nil
        )

        XCTAssertEqual(planned, [kept.id])
    }

    /// The selected session is already being restored on screen through the sidebar; a second
    /// launch here would race the selection's own.
    func testTheRestoredSelectionIsLeftOut() {
        let selected = session("selected", lastActiveAt: Date(timeIntervalSince1970: 300))
        let other = session("other", lastActiveAt: Date(timeIntervalSince1970: 100))

        let planned = StartupSessionRelaunch.plan(
            recorded: [selected.id, other.id],
            sessions: [selected, other],
            excluding: selected.id
        )

        XCTAssertEqual(planned, [other.id])
    }

    func testAnEmptyRecordPlansNothing() {
        let stored = session("stored", lastActiveAt: Date())

        XCTAssertTrue(
            StartupSessionRelaunch.plan(
                recorded: [],
                sessions: [stored],
                excluding: nil
            ).isEmpty
        )
    }

    // MARK: - Stagger

    /// One launch per tick, and the relauncher retires its timer with the plan — it must not
    /// keep a repeating timer alive after the last session is up.
    @MainActor
    func testTheRelauncherWalksThePlanInOrder() {
        let first = SessionID()
        let second = SessionID()
        var launched: [SessionID] = []

        let interval: TimeInterval = 0.05
        let relauncher = StartupSessionRelauncher(
            sessionIDs: [first, second],
            interval: interval
        ) {
            launched.append($0)
        }
        relauncher.start()

        XCTAssertTrue(launched.isEmpty, "the first launch waits a full interval too")

        let deadline = Date().addingTimeInterval(interval * 40)
        while launched.count < 2, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        XCTAssertEqual(launched, [first, second])
    }
}

// MARK: - Quit Path

/// What the relaunch record depends on: that closing the window does not tear the agents down
/// before the quit has looked at them.
///
/// This is the bug the feature shipped with. Closing the window ran `windowWillClose`, which
/// terminated every agent and emptied `AgentRuntime`; the quit that followed found nothing
/// running, so it warned about nothing and recorded nothing, and the next launch relaunched
/// nothing — with the setting on and the plan above perfectly correct. The window is built and
/// never shown, and the close is asked rather than performed, so nothing here can close a
/// window under the test host.
@MainActor
final class WindowCloseQuitPathTests: XCTestCase {

    /// Asserted through the affordance the user actually presses, not just the delegate method:
    /// the themed close button is the app's only close control, and it is the caller that has
    /// to honour the answer.
    func testTheCloseButtonAsksTheApplicationToQuitAndClosesNothingItself() throws {
        let controller = MainWindowController()
        let window = try XCTUnwrap(controller.window)
        var quitRequests = 0
        controller.requestsApplicationQuit = { quitRequests += 1 }

        var didClose = false
        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: nil
        ) { _ in didClose = true }
        defer { NotificationCenter.default.removeObserver(observer) }

        let close = WindowChromeButton(role: .close)
        window.contentView?.addSubview(close)
        _ = close.performPrimaryAction()

        XCTAssertEqual(quitRequests, 1, "closing the only window is quitting, and takes that path")
        XCTAssertFalse(
            didClose,
            "the window must outlive the request: the quit reads the live runtime, and a "
                + "declined quit has to leave the window exactly as it was"
        )
    }

    /// The delegate's own answer, so the contract holds for any future close affordance.
    func testTheDelegateDeclinesTheCloseItself() throws {
        let controller = MainWindowController()
        let window = try XCTUnwrap(controller.window)
        var quitRequests = 0
        controller.requestsApplicationQuit = { quitRequests += 1 }

        XCTAssertFalse(controller.windowShouldClose(window))
        XCTAssertEqual(quitRequests, 1)
    }
}

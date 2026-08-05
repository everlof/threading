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

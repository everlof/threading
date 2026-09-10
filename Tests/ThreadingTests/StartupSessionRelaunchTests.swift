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
        lastTurnAt: Date? = nil,
        archived: Bool = false
    ) -> AgentSession {
        var session = AgentSession(kind: .claude, title: title)
        session.lastActiveAt = lastActiveAt
        session.lastTurnAt = lastTurnAt
        session.isArchived = archived
        return session
    }

    // MARK: - Running At Last Quit

    func testMostRecentlyActiveLaunchesFirst() {
        let older = session("older", lastActiveAt: Date(timeIntervalSince1970: 100))
        let newest = session("newest", lastActiveAt: Date(timeIntervalSince1970: 300))
        let middle = session("middle", lastActiveAt: Date(timeIntervalSince1970: 200))

        let planned = StartupSessionRelaunch.plan(
            policy: .runningAtLastQuit,
            recorded: [older.id, newest.id, middle.id],
            sessions: [older, newest, middle],
            now: Date(timeIntervalSince1970: 350)
        )

        XCTAssertEqual(
            planned.sessionIDs,
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
            policy: .runningAtLastQuit,
            recorded: [deleted, archived.id, kept.id],
            sessions: [kept, archived],
            now: Date(timeIntervalSince1970: 250)
        )

        XCTAssertEqual(planned.sessionIDs, [kept.id])
        XCTAssertNil(
            planned.outcomes[archived.id],
            "an archived session is not a dormant row anybody can hover, so it earns no reason"
        )
    }

    /// The selected session is already being restored on screen through the sidebar; a second
    /// launch here would race the selection's own.
    func testTheRestoredSelectionIsLeftOut() {
        let selected = session("selected", lastActiveAt: Date(timeIntervalSince1970: 300))
        let other = session("other", lastActiveAt: Date(timeIntervalSince1970: 100))

        let planned = StartupSessionRelaunch.plan(
            policy: .runningAtLastQuit,
            recorded: [selected.id, other.id],
            sessions: [selected, other],
            now: Date(timeIntervalSince1970: 350),
            excluding: selected.id
        )

        XCTAssertEqual(planned.sessionIDs, [other.id])
        XCTAssertEqual(
            planned.outcomes[selected.id],
            .restored,
            "left out of the launch list because something else is launching it, not because it "
                + "was refused"
        )
    }

    func testAnEmptyRecordPlansNothing() {
        let stored = session("stored", lastActiveAt: Date())

        let planned = StartupSessionRelaunch.plan(
            policy: .runningAtLastQuit,
            recorded: [],
            sessions: [stored]
        )

        XCTAssertTrue(planned.sessionIDs.isEmpty)
        XCTAssertEqual(
            planned.outcomes[stored.id],
            .nothingRecorded,
            "an empty record and a session that simply was not running are different facts, and "
                + "only one of them is something the user chose"
        )
    }

    func testASessionThatWasNotRunningSaysSo() {
        let running = session("running", lastActiveAt: Date(timeIntervalSince1970: 300))
        let idle = session("idle", lastActiveAt: Date(timeIntervalSince1970: 200))

        let planned = StartupSessionRelaunch.plan(
            policy: .runningAtLastQuit,
            recorded: [running.id],
            sessions: [running, idle],
            now: Date(timeIntervalSince1970: 350)
        )

        XCTAssertEqual(planned.outcomes[running.id], .restored)
        XCTAssertEqual(planned.outcomes[idle.id], .notRunningAtLastQuit)
    }

    // MARK: - Recently Used

    /// The window's whole point: it does not depend on the record, so a reboot, a force quit or a
    /// launch that erased the record cannot cost the user their open conversations.
    func testTheWindowIgnoresTheRecordEntirely() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let used = session(
            "used",
            lastActiveAt: now.addingTimeInterval(-3600),
            lastTurnAt: now.addingTimeInterval(-3600)
        )

        let planned = StartupSessionRelaunch.plan(
            policy: .recentlyUsed,
            recorded: [],
            sessions: [used],
            windowDays: 1,
            limit: 12,
            now: now
        )

        XCTAssertEqual(planned.sessionIDs, [used.id])
        XCTAssertEqual(planned.outcomes[used.id], .restored)
    }

    func testSessionsOlderThanTheWindowStayDormantAndSayWhen() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let stale = session(
            "stale",
            lastActiveAt: now,
            lastTurnAt: now.addingTimeInterval(-4 * 24 * 3600)
        )

        let planned = StartupSessionRelaunch.plan(
            policy: .recentlyUsed,
            recorded: [],
            sessions: [stale],
            windowDays: 1,
            now: now
        )

        XCTAssertTrue(planned.sessionIDs.isEmpty)
        XCTAssertEqual(
            planned.outcomes[stale.id],
            .outsideWindow(days: 1, lastUsedAt: now.addingTimeInterval(-4 * 24 * 3600)),
            "the reason carries both halves the card needs: when it was used, and how far back "
                + "the window reaches"
        )
    }

    /// A window is not a bound. The cap is, and the sessions it turns away have to be able to say
    /// that the cap is what turned them away.
    func testTheLimitTakesTheMostRecentAndNamesItselfToTheRest() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        // The smallest limit the settings pop-up offers, because a smaller one is clamped up to
        // it: the stored value and the control that shows it have to agree.
        let cap = SessionRestoreDefaults.limitChoices.first ?? SessionRestoreDefaults.limit
        let sessions = (0..<(cap + 3)).map { index in
            session(
                "session-\(index)",
                lastActiveAt: now,
                lastTurnAt: now.addingTimeInterval(-Double(index) * 60)
            )
        }

        let planned = StartupSessionRelaunch.plan(
            policy: .recentlyUsed,
            recorded: [],
            sessions: sessions.shuffled(),
            windowDays: 1,
            limit: cap,
            now: now
        )

        XCTAssertEqual(planned.sessionIDs, sessions.prefix(cap).map(\.id))
        for turnedAway in sessions.dropFirst(cap) {
            XCTAssertEqual(planned.outcomes[turnedAway.id], .beyondLimit(limit: cap))
        }
    }

    /// The trap this field exists to avoid: the runtime stamps `lastActiveAt` when it relaunches a
    /// session, so a window read from it would count its own last launch as use and never let go
    /// of anything.
    func testARelaunchStampIsNotUse() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let relaunchedThisMorning = session(
            "relaunched",
            lastActiveAt: now.addingTimeInterval(-60),
            lastTurnAt: now.addingTimeInterval(-9 * 24 * 3600)
        )

        let planned = StartupSessionRelaunch.plan(
            policy: .recentlyUsed,
            recorded: [],
            sessions: [relaunchedThisMorning],
            windowDays: 1,
            now: now
        )

        XCTAssertTrue(planned.sessionIDs.isEmpty)
    }

    /// Records written before `lastTurnAt` existed have to fall back to something, and the cap is
    /// what keeps that first launch honest.
    func testRecordsWithoutATurnFallBackToLastActive() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let legacy = session("legacy", lastActiveAt: now.addingTimeInterval(-600))

        XCTAssertEqual(legacy.lastUsedAt, now.addingTimeInterval(-600))
        XCTAssertEqual(
            StartupSessionRelaunch.plan(
                policy: .recentlyUsed,
                recorded: [],
                sessions: [legacy],
                windowDays: 1,
                now: now
            ).sessionIDs,
            [legacy.id]
        )
    }

    // MARK: - Nothing

    func testBringingNothingBackStillExplainsItself() {
        let stored = session("stored", lastActiveAt: Date())

        let planned = StartupSessionRelaunch.plan(
            policy: .nothing,
            recorded: [stored.id],
            sessions: [stored]
        )

        XCTAssertTrue(planned.sessionIDs.isEmpty)
        XCTAssertEqual(planned.outcomes[stored.id], .restoreDisabled)
    }

    // MARK: - Settings

    /// The setting grew a third answer, and a choice already made has to survive that.
    func testAnUnsetPolicyReadsTheToggleItReplaced() {
        XCTAssertEqual(
            SessionRestorePolicy.resolved(stored: nil, legacyRestoresRunningSessions: true),
            .runningAtLastQuit
        )
        XCTAssertEqual(
            SessionRestorePolicy.resolved(stored: nil, legacyRestoresRunningSessions: false),
            .nothing,
            "somebody who switched relaunching off must not have it switched back on by an update"
        )
        XCTAssertEqual(
            SessionRestorePolicy.resolved(
                stored: SessionRestorePolicy.recentlyUsed.rawValue,
                legacyRestoresRunningSessions: false
            ),
            .recentlyUsed,
            "a stored policy is the answer, whatever the legacy toggle still says"
        )
        XCTAssertEqual(
            SessionRestorePolicy.resolved(stored: "nonsense", legacyRestoresRunningSessions: true),
            .runningAtLastQuit,
            "a value this build cannot read is not a policy"
        )
    }

    /// Both values decide how many processes a launch spawns, so neither trusts what it is given.
    func testTheWindowAndLimitAreClamped() {
        XCTAssertEqual(SessionRestoreDefaults.windowDays, 1)
        XCTAssertEqual(SessionRestoreDefaults.limit, 4)
        XCTAssertEqual(SessionRestoreDefaults.clampWindowDays(0), SessionRestoreDefaults.windowDays)
        XCTAssertEqual(SessionRestoreDefaults.clampWindowDays(-5), SessionRestoreDefaults.windowDays)
        XCTAssertEqual(SessionRestoreDefaults.clampWindowDays(9_000), 30)
        XCTAssertEqual(SessionRestoreDefaults.clampLimit(0), SessionRestoreDefaults.limit)
        XCTAssertEqual(SessionRestoreDefaults.clampLimit(9_000), 32)
        XCTAssertEqual(SessionRestoreDefaults.clampLimit(1), 4, "below the smallest offered choice")
    }

    /// The window is elapsed use, not a date, so an hour past the window is outside it whichever
    /// side of midnight the two fell on.
    func testTheWindowIsMeasuredInElapsedTime() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let justInside = session(
            "inside",
            lastActiveAt: now,
            lastTurnAt: now.addingTimeInterval(-23 * 3600)
        )
        let justOutside = session(
            "outside",
            lastActiveAt: now,
            lastTurnAt: now.addingTimeInterval(-25 * 3600)
        )

        let planned = StartupSessionRelaunch.plan(
            policy: .recentlyUsed,
            recorded: [],
            sessions: [justInside, justOutside],
            windowDays: 1,
            now: now
        )

        XCTAssertEqual(planned.sessionIDs, [justInside.id])
    }

    // MARK: - Dormancy Copy

    /// The card's job: name the rule, and name where the rule is set. A dormant row the user
    /// cannot act on is what this whole setting was reported as.
    func testEveryReasonNamesItselfAndTheSettingsPage() {
        let outcomes: [SessionRestorationOutcome] = [
            .restoreDisabled,
            .notRunningAtLastQuit,
            .nothingRecorded,
            .outsideWindow(days: 3, lastUsedAt: Date(timeIntervalSinceNow: -9 * 24 * 3600)),
            .beyondLimit(limit: 12)
        ]

        for outcome in outcomes {
            let reason = SessionPopoverDefaults.dormancyReason(for: outcome)
            XCTAssertNotNil(reason, "\(outcome) has to be explainable")
            XCTAssertTrue(
                reason?.contains(SessionPopoverDefaults.restoreSettingHint) == true,
                "\(outcome) says nothing about where to change it"
            )
        }

        XCTAssertNil(
            SessionPopoverDefaults.dormancyReason(for: .restored),
            "a restored session is live, and the card already says so"
        )
    }

    /// The limit is the one reason a user cannot guess from the row: the session is recent enough,
    /// and something else still came back instead of it.
    func testTheLimitReasonQuotesTheLimit() throws {
        let reason = try XCTUnwrap(
            SessionPopoverDefaults.dormancyReason(for: .beyondLimit(limit: 12))
        )

        XCTAssertTrue(reason.contains("12"), "the ceiling that turned it away has to be in words")
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

// MARK: - The Record Itself

/// The record behind `.runningAtLastQuit`, and the one way a correct plan still comes up empty.
///
/// This is the bug that made a user ask why their sessions were dormant. Seventeen were live one
/// evening; then the app was opened and quit again about twenty times inside a few minutes —
/// rebuild-and-open cycles, each under a second — and every one of those quits wrote "nothing was
/// running" over the list the last real quit had left. Nothing after that could bring them back.
@MainActor
final class RunningSessionRecordTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("running-record-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func manager() -> StateManager {
        StateManager(appSupportDirectory: directory)
    }

    func testALaunchThatNeverReadTheRecordIsNotAllowedToClaimItSpent() {
        let quitting = manager()
        quitting.saveRunningSessionIDs([SessionID(), SessionID()])

        let throwaway = manager()
        XCTAssertFalse(
            throwaway.hasConsumedRunningSessionIDs,
            "the launch has not read the record, so its own emptiness says nothing about it"
        )

        // What `AppDelegate` does with that answer: nothing running and nothing spent means the
        // write is skipped entirely.
        XCTAssertEqual(manager().consumeRunningSessionIDs().count, 2)
    }

    func testReadingTheRecordMarksItSpentAndEmptiesIt() {
        let recorded = [SessionID(), SessionID()]
        manager().saveRunningSessionIDs(recorded)

        let launching = manager()
        XCTAssertEqual(launching.consumeRunningSessionIDs(), recorded)
        XCTAssertTrue(launching.hasConsumedRunningSessionIDs)
        XCTAssertTrue(
            manager().consumeRunningSessionIDs().isEmpty,
            "consumed rather than kept: a list that outlived the launch that read it would "
                + "relaunch sessions the user has since closed"
        )
    }

    /// The write the guard exists to prevent, asserted directly so the cost of getting the guard
    /// wrong stays visible: an empty list is not a harmless write.
    func testAnEmptyWriteDestroysTheRecord() {
        manager().saveRunningSessionIDs([SessionID()])
        manager().saveRunningSessionIDs([])

        XCTAssertTrue(manager().consumeRunningSessionIDs().isEmpty)
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
final class WindowCloseQuitPathTests: HostedStoreTestCase {

    /// Asserted through the affordance the user actually presses, not just the delegate method:
    /// the themed close button is the app's only close control, and it is the caller that has
    /// to honour the answer.
    func testTheCloseButtonAsksTheApplicationToQuitAndClosesNothingItself() throws {
        let controller = makeMainWindowController()
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
        let controller = makeMainWindowController()
        let window = try XCTUnwrap(controller.window)
        var quitRequests = 0
        controller.requestsApplicationQuit = { quitRequests += 1 }

        XCTAssertFalse(controller.windowShouldClose(window))
        XCTAssertEqual(quitRequests, 1)
    }
}

import XCTest

@testable import Threading

/// One session asking to be told when another one stops, and being told exactly once.
///
/// The whole component is about *when* and *how often*: that the notice lands on the edge the
/// app already calls "finished", that an ending which is not a finished turn — the agent exiting,
/// the usage window running out — counts as one too, that a watch is spent when it fires, and
/// that an optional deadline retires out loud rather than silently, and that omission does not
/// impose a hidden wall-clock deadline.
///
/// Driven through a private `NotificationCenter` with the clock and all three lookups injected,
/// so no live agent, no store and none of the running app's own event traffic is involved.
@MainActor
final class SessionWatchCenterTests: XCTestCase {

    // MARK: - Fixture

    private var notifications: NotificationCenter!
    private var clock: Date!
    private var watcher: SessionID!
    private var target: SessionID!
    private var activities: [SessionID: SessionActivity] = [:]
    private var titles: [SessionID: String] = [:]
    private var delivered: [(text: String, target: SessionID)] = []
    private var deliveryOutcome: SessionMessageDelivery.Outcome = .sentNow

    override func setUp() {
        super.setUp()
        notifications = NotificationCenter()
        clock = Date()
        watcher = SessionID()
        target = SessionID()
        activities = [:]
        titles = [:]
        delivered = []
        deliveryOutcome = .sentNow
        activities[target] = .working
        titles[target] = "Review pass"
    }

    override func tearDown() {
        notifications = nil
        super.tearDown()
    }

    private func makeCenter() -> SessionWatchCenter {
        SessionWatchCenter(
            center: notifications,
            now: { [weak self] in self?.clock ?? Date() },
            dependencies: SessionWatchCenter.Dependencies(
                activity: { [weak self] id in self?.activities[id] ?? .dormant },
                sessionTitle: { [weak self] id in self?.titles[id] },
                deliverNotice: { [weak self] text, watcher, completion in
                    self?.delivered.append((text, watcher))
                    completion(self?.deliveryOutcome ?? .sentNow)
                }
            )
        )
    }

    /// The one signal the centre listens to, as the container posts it.
    private func reportActivity(_ new: SessionActivity, of sessionID: SessionID? = nil) {
        activities[sessionID ?? target] = new
        notifications.post(SessionActivityDidChange(sessionID: sessionID ?? target))
        settle()
    }

    private func settle(_ interval: TimeInterval = 0.05) {
        let settled = expectation(description: "the run loop advanced")
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { settled.fulfill() }
        wait(for: [settled], timeout: interval + 5)
    }

    // MARK: - Held Notices

    /// The common shape in practice: the watcher is itself mid-turn at a terminal when its
    /// worker settles. The notice must wait for the watcher's own settle edge, not vanish.
    func testANoticeTheWatcherCannotTakeYetIsHeldForItsOwnSettleEdge() {
        let center = makeCenter()
        activities[watcher] = .working
        center.arm(watcher: watcher, target: target)

        deliveryOutcome = .busyTerminal
        reportActivity(.idle)
        XCTAssertEqual(delivered.count, 1, "one attempt was made and answered busyTerminal")
        XCTAssertFalse(center.isWatching(watcher: watcher, target: target), "the watch is spent")

        deliveryOutcome = .sentNow
        reportActivity(.idle, of: watcher)
        XCTAssertEqual(delivered.count, 2, "the watcher's own settle edge retried the notice")
        XCTAssertEqual(delivered.last?.target, watcher)
        XCTAssertTrue(
            delivered.last?.text.contains(target.uuidString.lowercased()) == true,
            "the held notice still names the watched session"
        )

        reportActivity(.idle, of: watcher)
        XCTAssertEqual(delivered.count, 2, "a delivered notice is not delivered again")
    }

    /// `.typedUnconfirmed` is the one failure never retried: the first copy may have landed,
    /// and a manager handed the same conclusion twice will act on it twice.
    func testAnAmbiguousDeliveryIsNeverRetried() {
        let center = makeCenter()
        center.arm(watcher: watcher, target: target)

        deliveryOutcome = .typedUnconfirmed
        reportActivity(.idle)
        XCTAssertEqual(delivered.count, 1)

        deliveryOutcome = .sentNow
        reportActivity(.idle, of: watcher)
        XCTAssertEqual(delivered.count, 1, "an ambiguous delivery must not risk a duplicate")
    }

    // MARK: - The edge

    /// The heart of it: nothing while the target is still answering, one notice when it stops,
    /// and nothing ever again from that watch.
    func testTheSettleEdgeFiresOnceAndSpendsTheWatch() {
        let center = makeCenter()
        XCTAssertEqual(
            center.arm(watcher: watcher, target: target),
            .armed(expiresAfter: nil)
        )

        reportActivity(.working)
        XCTAssertTrue(delivered.isEmpty, "the notice landed while the target was still working")

        reportActivity(.idle)
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered.first?.target, watcher, "the notice goes to the watcher, not the target")
        XCTAssertFalse(center.isWatching(watcher: watcher, target: target))

        reportActivity(.working)
        reportActivity(.idle)
        XCTAssertEqual(
            delivered.count, 1,
            "a spent watch fired a second time on the next turn's end"
        )
    }

    func testAnotherSessionsTurnEndingSpendsNothing() {
        let center = makeCenter()
        center.arm(watcher: watcher, target: target)

        let stranger = SessionID()
        activities[stranger] = .working
        reportActivity(.idle, of: stranger)

        XCTAssertTrue(delivered.isEmpty)
        XCTAssertTrue(center.isWatching(watcher: watcher, target: target))
    }

    // MARK: - What the notice says

    /// The title is read when the watch fires, not when it is armed: an agent renames its own
    /// session mid-turn, and a notice naming the old row names something `list_sessions` will
    /// not show.
    func testTheNoticeCarriesTheFreshTitleTheIdAndThreadingsOwnFrame() throws {
        let center = makeCenter()
        titles[target] = "Old name"
        center.arm(watcher: watcher, target: target)

        titles[target] = "Review pass"
        reportActivity(.idle)

        let notice = try XCTUnwrap(delivered.first?.text)
        XCTAssertTrue(notice.hasPrefix("[Session watch — Threading]"))
        XCTAssertTrue(notice.contains("“Review pass”"), "the notice named the title the row had at arm time")
        XCTAssertFalse(notice.contains("Old name"))
        XCTAssertTrue(
            notice.contains(target.uuidString.lowercased()),
            "the id is spelled the way every app-side surface prints it — lowercased"
        )
        XCTAssertTrue(notice.contains("finished its turn and is idle"))
        XCTAssertFalse(
            notice.contains("[Cross-session message"),
            "that header claims the target's agent wrote the body, which for a watch notice is a lie"
        )
        XCTAssertTrue(notice.contains("This is Threading speaking, not that session's agent."))
    }

    /// A session whose agent exited and one stopped at its usage limit have both ended, and the
    /// watcher's next move differs in each case — so the notice says which ending it was.
    func testTheEndingsThatAreNotAFinishedTurnSayWhatTheyAre() throws {
        for (ending, phrase) in [
            (SessionActivity.dormant, "its agent exited"),
            (SessionActivity.limitReached, "stopped at its usage limit"),
        ] {
            delivered = []
            activities[target] = .working
            let center = makeCenter()
            center.arm(watcher: watcher, target: target)

            reportActivity(ending)

            let notice = try XCTUnwrap(delivered.first?.text, "\(ending) left the watch armed")
            XCTAssertEqual(delivered.count, 1)
            XCTAssertTrue(notice.contains(phrase), "\(ending) was reported as an ordinary settle")
            XCTAssertFalse(center.isWatching(watcher: watcher, target: target))
        }
    }

    // MARK: - What arming refuses

    /// Nothing is in flight, so there is no edge to wait for: a watch armed here would fire on
    /// whatever the target is asked to do next, which is not the work the watcher waited on.
    func testAnAlreadySettledTargetIsRefusedRatherThanWatched() {
        let center = makeCenter()

        for settled in [SessionActivity.idle, .needsAttention, .dormant, .limitReached] {
            activities[target] = settled
            XCTAssertEqual(
                center.arm(watcher: watcher, target: target),
                .targetAlreadySettled,
                "\(settled) was taken as something still to wait for"
            )
        }

        reportActivity(.working)
        reportActivity(.idle)
        XCTAssertTrue(delivered.isEmpty, "a refused watch still delivered")
    }

    /// Two watches on one edge would deliver the same fact twice, spending two of the watcher's
    /// turns on it.
    func testTheSameWatcherAndTargetCoalescesToOneWatch() {
        let center = makeCenter()

        XCTAssertEqual(
            center.arm(watcher: watcher, target: target),
            .armed(expiresAfter: nil)
        )
        XCTAssertEqual(center.arm(watcher: watcher, target: target), .alreadyWatching)

        reportActivity(.idle)
        XCTAssertEqual(delivered.count, 1)
    }

    func testAWatcherIsBoundedByTheNamedBudget() {
        let center = makeCenter()

        let targets = (0..<ControlWatchDefaults.maximumPerWatcher).map { _ -> SessionID in
            let id = SessionID()
            activities[id] = .working
            return id
        }
        for id in targets {
            XCTAssertEqual(
                center.arm(watcher: watcher, target: id),
                .armed(expiresAfter: nil)
            )
        }

        XCTAssertEqual(
            center.arm(watcher: watcher, target: target),
            .watcherAtCapacity(limit: ControlWatchDefaults.maximumPerWatcher),
            "the cap is per watcher and holds at the limit, not one past it"
        )
        // Another session's budget is its own.
        XCTAssertEqual(
            center.arm(watcher: SessionID(), target: target),
            .armed(expiresAfter: nil)
        )
    }

    // MARK: - Expiry

    /// A watch on a turn that never ends retires itself, and says so: an agent that armed one
    /// and heard nothing cannot tell "still running" from "quietly forgotten".
    func testAWatchThatNeverFiresExpiresOutLoudAndIsSpent() throws {
        let center = makeCenter()
        center.arm(watcher: watcher, target: target, timeout: 0.03)

        settle(0.2)

        let notice = try XCTUnwrap(delivered.first?.text)
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered.first?.target, watcher)
        XCTAssertTrue(notice.hasPrefix("[Session watch — Threading]"))
        XCTAssertTrue(notice.contains("expired"))
        XCTAssertTrue(notice.contains("Re-arm it if you still need the signal."))
        XCTAssertTrue(notice.contains("“Review pass”"))
        XCTAssertFalse(center.isWatching(watcher: watcher, target: target))

        reportActivity(.idle)
        XCTAssertEqual(delivered.count, 1, "an expired watch was still spent on a later settle")
    }

    /// The run loop was blocked or the machine slept, so the expiry timer never ran and the edge
    /// arrives first. The watch is still older than its budget, and is retired rather than spent
    /// on a turn it has outlived.
    func testAWatchOlderThanItsBudgetIsRetiredRatherThanSpentOnALaterTurn() throws {
        let center = makeCenter()
        let timeout: TimeInterval = 30
        center.arm(watcher: watcher, target: target, timeout: timeout)

        clock = clock.addingTimeInterval(timeout + 1)
        reportActivity(.idle)

        let notice = try XCTUnwrap(delivered.first?.text)
        XCTAssertEqual(delivered.count, 1)
        XCTAssertTrue(notice.contains("expired"), "a stale watch was spent on an unrelated turn's end")
        XCTAssertFalse(center.isWatching(watcher: watcher, target: target))
    }

    /// With no caller-supplied deadline, elapsed wall time does not replace the settle edge the
    /// caller asked for. The app run and the per-watcher cap remain the lifetime bounds.
    func testAWatchWithoutATimeoutStillFiresAfterThirtyMinutes() throws {
        let center = makeCenter()
        center.arm(watcher: watcher, target: target)

        clock = clock.addingTimeInterval(31 * 60)
        reportActivity(.idle)

        let notice = try XCTUnwrap(delivered.first?.text)
        XCTAssertTrue(notice.contains("finished its turn and is idle"))
        XCTAssertFalse(notice.contains("expired"))
        XCTAssertFalse(center.isWatching(watcher: watcher, target: target))
    }

    func testInvalidTimeoutsAreRefusedWithoutHoldingAWatch() {
        let center = makeCenter()

        for timeout in [0, -1, .infinity, .nan] {
            XCTAssertEqual(
                center.arm(watcher: watcher, target: target, timeout: timeout),
                .invalidTimeout
            )
            XCTAssertFalse(center.isWatching(watcher: watcher, target: target))
        }
    }

    // MARK: - Delivery

    /// The watch is spent whatever the surface says, so an undeliverable notice leaves a record
    /// rather than nothing at all.
    func testAnUndeliverableNoticeStillSpendsTheWatch() {
        deliveryOutcome = .noLiveSurface
        let center = makeCenter()
        center.arm(watcher: watcher, target: target)

        reportActivity(.idle)

        XCTAssertEqual(delivered.count, 1)
        XCTAssertFalse(center.isWatching(watcher: watcher, target: target))
    }
}

import Foundation
import XCTest
@testable import Threading

/// Snooze's complete state machine against a private durable project store and injected clock.
/// No process, provider, notification daemon, or wall-clock timer participates in these tests.
@MainActor
final class SessionSnoozeTests: XCTestCase {

    private var directory: URL!
    private var store: ProjectStore!
    private var sessionID: SessionID!
    private var now: Date!
    private var activity: SessionActivity = .idle
    private var center: SessionSnoozeCenter!
    private var events: NotificationCenter!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-snooze-tests-\(UUID().uuidString)")
        store = ProjectStore(stateManager: StateManager(appSupportDirectory: directory))
        // `addProject` answers Optional since the store began refusing writes it cannot persist.
        let project = try XCTUnwrap(
            store.addProject(folderURL: directory.appendingPathComponent("checkout"))
        )
        sessionID = store.addSession(to: project.id, kind: .claude)?.id
        now = Date(timeIntervalSince1970: 2_000_000_000)
        events = NotificationCenter()
        center = SessionSnoozeCenter(
            projectStore: store,
            now: { [weak self] in self?.now ?? .distantPast },
            activity: { [weak self] _ in self?.activity ?? .dormant },
            runtime: { [weak self] _ in
                .test(activity: self?.activity ?? .dormant)
            },
            notificationCenter: events
        )
    }

    override func tearDown() {
        center = nil
        store = nil
        events = nil
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        super.tearDown()
    }

    func testSnoozePersistsBothDatesAndRunningSnapshotAcrossRelaunch() throws {
        activity = .working
        let deadline = now.addingTimeInterval(3_600)
        center.snooze(sessionID, until: deadline)

        let stored = try XCTUnwrap(store.session(withID: sessionID))
        XCTAssertEqual(stored.snoozedAt, now)
        XCTAssertEqual(stored.snoozedUntil, deadline)
        XCTAssertTrue(stored.hadTurnInFlightWhenSnoozed)
        XCTAssertTrue(stored.isSnoozed(at: now))

        let reopened = ProjectStore(stateManager: StateManager(appSupportDirectory: directory))
        let restored = try XCTUnwrap(reopened.session(withID: sessionID))
        XCTAssertEqual(restored.snoozedAt, now)
        XCTAssertEqual(restored.snoozedUntil, deadline)
        XCTAssertTrue(restored.hadTurnInFlightWhenSnoozed)
        XCTAssertFalse(restored.isArchived, "Snooze changed filing state")
        XCTAssertEqual(activity, .working, "Snooze changed unread/running activity")
    }

    func testRelaunchMaterializesAnExpiredPersistedSnooze() throws {
        let deadline = now.addingTimeInterval(60)
        center.snooze(sessionID, until: deadline)
        center = nil
        now = deadline.addingTimeInterval(600)

        store = ProjectStore(stateManager: StateManager(appSupportDirectory: directory))
        let relaunched = SessionSnoozeCenter(
            projectStore: store,
            now: { [weak self] in self?.now ?? .distantPast },
            activity: { _ in .dormant },
            runtime: { _ in .dormant },
            notificationCenter: NotificationCenter()
        )
        relaunched.start()

        XCTAssertEqual(
            try XCTUnwrap(store.session(withID: sessionID)).wake,
            SessionWake(reason: .timeReached, wokeAt: deadline)
        )
    }

    func testExpiryIsDerivedFromPersistedDeadlineAndSurvivesMissedTimer() throws {
        let deadline = now.addingTimeInterval(60)
        center.snooze(sessionID, until: deadline)
        now = deadline.addingTimeInterval(10)

        XCTAssertFalse(try XCTUnwrap(store.session(withID: sessionID)).isSnoozed(at: now))
        center.refreshAfterClockChange()

        let woke = try XCTUnwrap(store.session(withID: sessionID))
        XCTAssertNil(woke.snoozedAt)
        XCTAssertEqual(woke.wake, SessionWake(reason: .timeReached, wokeAt: deadline))
    }

    func testImportantNewEdgesWakeEarly() throws {
        for reason in [
            SessionWakeReason.approvalRequested,
            .inputRequested,
            .failed
        ] {
            center.snooze(sessionID, until: now.addingTimeInterval(3_600))
            center.record(reason, for: sessionID)
            XCTAssertEqual(store.session(withID: sessionID)?.wake?.reason, reason)
            store.acknowledgeWake(for: sessionID)
        }
    }

    func testOnlyCompletionOfTurnAlreadyRunningAtSnoozeWakes() {
        activity = .idle
        center.snooze(sessionID, until: now.addingTimeInterval(3_600))
        center.record(.turnCompleted, for: sessionID)
        XCTAssertTrue(center.isSnoozed(sessionID))

        center.unsnooze(sessionID)
        activity = .working
        center.snooze(sessionID, until: now.addingTimeInterval(3_600))
        center.record(.turnCompleted, for: sessionID)
        XCTAssertEqual(store.session(withID: sessionID)?.wake?.reason, .turnCompleted)
    }

    func testTypedCompletionAndPresentationAttentionWakeForTheirOwnReasons() {
        center.start()
        activity = .working
        center.snooze(sessionID, until: now.addingTimeInterval(3_600))
        activity = .idle
        events.post(SessionRuntimeDidChange(
            sessionID: sessionID,
            transition: SessionRuntimeTransition(
                previous: .test(activity: .working),
                current: .test(activity: .idle)
            ),
            cause: nil
        ))
        XCTAssertEqual(store.session(withID: sessionID)?.wake?.reason, .turnCompleted)

        store.acknowledgeWake(for: sessionID)
        activity = .working
        center.snooze(sessionID, until: now.addingTimeInterval(3_600))
        activity = .awaitingUser
        events.post(SessionActivityDidChange(sessionID: sessionID))
        XCTAssertEqual(store.session(withID: sessionID)?.wake?.reason, .inputRequested)
    }

    func testStaleFailureAndBackwardClockDoNotWakeImmediately() {
        store.update(sessionID: sessionID) { $0.lastExitCode = 1 }
        center.snooze(sessionID, until: now.addingTimeInterval(3_600))
        XCTAssertNil(store.session(withID: sessionID)?.wake, "old exit state became a new edge")

        now = now.addingTimeInterval(-3_600)
        XCTAssertTrue(center.isSnoozed(sessionID), "a backwards clock step resurfaced the row")
        center.record(.failed, for: sessionID)
        XCTAssertNil(store.session(withID: sessionID)?.wake, "an event dated before Snooze woke it")
    }

    func testPinningIsOrthogonalAndArchiveClearsOverlayBeforeRestore() throws {
        store.setPinned(true, for: sessionID)
        center.snooze(sessionID, until: now.addingTimeInterval(3_600))
        XCTAssertTrue(try XCTUnwrap(store.session(withID: sessionID)).isPinned)

        store.setArchived(true, for: sessionID)
        var archived = try XCTUnwrap(store.session(withID: sessionID))
        XCTAssertTrue(archived.isArchived)
        XCTAssertTrue(archived.isPinned)
        XCTAssertNil(archived.snoozedAt)
        XCTAssertNil(archived.wake)

        store.setArchived(false, for: sessionID)
        archived = try XCTUnwrap(store.session(withID: sessionID))
        XCTAssertFalse(archived.isArchived)
        XCTAssertFalse(archived.isSnoozed(at: now), "Restore resurrected a visibility overlay")
    }

    func testWakeReceiptIsSharedAndClearedByAcknowledgement() {
        center.snooze(sessionID, until: now.addingTimeInterval(3_600))
        center.record(.approvalRequested, for: sessionID)

        let anotherWindow = SessionSnoozeCenter(
            projectStore: store,
            now: { [weak self] in self?.now ?? .distantPast },
            activity: { _ in .idle },
            runtime: { _ in .test(activity: .idle) },
            notificationCenter: NotificationCenter()
        )
        XCTAssertEqual(store.session(withID: sessionID)?.wake?.reason, .approvalRequested)
        anotherWindow.acknowledge(sessionID)
        XCTAssertNil(store.session(withID: sessionID)?.wake)
    }

    func testOlderSessionPayloadDefaultsToNoSnooze() throws {
        let session = AgentSession(kind: .claude, title: "Older")
        let encoded = try JSONEncoder().encode(session)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "snoozedAt")
        object.removeValue(forKey: "snoozedUntil")
        object.removeValue(forKey: "hadTurnInFlightWhenSnoozed")
        object.removeValue(forKey: "wake")

        let oldData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(AgentSession.self, from: oldData)
        XCTAssertNil(decoded.snoozedAt)
        XCTAssertNil(decoded.snoozedUntil)
        XCTAssertFalse(decoded.hadTurnInFlightWhenSnoozed)
        XCTAssertNil(decoded.wake)
    }
}

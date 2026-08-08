import XCTest

@testable import Threading

/// What the store will keep, what it refuses, and what it drops when the thing a send was
/// addressed to stops existing.
///
/// Every case drives a store rooted in a scratch directory. The bundle is hosted in the app, so
/// a store that resolved Application Support would have each run editing the developer's own
/// scheduled sends — the file-store twin of the `UserDefaults` trap CLAUDE.md records.
@MainActor
final class ScheduledMessageStoreTests: XCTestCase {

    // MARK: - Fixture

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("scheduled-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        super.tearDown()
    }

    private func makeStore() -> ScheduledMessageStore {
        ScheduledMessageStore(directory: directory, center: NotificationCenter())
    }

    private var storeFile: URL {
        directory.appendingPathComponent(ScheduledMessageDefaults.fileName)
    }

    private let now = Date(timeIntervalSince1970: 1_775_000_000)

    private func message(
        dueIn seconds: TimeInterval = 3_600,
        to sessionID: SessionID = SessionID(),
        text: String = "Pick this up",
        anchor: ScheduledMessage.Anchor = .wallClock
    ) -> ScheduledMessage {
        ScheduledMessage(
            dueAt: now.addingTimeInterval(seconds),
            target: .session(sessionID),
            text: text,
            anchor: anchor
        )
    }

    private func sessionStart(
        in projectID: ProjectID,
        dueIn seconds: TimeInterval = 3_600
    ) -> ScheduledMessage {
        ScheduledMessage(
            dueAt: now.addingTimeInterval(seconds),
            target: .newSession(
                ScheduledSessionPlan(
                    projectID: projectID,
                    kind: .claude,
                    accountHandle: .standard,
                    model: nil,
                    reasoningEffort: nil,
                    fastMode: true,
                    branch: nil,
                    usesNativeUI: true,
                    permissionMode: nil
                )
            ),
            text: "Start on the importer"
        )
    }

    // MARK: - Taking Work

    func testAcceptsAndReadsBackASend() {
        let store = makeStore()
        let session = SessionID()

        XCTAssertNoThrow(try store.add(message(to: session), now: now).get())
        XCTAssertEqual(store.messages(for: session).count, 1)
        XCTAssertEqual(store.all.first?.text, "Pick this up")
    }

    func testOrdersEverythingSoonestFirst() {
        let store = makeStore()
        store.add(message(dueIn: 7_200, text: "later"), now: now)
        store.add(message(dueIn: 600, text: "sooner"), now: now)

        XCTAssertEqual(store.all.map(\.text), ["sooner", "later"])
    }

    func testRefusesAMomentThatHasAlreadyPassed() {
        let store = makeStore()

        XCTAssertEqual(
            store.add(message(dueIn: -60), now: now).failure,
            .inThePast,
            "A send scheduled into the past would fire on the next tick, which nobody asked for"
        )
    }

    func testRefusesAnEmptySend() {
        let store = makeStore()
        let empty = ScheduledMessage(
            dueAt: now.addingTimeInterval(60),
            target: .session(SessionID()),
            text: "   "
        )

        XCTAssertEqual(store.add(empty, now: now).failure, .empty)
    }

    func testRefusesRatherThanEvictingWhenOneTargetIsFull() {
        let store = makeStore()
        let session = SessionID()
        for index in 0..<ScheduledMessageDefaults.maximumPerTarget {
            store.add(message(dueIn: TimeInterval(60 * (index + 1)), to: session), now: now)
        }

        XCTAssertEqual(
            store.add(message(to: session), now: now).failure,
            .targetFull(limit: ScheduledMessageDefaults.maximumPerTarget)
        )
        XCTAssertEqual(
            store.messages(for: session).count,
            ScheduledMessageDefaults.maximumPerTarget,
            "A full queue must say so rather than quietly dropping the oldest thing written"
        )
    }

    func testRefusesWhenTheWholeStoreIsFull() {
        let store = makeStore()
        for index in 0..<ScheduledMessageDefaults.maximumTotal {
            store.add(message(dueIn: TimeInterval(60 * (index + 1))), now: now)
        }

        XCTAssertEqual(
            store.add(message(), now: now).failure,
            .storeFull(limit: ScheduledMessageDefaults.maximumTotal)
        )
    }

    // MARK: - Claiming

    func testAClaimedSendCannotBeClaimedTwice() {
        let store = makeStore()
        guard let armed = try? store.add(message(), now: now).get() else {
            return XCTFail("The store should have taken it")
        }

        XCTAssertNotNil(store.claim(armed.id))
        XCTAssertNil(
            store.claim(armed.id),
            """
            Two performers observing one due event must not both send. The hosted test bundle \
            builds several MainWindowControllers, so this is not hypothetical.
            """
        )
    }

    func testAClaimedSendIsNotOfferedAsDueAgain() {
        let store = makeStore()
        guard let armed = try? store.add(message(dueIn: 60), now: now).get() else {
            return XCTFail("The store should have taken it")
        }
        let afterDue = now.addingTimeInterval(120)

        XCTAssertEqual(store.due(at: afterDue).count, 1)
        _ = store.claim(armed.id)
        XCTAssertTrue(store.due(at: afterDue).isEmpty)
    }

    func testRelinquishingPutsASendBackInPlay() {
        let store = makeStore()
        guard let armed = try? store.add(message(dueIn: 60), now: now).get() else {
            return XCTFail("The store should have taken it")
        }
        _ = store.claim(armed.id)
        store.relinquish(armed.id)

        XCTAssertNotNil(store.claim(armed.id), "A send the surface could not take is still owed")
    }

    func testCompletingRemovesTheRecordEntirely() {
        let store = makeStore()
        guard let armed = try? store.add(message(), now: now).get() else {
            return XCTFail("The store should have taken it")
        }
        _ = store.claim(armed.id)
        store.complete(armed.id)

        XCTAssertTrue(
            store.all.isEmpty,
            "The conversation it landed in is the record now; a second copy here would be litter"
        )
    }

    func testFailingKeepsTheRecordForTheUser() {
        let store = makeStore()
        guard let armed = try? store.add(message(), now: now).get() else {
            return XCTFail("The store should have taken it")
        }
        _ = store.claim(armed.id)
        store.fail(armed.id, reason: "Its project folder is gone")

        XCTAssertEqual(store[armed.id]?.state, .failed("Its project folder is gone"))
        XCTAssertEqual(store.needingAttention.count, 1)
    }

    // MARK: - The Clock Passing While Nobody Watched

    func testAMomentPassedWhileQuitBecomesMissedAndIsNeverSent() {
        let store = makeStore()
        store.add(message(dueIn: 60), now: now)
        store.add(message(dueIn: 86_400), now: now)

        let missed = store.markMissed(before: now.addingTimeInterval(3_600))

        XCTAssertEqual(missed.count, 1)
        XCTAssertEqual(store.needingAttention.count, 1)
        XCTAssertTrue(
            store.due(at: now.addingTimeInterval(3_600)).isEmpty,
            """
            A missed send must not still read as due. There is no grace window: the app does not \
            send what the clock passed while it was not running.
            """
        )
    }

    func testMissedSendsAreNotMarkedTwice() {
        let store = makeStore()
        store.add(message(dueIn: 60), now: now)
        _ = store.markMissed(before: now.addingTimeInterval(3_600))

        XCTAssertTrue(store.markMissed(before: now.addingTimeInterval(7_200)).isEmpty)
    }

    func testWallClockMomentsAreReDerivedButResetAnchoredOnesAreNot() {
        let store = makeStore()
        let calendar = Calendar(identifier: .gregorian)
        var stockholm = calendar
        stockholm.timeZone = TimeZone(identifier: "Europe/Stockholm")!

        let wallClock = ScheduledMessage(
            dueAt: now.addingTimeInterval(3_600),
            timeZone: TimeZone(identifier: "Europe/Stockholm")!,
            calendar: calendar,
            target: .session(SessionID()),
            text: "Nine tomorrow, wherever I am"
        )
        let reset = message(dueIn: 3_600, anchor: .usageWindowReset(windowID: "5h"))
        store.add(wallClock, now: now)
        store.add(reset, now: now)

        let originalReset = store[reset.id]?.dueAt
        _ = store.reanchorWallClockMoments(calendar: calendar)

        XCTAssertEqual(
            store[reset.id]?.dueAt,
            originalReset,
            "A window's reset is an instant, not a time of day — moving it would be a bug"
        )
    }

    // MARK: - Lifecycle

    func testForgettingASessionDropsWhatWasAddressedToIt() {
        let store = makeStore()
        let doomed = SessionID()
        let survivor = SessionID()
        store.add(message(to: doomed), now: now)
        store.add(message(to: survivor), now: now)

        store.forget(sessionID: doomed)

        XCTAssertTrue(store.messages(for: doomed).isEmpty)
        XCTAssertEqual(store.messages(for: survivor).count, 1)
    }

    func testForgettingAProjectDropsItsScheduledStarts() {
        let store = makeStore()
        let project = ProjectID()
        store.add(sessionStart(in: project), now: now)
        store.add(sessionStart(in: ProjectID()), now: now)

        store.forget(projectID: project)

        XCTAssertTrue(store.sessionStarts(in: project).isEmpty)
        XCTAssertEqual(store.all.count, 1)
    }

    func testRetainOnlySweepsTargetsThatNoLongerExist() {
        let store = makeStore()
        let keptSession = SessionID()
        let keptProject = ProjectID()
        store.add(message(to: keptSession), now: now)
        store.add(message(to: SessionID()), now: now)
        store.add(sessionStart(in: keptProject), now: now)
        store.add(sessionStart(in: ProjectID()), now: now)

        store.retainOnly(sessionIDs: [keptSession], projectIDs: [keptProject])

        XCTAssertEqual(store.all.count, 2)
    }

    // MARK: - Persistence

    func testSurvivesBeingReadBackFromDisk() {
        let session = SessionID()
        let written = makeStore()
        written.add(message(to: session, text: "Still here tomorrow"), now: now)

        let reopened = makeStore()

        XCTAssertEqual(reopened.messages(for: session).first?.text, "Still here tomorrow")
    }

    func testAnUnreadableFileIsMovedAsideRatherThanOverwritten() throws {
        try Data("not json at all".utf8).write(to: storeFile)

        let store = makeStore()

        XCTAssertTrue(store.all.isEmpty, "An unreadable file reads as nothing stored")
        let siblings = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(
            siblings.contains { $0.hasPrefix("\(ScheduledMessageDefaults.fileName).unreadable") },
            """
            The bytes are kept. A build that cannot read them is not licensed to destroy what \
            the build that wrote them could — the standing rule for every store here.
            """
        )
    }

    func testTheStoredShapeCarriesNoImagePaths() throws {
        let store = makeStore()
        store.add(message(text: "No pictures here"), now: now)

        let written = try String(contentsOf: storeFile, encoding: .utf8)

        XCTAssertFalse(
            written.lowercased().contains("attachmentpath"),
            """
            Images are deliberately unschedulable: a pasted screenshot is a temporary file, and \
            a path recorded now can name nothing by Monday. If this key ever appears, the \
            composer has started promising something the disk cannot keep.
            """
        )
    }
}

// MARK: - Result Convenience

private extension Result {
    var failure: Failure? {
        guard case .failure(let error) = self else { return nil }
        return error
    }
}

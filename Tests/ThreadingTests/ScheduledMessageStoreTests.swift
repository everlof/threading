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
        reserving sessionID: SessionID? = nil,
        dueIn seconds: TimeInterval = 3_600
    ) -> ScheduledMessage {
        ScheduledMessage(
            dueAt: now.addingTimeInterval(seconds),
            target: .newSession(
                ScheduledSessionPlan(
                    reservedSessionID: sessionID,
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
        XCTAssertTrue(store.hasClockWorkPending)
    }

    /// Automatic recovery shares the durable queue with user-authored schedules, so its purpose
    /// and originating refusal must survive both persistence and a reset re-arm.
    func testLimitRecoveryProvenanceSurvivesPersistenceAndRescheduling() throws {
        let store = makeStore()
        let recovery = ScheduledMessage(
            dueAt: now.addingTimeInterval(3_600),
            target: .session(SessionID()),
            text: "continue",
            anchor: .usageWindowReset(windowID: "5h"),
            purpose: .limitRecovery,
            limitRecoveryRecordID: "refusal-two"
        )
        try store.add(recovery, now: now).get()

        let reopened = makeStore()
        let persisted = try XCTUnwrap(reopened[recovery.id])
        XCTAssertEqual(persisted.purpose, .limitRecovery)
        XCTAssertEqual(persisted.limitRecoveryRecordID, "refusal-two")
        XCTAssertTrue(persisted.isOwedLimitRecoveryContinuation)

        let rearmed = persisted.rescheduled(to: now.addingTimeInterval(7_200))
        XCTAssertEqual(rearmed.purpose, .limitRecovery)
        XCTAssertEqual(rearmed.limitRecoveryRecordID, "refusal-two")
    }

    /// Once the provider produces a newer outcome, the recovery promise is fulfilled. Cancelling
    /// it must not touch a user's own message aimed at the same reset.
    func testClearingARefusalCancelsOnlyAutomaticRecoveryContinuations() throws {
        let store = makeStore()
        let sessionID = SessionID()
        let userPreset = message(
            to: sessionID,
            text: "Review the result",
            anchor: .usageWindowReset(windowID: "5h")
        )
        let recovery = ScheduledMessage(
            dueAt: now.addingTimeInterval(3_600),
            target: .session(sessionID),
            text: "continue",
            anchor: .usageWindowReset(windowID: "5h"),
            purpose: .limitRecovery,
            limitRecoveryRecordID: "refusal-one"
        )
        try store.add(userPreset, now: now).get()
        try store.add(recovery, now: now).get()

        XCTAssertTrue(store.cancelLimitRecoveryContinuations(for: sessionID))

        XCTAssertEqual(store.messages(for: sessionID).map(\.id), [userPreset.id])
        XCTAssertEqual(makeStore().messages(for: sessionID).map(\.id), [userPreset.id])
    }

    func testBankedResetReleasesOnlyExistingOwedRecoveryContinuations() throws {
        let store = makeStore()
        let matching = SessionID()
        let other = SessionID()
        let armed = ScheduledMessage(
            dueAt: now.addingTimeInterval(3_600),
            target: .session(matching),
            text: "continue one",
            anchor: .usageWindowReset(windowID: "5h"),
            purpose: .limitRecovery
        )
        let waiting = ScheduledMessage(
            dueAt: now.addingTimeInterval(7_200),
            target: .session(matching),
            text: "continue two",
            anchor: .usageWindowReset(windowID: "7d"),
            state: .waiting("busy"),
            purpose: .limitRecovery
        )
        let userMessage = message(
            to: matching,
            text: "ordinary",
            anchor: .usageWindowReset(windowID: "5h")
        )
        let otherRecovery = ScheduledMessage(
            dueAt: now.addingTimeInterval(3_600),
            target: .session(other),
            text: "other",
            anchor: .usageWindowReset(windowID: "5h"),
            purpose: .limitRecovery
        )
        for value in [armed, waiting, userMessage, otherRecovery] {
            try store.add(value, now: now).get()
        }

        let releaseAt = now.addingTimeInterval(30)
        XCTAssertEqual(
            store.releaseLimitRecoveryContinuations(for: [matching], dueAt: releaseAt),
            2
        )
        XCTAssertEqual(store[armed.id]?.dueAt, releaseAt)
        XCTAssertEqual(store[waiting.id]?.dueAt, releaseAt)
        XCTAssertEqual(store[armed.id]?.state, .armed)
        XCTAssertEqual(store[waiting.id]?.state, .armed)
        XCTAssertEqual(store[armed.id]?.text, "continue one")
        XCTAssertEqual(store[userMessage.id]?.dueAt, userMessage.dueAt)
        XCTAssertEqual(store[otherRecovery.id]?.dueAt, otherRecovery.dueAt)
        XCTAssertEqual(makeStore()[waiting.id]?.dueAt, releaseAt)
    }

    func testAReservedSessionStartIsAddressableByItsConversationID() throws {
        let store = makeStore()
        let projectID = ProjectID()
        let sessionID = SessionID()
        let start = sessionStart(in: projectID, reserving: sessionID)

        XCTAssertNoThrow(try store.add(start, now: now).get())
        XCTAssertEqual(store.scheduledStart(for: sessionID)?.id, start.id)
        XCTAssertEqual(store.messages(for: sessionID).map(\.id), [start.id])

        let reopened = makeStore()
        XCTAssertEqual(
            reopened.scheduledStart(for: sessionID)?.target.sessionID,
            sessionID,
            "the sidebar identity disappeared after the scheduled record was decoded"
        )
    }

    func testAcceptsAFinishTriggerWithoutInventingAClockTime() {
        let store = makeStore()
        let watched = SessionID()
        let message = ScheduledMessage(
            createdAt: now,
            whenSessionFinishes: watched,
            target: .session(SessionID()),
            text: "Review what it produced"
        )

        XCTAssertNoThrow(try store.add(message, now: now).get())
        XCTAssertNil(store[message.id]?.dueAt)
        XCTAssertTrue(store.due(at: now.addingTimeInterval(86_400)).isEmpty)
        XCTAssertEqual(store.dueWhenSessionFinishes(watched).map(\.id), [message.id])
        XCTAssertFalse(
            store.hasClockWorkPending,
            "an activity edge needs no five-minute polling heartbeat"
        )
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

    func testStartNowMakesAnAttentionItemClaimableAgain() throws {
        let store = makeStore()
        let start = try store.add(message(), now: now).get()
        XCTAssertTrue(store.setState(.missed, for: start.id))
        XCTAssertNil(store.claim(start.id))

        XCTAssertTrue(store.prepareForImmediateAttempt(start.id))
        XCTAssertNotNil(store.claim(start.id))
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

    func testAClaimedSendIsNotReclassifiedWhileItsPerformerOwnsIt() throws {
        let store = makeStore()
        let message = try store.add(message(dueIn: 60), now: now).get()
        XCTAssertNotNil(store.claim(message.id))

        XCTAssertTrue(store.markMissed(before: now.addingTimeInterval(3_600)).isEmpty)
        XCTAssertEqual(store[message.id]?.state, .armed)
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

    func testDeletingAConversationWatchedByAnotherSendKeepsTheWordsAndFailsIt() {
        let store = makeStore()
        let watched = SessionID()
        let target = SessionID()
        let message = ScheduledMessage(
            createdAt: now,
            whenSessionFinishes: watched,
            target: .session(target),
            text: "Use the finished result"
        )
        store.add(message, now: now)

        store.forget(sessionID: watched)

        XCTAssertEqual(store.messages(for: target).map(\.text), ["Use the finished result"])
        guard case .failed = store[message.id]?.state else {
            return XCTFail("Deleting the watched conversation must not delete user-authored text")
        }
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

    func testForgettingAProjectBatchesSessionTargetsAndWatchedSessions() {
        let store = makeStore()
        let project = ProjectID()
        let first = SessionID()
        let second = SessionID()
        let survivor = SessionID()
        store.add(message(to: first, text: "First"), now: now)
        store.add(message(to: second, text: "Second"), now: now)
        store.add(sessionStart(in: project), now: now)
        let waiting = ScheduledMessage(
            createdAt: now,
            whenSessionFinishes: second,
            target: .session(survivor),
            text: "Keep these words"
        )
        store.add(waiting, now: now)

        store.forget(sessionIDs: [first, second], projectID: project)

        XCTAssertTrue(store.messages(for: first).isEmpty)
        XCTAssertTrue(store.messages(for: second).isEmpty)
        XCTAssertTrue(store.sessionStarts(in: project).isEmpty)
        XCTAssertEqual(store.messages(for: survivor).map(\.text), ["Keep these words"])
        guard case .failed = store[waiting.id]?.state else {
            return XCTFail("the retained send must report that its watched session was deleted")
        }
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

    func testAFailedAddIsRefusedAndNeverBecomesCurrentOnlyInMemory() throws {
        let blockedDirectory = directory.appendingPathComponent("not-a-directory")
        try Data("occupied".utf8).write(to: blockedDirectory)
        let store = ScheduledMessageStore(
            directory: blockedDirectory,
            center: NotificationCenter()
        )

        let result = store.add(message(), now: now)

        XCTAssertEqual(result.failure, .writesBlocked)
        XCTAssertTrue(
            store.all.isEmpty,
            "A scheduled send is accepted only after its sole durable copy is verified"
        )
    }

    func testAFailedRemovalKeepsTheRecordAndStopsUnattendedDelivery() throws {
        let mutableDirectory = directory.appendingPathComponent("mutable", isDirectory: true)
        try FileManager.default.createDirectory(
            at: mutableDirectory,
            withIntermediateDirectories: true
        )
        let store = ScheduledMessageStore(
            directory: mutableDirectory,
            center: NotificationCenter()
        )
        let scheduled = try store.add(message(dueIn: 60), now: now).get()

        try FileManager.default.removeItem(at: mutableDirectory)
        try Data("occupied".utf8).write(to: mutableDirectory)

        XCTAssertFalse(store.remove(scheduled.id))
        XCTAssertEqual(store.all.map(\.id), [scheduled.id])
        XCTAssertNil(
            store.claim(scheduled.id),
            "Once outcomes cannot be recorded, unattended sends must stand down"
        )
        XCTAssertTrue(store.due(at: now.addingTimeInterval(120)).isEmpty)
        XCTAssertFalse(store.hasClockWorkPending)
    }

    func testFinishTriggerSurvivesBeingReadBackFromDisk() {
        let watched = SessionID()
        let written = makeStore()
        let message = ScheduledMessage(
            createdAt: now,
            whenSessionFinishes: watched,
            target: .session(SessionID()),
            text: "Still waiting on that turn"
        )
        written.add(message, now: now)

        let reopened = makeStore()

        XCTAssertEqual(reopened[message.id]?.trigger, .sessionFinished(watched))
    }

    func testPreTriggerStoredShapeStillDecodes() throws {
        let legacy = LegacyScheduledMessage(
            id: ScheduledMessageID(),
            createdAt: now,
            dueAt: now.addingTimeInterval(3_600),
            intendedTimeZoneIdentifier: TimeZone.current.identifier,
            intendedWallClock: Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: now.addingTimeInterval(3_600)
            ),
            target: .session(SessionID()),
            text: "Written by the previous release",
            context: [],
            anchor: .wallClock,
            state: .armed,
            resetRearmCount: 0
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(LegacyScheduledMessagesFile(messages: [legacy])).write(to: storeFile)

        let reopened = makeStore()

        XCTAssertEqual(reopened.all.first?.text, "Written by the previous release")
        XCTAssertEqual(
            reopened.all.first?.purpose,
            .userAuthored,
            "An old record cannot be guessed to be automation merely because it targets a reset"
        )
        guard case .time = reopened.all.first?.trigger else {
            return XCTFail("The pre-trigger clock fields should migrate into a time trigger")
        }
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

private struct LegacyScheduledMessagesFile: Codable {
    let messages: [LegacyScheduledMessage]
}

private struct LegacyScheduledMessage: Codable {
    let id: ScheduledMessageID
    let createdAt: Date
    let dueAt: Date
    let intendedTimeZoneIdentifier: String
    let intendedWallClock: DateComponents
    let target: ScheduledMessage.Target
    let text: String
    let context: [ConversationContextAttachment]
    let anchor: ScheduledMessage.Anchor
    let state: ScheduledMessage.State
    let resetRearmCount: Int
}

// MARK: - Result Convenience

private extension Result {
    var failure: Failure? {
        guard case .failure(let error) = self else { return nil }
        return error
    }
}

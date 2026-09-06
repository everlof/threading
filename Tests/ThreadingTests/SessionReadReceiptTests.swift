import os
import XCTest
@testable import Threading

@MainActor
final class SessionReadReceiptTests: XCTestCase {

    func testOwnerDevicesShareAReceiptWhileCollaboratorsRemainIndependent() {
        let persisted = OSAllocatedUnfairLock(
            initialState: [SessionID: SessionReadReceiptState]()
        )
        let store = SessionReadReceiptStore(
            load: { persisted.withLock { $0 } },
            save: { state in
                persisted.withLock { $0[state.sessionID] = state }
                return true
            }
        )
        let sessionID = SessionID()

        _ = store.recordAttention(for: sessionID, seenBy: [])
        XCTAssertTrue(store.hasUnread(
            sessionID: sessionID,
            participantID: SessionReadReceiptStore.ownerParticipantID
        ))
        XCTAssertTrue(store.hasUnread(sessionID: sessionID, participantID: "anna"))
        XCTAssertTrue(store.hasUnread(sessionID: sessionID, participantID: "priya"))

        // A visit from any owner device advances the one owner identity.
        XCTAssertTrue(store.acknowledge(
            sessionID: sessionID,
            participantID: SessionReadReceiptStore.ownerParticipantID
        ).didChangeProjection)
        XCTAssertFalse(store.hasUnread(
            sessionID: sessionID,
            participantID: SessionReadReceiptStore.ownerParticipantID
        ))
        XCTAssertTrue(store.hasUnread(sessionID: sessionID, participantID: "anna"))

        // Anna reading cannot spend Priya's receipt.
        XCTAssertTrue(store.acknowledge(
            sessionID: sessionID,
            participantID: "anna"
        ).didChangeProjection)
        XCTAssertFalse(store.hasUnread(sessionID: sessionID, participantID: "anna"))
        XCTAssertTrue(store.hasUnread(sessionID: sessionID, participantID: "priya"))
    }

    func testACompletionIsAlreadyReadForEveryIdentityViewingIt() {
        let persisted = OSAllocatedUnfairLock(
            initialState: [SessionID: SessionReadReceiptState]()
        )
        let store = SessionReadReceiptStore(
            load: { persisted.withLock { $0 } },
            save: { state in
                persisted.withLock { $0[state.sessionID] = state }
                return true
            }
        )
        let sessionID = SessionID()

        _ = store.recordAttention(
            for: sessionID,
            seenBy: [SessionReadReceiptStore.ownerParticipantID, "anna"]
        )

        XCTAssertFalse(store.hasUnread(
            sessionID: sessionID,
            participantID: SessionReadReceiptStore.ownerParticipantID
        ))
        XCTAssertFalse(store.hasUnread(sessionID: sessionID, participantID: "anna"))
        XCTAssertTrue(store.hasUnread(sessionID: sessionID, participantID: "priya"))
    }

    func testReceiptsSurviveAStoreRecreation() {
        let persisted = OSAllocatedUnfairLock(
            initialState: [SessionID: SessionReadReceiptState]()
        )
        func makeStore() -> SessionReadReceiptStore {
            SessionReadReceiptStore(
                load: { persisted.withLock { $0 } },
                save: { state in
                    persisted.withLock { $0[state.sessionID] = state }
                    return true
                }
            )
        }
        let sessionID = SessionID()
        let first = makeStore()
        _ = first.recordAttention(for: sessionID, seenBy: [])
        _ = first.acknowledge(sessionID: sessionID, participantID: "anna")

        let relaunched = makeStore()
        XCTAssertFalse(relaunched.hasUnread(sessionID: sessionID, participantID: "anna"))
        XCTAssertTrue(relaunched.hasUnread(sessionID: sessionID, participantID: "priya"))
    }

    func testOnlyUnreadIsReaderSpecific() {
        let sessionID = SessionID()
        let store = SessionReadReceiptStore(load: { [:] }, save: { _ in true })

        for shared in [SessionActivity.dormant, .working, .awaitingUser, .limitReached] {
            XCTAssertEqual(
                store.project(shared, sessionID: sessionID, participantID: "anna"),
                shared
            )
        }
        XCTAssertEqual(
            store.project(.needsAttention, sessionID: sessionID, participantID: "anna"),
            .idle,
            "a process-local unread bit cannot override Anna's durable receipt"
        )
    }

    func testFailedLoadIsUnknownAndNeverLooksRead() {
        let store = SessionReadReceiptStore(load: { nil }, save: { _ in true })
        let sessionID = SessionID()

        XCTAssertEqual(
            store.attention(sessionID: sessionID, participantID: "anna"),
            .unknown
        )
        XCTAssertTrue(store.hasUnread(sessionID: sessionID, participantID: "anna"))
        XCTAssertEqual(
            store.project(.idle, sessionID: sessionID, participantID: "anna"),
            .needsAttention
        )
        XCTAssertEqual(
            store.acknowledge(sessionID: sessionID, participantID: "anna").persistence,
            .unavailable
        )
    }

    func testFailedAcknowledgementWriteCannotClaimReadAndASecondVisitRetriesIt() {
        let persistence = OSAllocatedUnfairLock(
            initialState: (
                states: [SessionID: SessionReadReceiptState](),
                writesSucceed: true
            )
        )
        let store = SessionReadReceiptStore(
            load: { persistence.withLock { $0.states } },
            save: { state in
                persistence.withLock {
                    guard $0.writesSucceed else { return false }
                    $0.states[state.sessionID] = state
                    return true
                }
            }
        )
        let sessionID = SessionID()
        XCTAssertEqual(
            store.recordAttention(for: sessionID, seenBy: []).persistence,
            .committed
        )

        persistence.withLock { $0.writesSucceed = false }
        let refused = store.acknowledge(sessionID: sessionID, participantID: "anna")
        XCTAssertEqual(refused.persistence, .unavailable)
        XCTAssertEqual(
            store.attention(sessionID: sessionID, participantID: "anna"),
            .unknown
        )
        XCTAssertTrue(store.hasUnread(sessionID: sessionID, participantID: "anna"))

        persistence.withLock { $0.writesSucceed = true }
        let retried = store.acknowledge(sessionID: sessionID, participantID: "anna")
        XCTAssertEqual(retried.persistence, .committed)
        XCTAssertTrue(retried.didChangeProjection)
        XCTAssertEqual(
            store.attention(sessionID: sessionID, participantID: "anna"),
            .read(completionGeneration: 1, seenGeneration: 1)
        )
    }

    func testFailedAttentionWriteRemainsUnknownUntilTheWholeRecordCommits() {
        let writesSucceed = OSAllocatedUnfairLock(initialState: false)
        let store = SessionReadReceiptStore(
            load: { [:] },
            save: { _ in writesSucceed.withLock { $0 } }
        )
        let sessionID = SessionID()

        XCTAssertEqual(
            store.recordAttention(for: sessionID, seenBy: []).persistence,
            .unavailable
        )
        XCTAssertEqual(
            store.attention(sessionID: sessionID, participantID: "anna"),
            .unknown
        )

        writesSucceed.withLock { $0 = true }
        XCTAssertEqual(
            store.acknowledge(sessionID: sessionID, participantID: "anna").persistence,
            .committed
        )
        XCTAssertEqual(
            store.attention(sessionID: sessionID, participantID: "anna"),
            .read(completionGeneration: 1, seenGeneration: 1)
        )
    }

    func testTrackerReportsOneAttentionEpisodeForStopAndItsLateIdleNotice() {
        let tracker = SessionActivityTracker()
        var attentionCount = 0
        tracker.onAttention = { attentionCount += 1 }
        tracker.markRunning()
        tracker.isVisible = true

        tracker.noteTurnStarted()
        tracker.noteTurnFinished()
        tracker.noteAwaitingUser()
        XCTAssertEqual(attentionCount, 1)

        tracker.noteTurnStarted()
        tracker.noteTurnFinished()
        XCTAssertEqual(attentionCount, 2)
    }
}

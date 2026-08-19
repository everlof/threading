import XCTest
@testable import Threading

@MainActor
final class SessionReadReceiptTests: XCTestCase {

    func testOwnerDevicesShareAReceiptWhileCollaboratorsRemainIndependent() {
        var persisted: [SessionID: SessionReadReceiptState] = [:]
        let store = SessionReadReceiptStore(
            load: { persisted },
            save: {
                persisted[$0.sessionID] = $0
                return true
            }
        )
        let sessionID = SessionID()

        store.recordAttention(for: sessionID, seenBy: [])
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
        ))
        XCTAssertFalse(store.hasUnread(
            sessionID: sessionID,
            participantID: SessionReadReceiptStore.ownerParticipantID
        ))
        XCTAssertTrue(store.hasUnread(sessionID: sessionID, participantID: "anna"))

        // Anna reading cannot spend Priya's receipt.
        XCTAssertTrue(store.acknowledge(sessionID: sessionID, participantID: "anna"))
        XCTAssertFalse(store.hasUnread(sessionID: sessionID, participantID: "anna"))
        XCTAssertTrue(store.hasUnread(sessionID: sessionID, participantID: "priya"))
    }

    func testACompletionIsAlreadyReadForEveryIdentityViewingIt() {
        var persisted: [SessionID: SessionReadReceiptState] = [:]
        let store = SessionReadReceiptStore(
            load: { persisted },
            save: {
                persisted[$0.sessionID] = $0
                return true
            }
        )
        let sessionID = SessionID()

        store.recordAttention(
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
        var persisted: [SessionID: SessionReadReceiptState] = [:]
        func makeStore() -> SessionReadReceiptStore {
            SessionReadReceiptStore(
                load: { persisted },
                save: {
                    persisted[$0.sessionID] = $0
                    return true
                }
            )
        }
        let sessionID = SessionID()
        let first = makeStore()
        first.recordAttention(for: sessionID, seenBy: [])
        first.acknowledge(sessionID: sessionID, participantID: "anna")

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

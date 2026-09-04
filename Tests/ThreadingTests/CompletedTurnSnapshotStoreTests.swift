import XCTest
@testable import Threading

@MainActor
final class CompletedTurnSnapshotStoreTests: XCTestCase {
    func testGenerationIsNotReusedAfterSessionRemoval() {
        let store = CompletedTurnSnapshotStore()
        let sessionID = SessionID()

        let first = store.beginTurn(sessionID: sessionID)
        store.remove(sessionID: sessionID)
        let second = store.beginTurn(sessionID: sessionID)

        XCTAssertGreaterThan(second, first)
        XCTAssertNil(store.snapshot(sessionID: sessionID, generation: first))
    }

    func testCaptureWithoutBeginAllocatesARealGeneration() throws {
        let store = CompletedTurnSnapshotStore()
        let sessionID = SessionID()

        store.captureCompletedTurn(sessionID: sessionID, finalAssistantText: "Done")

        let generation = store.currentGeneration(sessionID: sessionID)
        XCTAssertGreaterThan(generation, 0)
        XCTAssertEqual(
            try XCTUnwrap(store.snapshot(sessionID: sessionID, generation: generation))
                .finalAssistantText,
            "Done"
        )
    }

    func testTrackedSessionBudgetEvictsOldestGenerationFailClosed() {
        let store = CompletedTurnSnapshotStore()
        var sessions: [SessionID] = []
        for _ in 0..<CompletedTurnSnapshotStore.maximumTrackedSessions {
            let sessionID = SessionID()
            sessions.append(sessionID)
            _ = store.beginTurn(sessionID: sessionID)
        }
        let oldest = sessions[0]
        let newest = SessionID()

        _ = store.beginTurn(sessionID: newest)

        XCTAssertEqual(
            store.trackedSessionCount,
            CompletedTurnSnapshotStore.maximumTrackedSessions
        )
        XCTAssertEqual(store.currentGeneration(sessionID: oldest), 0)
        XCTAssertGreaterThan(store.currentGeneration(sessionID: newest), 0)
    }

    func testCapturedTextIsBoundedWithoutSplittingUTF8() throws {
        let store = CompletedTurnSnapshotStore()
        let sessionID = SessionID()
        _ = store.beginTurn(sessionID: sessionID)
        store.captureCompletedTurn(
            sessionID: sessionID,
            finalAssistantText: String(repeating: "🧵", count: 20_000)
        )

        let snapshot = try XCTUnwrap(store.snapshot(
            sessionID: sessionID,
            generation: store.currentGeneration(sessionID: sessionID)
        ))
        let text = try XCTUnwrap(snapshot.finalAssistantText)
        XCTAssertLessThanOrEqual(
            text.utf8.count,
            CompletedTurnSnapshotStore.maximumCapturedUTF8Bytes
        )
        XCTAssertFalse(text.isEmpty)
    }
}

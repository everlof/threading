import XCTest
@testable import Threading

@MainActor
final class ConversationPreparedChildTests: XCTestCase {
    func testWorkerChildRetainsItsExitBeforeOneUIHandover() async throws {
        let id = SessionID()
        let plan = AgentLaunchPlan(executable: "/bin/sh", arguments: ["-c", "exit 7"], resumeState: .unavailable)
        let prepared = try await Task.detached {
            try ConversationPreparedChild(plan: plan, sessionID: id, host: nil)
        }.value
        // Reaping clears the real ownership record before the UI takes the child. This is the
        // fast-exit case that a worker handover must not turn into a missing lifecycle receipt.
        let deadline = Date().addingTimeInterval(2)
        while AgentChildLedger.shared.currentRecords.contains(where: { $0.sessionID == id.uuidString }), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(AgentChildLedger.shared.currentRecords.contains(where: { $0.sessionID == id.uuidString }))
        let received = expectation(description: "retained exit")
        let statuses = LockedState(initialState: [Int32]())
        let child = try prepared.take { status in
            statuses.withLock { $0.append(status) }
            received.fulfill()
        }
        defer { child.terminate() }
        XCTAssertThrowsError(try prepared.take { _ in XCTFail("second handover delivered an exit") })
        await fulfillment(of: [received], timeout: 2)
        XCTAssertEqual(statuses.withLock { $0 }, [7])
        XCTAssertFalse(child.isRunning)
    }
}

import XCTest
@testable import Skalman

final class MCPSessionRegistryTests: XCTestCase {

    func testConcurrentMintAndLookupPreservesBidirectionalMapping() {
        let sessionIDs = (0..<128).map { _ in SessionID() }
        let resultLock = NSLock()
        var mismatches: [(expected: SessionID, actual: SessionID?)] = []

        DispatchQueue.concurrentPerform(iterations: 4_096) { index in
            let expected = sessionIDs[index % sessionIDs.count]
            let token = MCPSessionRegistry.token(for: expected)
            let actual = MCPSessionRegistry.session(forToken: token)

            if actual != expected {
                resultLock.lock()
                mismatches.append((expected, actual))
                resultLock.unlock()
            }
        }

        XCTAssertTrue(mismatches.isEmpty)

        // Concurrent first use of one session must mint exactly one stable token.
        let sharedSessionID = SessionID()
        var sharedTokens: [String] = []
        DispatchQueue.concurrentPerform(iterations: 1_024) { _ in
            let token = MCPSessionRegistry.token(for: sharedSessionID)
            resultLock.lock()
            sharedTokens.append(token)
            resultLock.unlock()
        }

        XCTAssertEqual(Set(sharedTokens).count, 1)
        XCTAssertEqual(
            sharedTokens.first.flatMap(MCPSessionRegistry.session(forToken:)),
            sharedSessionID
        )
    }

    @MainActor
    func testRetainOnlyRevokesBothDirections() {
        let retainedSessionID = SessionID()
        let removedSessionID = SessionID()
        let retainedToken = MCPSessionRegistry.token(for: retainedSessionID)
        let removedToken = MCPSessionRegistry.token(for: removedSessionID)

        MCPSessionRegistry.retainOnly(sessionIDs: [retainedSessionID])

        XCTAssertEqual(MCPSessionRegistry.session(forToken: retainedToken), retainedSessionID)
        XCTAssertNil(MCPSessionRegistry.session(forToken: removedToken))
        XCTAssertEqual(MCPSessionRegistry.token(for: retainedSessionID), retainedToken)
    }
}

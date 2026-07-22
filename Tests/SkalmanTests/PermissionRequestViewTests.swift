import XCTest
@testable import Skalman

final class PermissionRequestViewTests: XCTestCase {

    private final class LifetimeToken {}

    func testResolveReleasesDecisionHandlerAndCallsItOnce() {
        var card: PermissionRequestView!
        weak var handlerLifetime: LifetimeToken?
        var decisionCount = 0

        autoreleasepool {
            let lifetime = LifetimeToken()
            handlerLifetime = lifetime
            card = PermissionRequestView(request: makeRequest()) { [lifetime] _ in
                _ = lifetime
                decisionCount += 1
            }
        }

        XCTAssertNotNil(handlerLifetime)

        card.resolve(.deny(reason: "Test decision"))
        card.resolve(.deny(reason: "Duplicate decision"))

        XCTAssertEqual(decisionCount, 1)
        XCTAssertNil(handlerLifetime)
    }

    func testResolvedCardDoesNotRetainItselfThroughControllerStyleClosure() {
        weak var cardReference: PermissionRequestView?

        autoreleasepool {
            var card: PermissionRequestView?
            card = PermissionRequestView(request: makeRequest()) { _ in
                // Matches ConversationViewController's closure, which compares its local card.
                _ = card
            }
            cardReference = card
            card?.resolve(.deny(reason: "Test decision"))
        }

        XCTAssertNil(cardReference)
    }

    private func makeRequest() -> PermissionRequest {
        PermissionRequest(sessionID: SessionID(), toolName: "Bash", input: ["command": "pwd"])
    }
}

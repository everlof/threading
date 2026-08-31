import XCTest
import ThreadingRemoteKit
@testable import ThreadingMobile

final class RemoteNotificationPresentationPolicyTests: XCTestCase {
    func testOnlyAnExplicitlyRequestedAgentUpdatePresentsInForeground() {
        for kind in RemoteNotificationKind.allCases {
            XCTAssertEqual(
                RemoteNotificationPresentationPolicy.presentsInForeground(kind),
                kind == .agentMessage,
                "Unexpected foreground presentation policy for \(kind.rawValue)"
            )
        }
    }
}

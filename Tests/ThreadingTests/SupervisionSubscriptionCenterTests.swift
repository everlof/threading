import XCTest

@testable import Threading

@MainActor
final class SupervisionSubscriptionCenterTests: XCTestCase {
    func testStandingSubscriptionDeliversSettlesAndUserLimitEdgesAsThreadingNotices() {
        let center = NotificationCenter()
        let managerID = SessionID()
        let childID = SessionID()
        let accountID = AccountID(
            provider: .claude,
            handle: AccountHandle(storedName: "work")
        )
        let supervision = Supervision(
            managerID: managerID,
            childID: childID,
            brief: "Run the focused suite"
        )
        var activityBySession: [SessionID: SessionActivity] = [
            managerID: .idle,
            childID: .working,
        ]
        var activeSupervision: Supervision? = supervision
        var events: [SupervisionEventKind] = []
        var deliveries: [(String, SessionID)] = []
        let subscriptions = SupervisionSubscriptionCenter(
            center: center,
            dependencies: .init(
                activity: { activityBySession[$0] ?? .dormant },
                title: { $0 == childID ? "Child" : "Manager" },
                accountID: { $0 == childID ? accountID : nil },
                supervision: { $0 == childID ? activeSupervision : nil },
                appendEvent: { kind, _, _ in events.append(kind) },
                deliver: { text, target, completion in
                    deliveries.append((text, target))
                    completion(.sentNow)
                }
            )
        )

        XCTAssertTrue(subscriptions.subscribe(managerID: managerID, childID: childID))
        activityBySession[childID] = .idle
        center.post(SessionActivityDidChange(sessionID: childID))

        XCTAssertEqual(events, [.settled])
        XCTAssertEqual(deliveries.first?.1, managerID)
        XCTAssertTrue(deliveries.first?.0.hasPrefix("[Session watch — Threading]") == true)
        XCTAssertTrue(deliveries.first?.0.contains("not that session's agent") == true)

        center.post(CustomLimitDidFire(accountID: accountID))
        XCTAssertEqual(events, [.settled, .limitNearing])
        XCTAssertTrue(deliveries.last?.0.contains("nearing a usage limit") == true)

        activeSupervision = nil
        center.post(SupervisionDidChange(managerID: managerID, childID: childID))
        XCTAssertFalse(subscriptions.isSubscribed(managerID: managerID, childID: childID))
        center.post(CustomLimitDidFire(accountID: accountID))
        XCTAssertEqual(events, [.settled, .limitNearing])
    }
}

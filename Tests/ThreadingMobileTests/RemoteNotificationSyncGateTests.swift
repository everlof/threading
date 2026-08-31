import XCTest
@testable import ThreadingMobile

@MainActor
final class RemoteNotificationSyncGateTests: XCTestCase {

    func testSerializesRefreshesAndCoalescesToNewestPendingValue() async {
        var started: [Int] = []
        var activeCount = 0
        var maximumActiveCount = 0
        var releaseFirst: CheckedContinuation<Void, Never>?
        let firstStarted = expectation(description: "first refresh started")

        let gate = RemoteNotificationSyncGate<Int> { value in
            started.append(value)
            activeCount += 1
            maximumActiveCount = max(maximumActiveCount, activeCount)

            if value == 1 {
                await withCheckedContinuation { continuation in
                    releaseFirst = continuation
                    firstStarted.fulfill()
                }
            }

            activeCount -= 1
        }

        let firstDrain = gate.request(1)
        await fulfillment(of: [firstStarted], timeout: 1)

        let secondDrain = gate.request(2)
        let thirdDrain = gate.request(3)
        releaseFirst?.resume()

        await firstDrain.value
        await secondDrain.value
        await thirdDrain.value

        XCTAssertEqual(started, [1, 3])
        XCTAssertEqual(maximumActiveCount, 1)
    }
}

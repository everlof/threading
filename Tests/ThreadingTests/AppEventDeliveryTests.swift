import Foundation
import XCTest
@testable import Threading

private struct ObserverFixtureEvent: AppEvent {
    static let name = Notification.Name("threading.test.observer.fixture")
    let value: Int
}

@MainActor
private final class ObserverReceipt {
    var values: [Int] = []
}

@MainActor
final class AppEventDeliveryTests: XCTestCase {
    func testDeliveryRemovalReuseAndOwnerLifetime() {
        let center = NotificationCenter()
        let receipt = ObserverReceipt()
        var observations: AppEventObservations? = AppEventObservations(center: center)
        observations?.observe(ObserverFixtureEvent.self) { receipt.values.append($0.value) }
        center.post(ObserverFixtureEvent(value: 1))
        XCTAssertEqual(receipt.values, [1])
        observations?.removeAll()
        center.post(ObserverFixtureEvent(value: 2))
        observations?.observe(ObserverFixtureEvent.self) { receipt.values.append($0.value) }
        center.post(ObserverFixtureEvent(value: 3))
        observations = nil
        center.post(ObserverFixtureEvent(value: 4))
        XCTAssertEqual(receipt.values, [1, 3])
    }

    func testWorkerDeliveryAndPlatformNotificationLifetime() async {
        let center = NotificationCenter()
        let receipt = ObserverReceipt()
        let observations = AppEventObservations(center: center)
        observations.observe(ObserverFixtureEvent.self) { receipt.values.append($0.value) }
        await Task.detached { center.post(ObserverFixtureEvent(value: 5)) }.value
        for _ in 0..<100 where receipt.values.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(receipt.values, [5])
        observations.removeAll()
        let name = Notification.Name("threading.test.platform.fixture")
        observations.observe(name) { receipt.values.append(6) }
        center.post(name: name, object: nil)
        observations.removeAll()
        center.post(name: name, object: nil)
        XCTAssertEqual(receipt.values, [5, 6])
    }
}

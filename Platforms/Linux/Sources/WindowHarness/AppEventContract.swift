import Foundation
import Dispatch

private struct FixtureEvent: AppEvent {
    static let name = Notification.Name("threading.linux.fixture.event")
    let value: Int
}

@MainActor
private final class EventReceipt {
    var values: [Int] = []
}

@MainActor
enum AppEventContract {
    static func run() async throws {
        let center = NotificationCenter()
        let receipt = EventReceipt()
        var observations: AppEventObservations? = AppEventObservations(center: center)
        observations?.observe(FixtureEvent.self) { event in receipt.values.append(event.value) }
        center.post(FixtureEvent(value: 1))
        guard receipt.values == [1] else { throw WindowFailure("typed app event was not delivered") }
        observations?.removeAll()
        center.post(FixtureEvent(value: 2))
        guard receipt.values == [1] else { throw WindowFailure("removed app observer still received an event") }
        observations?.observe(FixtureEvent.self) { event in receipt.values.append(event.value) }
        center.post(FixtureEvent(value: 3))
        observations = nil
        center.post(FixtureEvent(value: 4))
        guard receipt.values == [1, 3] else { throw WindowFailure("app observer lifetime was not retained or released") }
        let pending = AppEventObservations(center: center)
        pending.observe(FixtureEvent.self) { event in receipt.values.append(event.value) }
        let sent = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            center.post(FixtureEvent(value: 5))
            sent.signal()
        }
        guard sent.wait(timeout: .now() + 1) == .success else {
            throw WindowFailure("worker notification blocked on the occupied UI executor")
        }
        pending.removeAll()
        try await Task.sleep(for: .milliseconds(20))
        guard receipt.values == [1, 3] else { throw WindowFailure("retired generation received queued delivery") }
        pending.observe(FixtureEvent.self) { event in receipt.values.append(event.value) }
        await Task.detached { center.post(FixtureEvent(value: 6)) }.value
        try await Task.sleep(for: .milliseconds(20))
        guard receipt.values == [1, 3, 6] else { throw WindowFailure("worker notification did not reach the UI executor") }
        print("PASS production typed app events: main/worker delivery, removeAll, reuse, queued generation cancellation and lifetime cleanup")
    }
}

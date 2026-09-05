import XCTest
@testable import ThreadingMobile

/// A gallery's burst of downloads becomes a queue of them: never more than the capacity in
/// flight, every slot handed on, and a waiter that leaves not spending a slot on its way out.
final class MobileMediaDownloadLimiterTests: XCTestCase {
    func testNeverMoreThanTheCapacityRunAtOnce() async throws {
        let limiter = MobileMediaDownloadLimiter(capacity: 2)
        let gauge = Gauge()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try await limiter.run {
                        await gauge.enter()
                        try await Task.sleep(for: .milliseconds(20))
                        await gauge.leave()
                    }
                }
            }
            try await group.waitForAll()
        }

        let peak = await gauge.peak
        let total = await gauge.total
        XCTAssertEqual(peak, 2)
        XCTAssertEqual(total, 8)
        let inUse = await limiter.inUse
        XCTAssertEqual(inUse, 0, "every slot is released however the operation ends")
    }

    func testAFailingOperationStillReleasesItsSlot() async throws {
        let limiter = MobileMediaDownloadLimiter(capacity: 1)
        struct Failure: Error {}

        do {
            try await limiter.run { throw Failure() }
            XCTFail("the failure must propagate")
        } catch is Failure {}

        let inUse = await limiter.inUse
        XCTAssertEqual(inUse, 0)
        let value = try await limiter.run { 42 }
        XCTAssertEqual(value, 42, "the next caller takes the slot at once")
    }

    /// SwiftUI cancels a lazy cell's task the moment it scrolls away. Its waiter leaves the
    /// queue, throws cancellation, and never takes a turn.
    func testACancelledWaiterLeavesTheQueueWithoutTakingASlot() async throws {
        let limiter = MobileMediaDownloadLimiter(capacity: 1)
        let holder = Task {
            try await limiter.run {
                try await Task.sleep(for: .milliseconds(150))
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        let waiterRan = Ran()
        let waiter = Task {
            try await limiter.run { await waiterRan.mark() }
        }
        try await Task.sleep(for: .milliseconds(20))
        let queued = await limiter.waiting
        XCTAssertEqual(queued, 1)

        waiter.cancel()
        do {
            try await waiter.value
            XCTFail("a cancelled waiter throws")
        } catch is CancellationError {}

        try await holder.value
        let ran = await waiterRan.value
        XCTAssertFalse(ran, "a cancelled waiter must not run once the slot frees")
        let inUse = await limiter.inUse
        XCTAssertEqual(inUse, 0)
        let waiting = await limiter.waiting
        XCTAssertEqual(waiting, 0)
    }

    private actor Gauge {
        private(set) var current = 0
        private(set) var peak = 0
        private(set) var total = 0

        func enter() {
            current += 1
            total += 1
            peak = max(peak, current)
        }

        func leave() {
            current -= 1
        }
    }

    private actor Ran {
        private(set) var value = false
        func mark() { value = true }
    }
}

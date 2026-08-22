import XCTest
@testable import ThreadingMobile

@MainActor
final class MobileHostRefreshSingleFlightTests: XCTestCase {
    func testSessionReconnectEscalatesAfterOneCheapRouteRetry() {
        XCTAssertFalse(
            MobileConnectionRecoveryPolicy.sessionReconnectNeedsHostRecovery(attempt: 0)
        )
        XCTAssertTrue(
            MobileConnectionRecoveryPolicy.sessionReconnectNeedsHostRecovery(attempt: 1)
        )
        XCTAssertTrue(
            MobileConnectionRecoveryPolicy.sessionReconnectNeedsHostRecovery(attempt: 4)
        )
    }

    func testConcurrentWaitersRunOneHostRecovery() async {
        let coordinator = MobileHostRefreshSingleFlight()
        let gate = HostRefreshTestGate()
        let started = expectation(description: "shared recovery started")
        var firstOperationStarts = 0
        var secondOperationStarts = 0
        var secondReturned = false

        let first = Task { @MainActor in
            await coordinator.run(hostID: "mac") {
                firstOperationStarts += 1
                started.fulfill()
                await gate.wait()
            }
        }
        await fulfillment(of: [started], timeout: 1)

        let second = Task { @MainActor in
            await coordinator.run(hostID: "mac") {
                secondOperationStarts += 1
            }
            secondReturned = true
        }
        await Task.yield()

        XCTAssertEqual(firstOperationStarts, 1)
        XCTAssertEqual(secondOperationStarts, 0)
        XCTAssertFalse(secondReturned, "a joiner must await the shared route result")

        await gate.open()
        await first.value
        await second.value

        XCTAssertTrue(secondReturned)
        XCTAssertEqual(firstOperationStarts + secondOperationStarts, 1)
    }

    func testCancellingOneWaiterDoesNotCancelRecoveryForTheOthers() async {
        let coordinator = MobileHostRefreshSingleFlight()
        let gate = HostRefreshTestGate()
        let started = expectation(description: "shared recovery started")
        var sharedTaskWasCancelled = true
        var replacementOperationStarts = 0

        let first = Task { @MainActor in
            await coordinator.run(hostID: "mac") {
                started.fulfill()
                await gate.wait()
                sharedTaskWasCancelled = Task.isCancelled
            }
        }
        await fulfillment(of: [started], timeout: 1)
        first.cancel()

        let second = Task { @MainActor in
            await coordinator.run(hostID: "mac") {
                replacementOperationStarts += 1
            }
        }
        await gate.open()
        await first.value
        await second.value

        XCTAssertFalse(sharedTaskWasCancelled)
        XCTAssertEqual(replacementOperationStarts, 0)
    }

    func testExplicitInvalidationCancelsTheFlightAndAllowsRetry() async {
        let coordinator = MobileHostRefreshSingleFlight()
        let started = expectation(description: "old recovery started")
        var observedCancellation = false
        var retryStarts = 0

        let oldWaiter = Task { @MainActor in
            await coordinator.run(hostID: "old-mac") {
                started.fulfill()
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch is CancellationError {
                    observedCancellation = true
                } catch {
                    XCTFail("unexpected cancellation error: \(error)")
                }
            }
        }
        await fulfillment(of: [started], timeout: 1)

        coordinator.invalidate()
        await oldWaiter.value
        await coordinator.run(hostID: "new-mac") {
            retryStarts += 1
        }

        XCTAssertTrue(observedCancellation)
        XCTAssertEqual(retryStarts, 1)
    }

    func testCancelledFlightCannotClearItsReplacementWhenItFinishesLate() async {
        let coordinator = MobileHostRefreshSingleFlight()
        let oldStarted = expectation(description: "old recovery started")
        let newStarted = expectation(description: "new recovery started")
        let allowOldCompletion = HostRefreshTestGate()
        let allowNewCompletion = HostRefreshTestGate()
        var thirdOperationStarts = 0

        let oldWaiter = Task { @MainActor in
            await coordinator.run(hostID: "old-mac") {
                oldStarted.fulfill()
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    await allowOldCompletion.wait()
                }
            }
        }
        await fulfillment(of: [oldStarted], timeout: 1)
        coordinator.invalidate()

        let newWaiter = Task { @MainActor in
            await coordinator.run(hostID: "new-mac") {
                newStarted.fulfill()
                await allowNewCompletion.wait()
            }
        }
        await fulfillment(of: [newStarted], timeout: 1)

        await allowOldCompletion.open()
        await oldWaiter.value
        let thirdWaiter = Task { @MainActor in
            await coordinator.run(hostID: "new-mac") {
                thirdOperationStarts += 1
            }
        }
        await Task.yield()

        XCTAssertEqual(
            thirdOperationStarts,
            0,
            "the old completion must not remove the replacement flight"
        )

        await allowNewCompletion.open()
        await newWaiter.value
        await thirdWaiter.value
        XCTAssertEqual(thirdOperationStarts, 0)
    }

    func testACompletedFlightIsNotMemoizedAsARecoveryResult() async {
        let coordinator = MobileHostRefreshSingleFlight()
        var starts = 0

        await coordinator.run(hostID: "mac") { starts += 1 }
        await coordinator.run(hostID: "mac") { starts += 1 }

        XCTAssertEqual(starts, 2, "a later explicit refresh must perform fresh work")
    }
}

private actor HostRefreshTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        pending.forEach { $0.resume() }
    }
}

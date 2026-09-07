import XCTest
@testable import ThreadingMobile

@MainActor
final class MobileHostRefreshSingleFlightTests: XCTestCase {
    /// The cheap retry on the last authenticated route is for a socket the Mac closed on purpose.
    /// A socket that died without a close frame may have died of its route (2026-09-02: Wi-Fi
    /// went, the LAN origin stayed cached, and the first retry dialled it), and a dashboard
    /// recovery already scheduled is the same loss seen by the other socket on that route.
    func testOnlyASocketTheMacClosedGetsTheCheapRouteRetry() {
        let closedByMac = MobileSessionReconnectRequest(attempt: 0, peerSentClose: true)
        let lostOnTheWire = MobileSessionReconnectRequest(attempt: 0, peerSentClose: false)
        let closedThenLostAgain = MobileSessionReconnectRequest(attempt: 1, peerSentClose: true)

        XCTAssertFalse(
            MobileConnectionRecoveryPolicy.sessionReconnectNeedsHostRecovery(
                closedByMac,
                dashboardRecoveryPending: false
            ),
            "the address answered with a close frame, so the route is not what broke"
        )
        XCTAssertTrue(
            MobileConnectionRecoveryPolicy.sessionReconnectNeedsHostRecovery(
                lostOnTheWire,
                dashboardRecoveryPending: false
            ),
            "no close frame is evidence about the route, and the first retry re-resolves"
        )
        XCTAssertTrue(
            MobileConnectionRecoveryPolicy.sessionReconnectNeedsHostRecovery(
                closedThenLostAgain,
                dashboardRecoveryPending: false
            ),
            "a second loss escalates whatever the first looked like"
        )
        XCTAssertTrue(
            MobileConnectionRecoveryPolicy.sessionReconnectNeedsHostRecovery(
                closedByMac,
                dashboardRecoveryPending: true
            ),
            "a scheduled dashboard recovery is joined rather than raced by 72 ms"
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

    /// A notification registration wants the route a refresh is about to find, not a refresh of
    /// its own: joining waits for the flight in progress and starts nothing.
    func testJoiningWaitsForTheFlightInProgressAndStartsNone() async {
        let coordinator = MobileHostRefreshSingleFlight()
        let gate = HostRefreshTestGate()
        var starts = 0
        var finished = false

        let flight = Task { @MainActor in
            await coordinator.run(hostID: "mac") {
                starts += 1
                await gate.wait()
                finished = true
            }
        }
        while !coordinator.hasFlight(for: "mac") { await Task.yield() }

        let joiner = Task { @MainActor in await coordinator.join(hostID: "mac") }
        await Task.yield()
        XCTAssertFalse(finished, "the joiner is still waiting while the flight runs")

        await gate.open()
        await joiner.value
        await flight.value
        XCTAssertTrue(finished)
        XCTAssertEqual(starts, 1, "joining never starts a flight")

        await coordinator.join(hostID: "mac")
        await coordinator.join(hostID: "another-mac")
        XCTAssertEqual(starts, 1, "with nothing in flight, joining returns at once")
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

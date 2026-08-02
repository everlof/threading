import XCTest
@testable import Threading

/// `HoverPopoverScheduler` is pure timing policy: these drive the pointer reports and assert
/// when the owner is asked to present and dismiss. What gets presented is each owner's
/// business and is covered by that owner's own tests.
@MainActor
final class HoverPopoverSchedulerTests: XCTestCase {

    private final class Owner {
        var presents = 0
        var dismisses = 0
    }

    /// The delay under test, and a spin long enough that anything scheduled under it has
    /// either fired or was genuinely cancelled.
    private let delay: TimeInterval = 0.05
    private let margin: TimeInterval = 0.3

    private func makeScheduler(
        openDelay: TimeInterval,
        closeGrace: TimeInterval,
        holdsWhilePointerOnPopover: Bool
    ) -> (HoverPopoverScheduler, Owner) {
        let owner = Owner()
        let scheduler = HoverPopoverScheduler(policy: .init(
            openDelay: openDelay,
            closeGrace: closeGrace,
            holdsWhilePointerOnPopover: holdsWhilePointerOnPopover
        ))
        scheduler.onPresent = { owner.presents += 1 }
        scheduler.onDismiss = { owner.dismisses += 1 }
        return (scheduler, owner)
    }

    private func spin(for interval: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(interval))
    }

    func testZeroDelayPolicyPresentsOnEntryAndDismissesOnExitSynchronously() {
        let (scheduler, owner) = makeScheduler(
            openDelay: 0, closeGrace: 0, holdsWhilePointerOnPopover: false
        )

        scheduler.pointerEntered()
        XCTAssertEqual(owner.presents, 1, "Zero dwell opens on entry, before the run loop turns")

        scheduler.pointerExited()
        XCTAssertEqual(owner.dismisses, 1, "Zero grace closes on exit, before the run loop turns")
    }

    func testOpenDwellWaitsAndAnExitBeforeItFiresCancelsIt() {
        let (scheduler, owner) = makeScheduler(
            openDelay: delay, closeGrace: 0, holdsWhilePointerOnPopover: false
        )

        scheduler.pointerEntered()
        XCTAssertEqual(owner.presents, 0, "The dwell has not elapsed yet")
        spin(for: margin)
        XCTAssertEqual(owner.presents, 1)

        scheduler.pointerExited()
        scheduler.pointerEntered()
        scheduler.pointerExited()
        spin(for: margin)
        XCTAssertEqual(owner.presents, 1, "Leaving during the dwell abandons the open")
    }

    func testCloseGraceHoldsWhileThePointerRestsOnThePopover() {
        let (scheduler, owner) = makeScheduler(
            openDelay: 0, closeGrace: delay, holdsWhilePointerOnPopover: true
        )

        scheduler.pointerEntered()
        scheduler.pointerExited()
        XCTAssertEqual(owner.dismisses, 0, "The grace has not elapsed yet")

        scheduler.popoverHoverChanged(true)
        spin(for: margin)
        XCTAssertEqual(owner.dismisses, 0, "The pointer resting on the popover holds it open")

        scheduler.popoverHoverChanged(false)
        spin(for: margin)
        XCTAssertEqual(owner.dismisses, 1, "Leaving the popover starts the grace again")
    }

    func testPolicyWithoutHoldIgnoresThePopoverPointer() {
        let (scheduler, owner) = makeScheduler(
            openDelay: 0, closeGrace: delay, holdsWhilePointerOnPopover: false
        )

        scheduler.pointerEntered()
        scheduler.pointerExited()
        scheduler.popoverHoverChanged(true)
        spin(for: margin)
        XCTAssertEqual(owner.dismisses, 1, "Without the hold, reaching the popover cannot keep it")
    }

    func testReentrantOwnerCallbacksDoNotOverlapTheSchedulersOwnState() {
        // Every real owner's dismiss re-enters `cancelPendingWork()`. With a zero delay the
        // callback runs synchronously, so it must run after the scheduler has settled its own
        // pending slots — running it while a slot was still being written through `inout`
        // crashed as two overlapping exclusive accesses.
        let (scheduler, owner) = makeScheduler(
            openDelay: 0, closeGrace: 0, holdsWhilePointerOnPopover: false
        )
        scheduler.onPresent = { [weak scheduler] in
            owner.presents += 1
            scheduler?.cancelPendingWork()
        }
        scheduler.onDismiss = { [weak scheduler] in
            owner.dismisses += 1
            scheduler?.cancelPendingWork()
        }

        scheduler.pointerEntered()
        scheduler.pointerExited()
        XCTAssertEqual(owner.presents, 1)
        XCTAssertEqual(owner.dismisses, 1)
    }

    func testAPolicySwapAppliesFromTheNextPointerReport() {
        // The usage pill swaps policies with its content: a reading closes with the pointer,
        // extension-composed content earns the grace and the hold.
        let (scheduler, owner) = makeScheduler(
            openDelay: 0, closeGrace: 0, holdsWhilePointerOnPopover: false
        )
        scheduler.pointerEntered()
        XCTAssertEqual(owner.presents, 1)

        scheduler.policy = .init(
            openDelay: 0, closeGrace: delay, holdsWhilePointerOnPopover: true
        )
        scheduler.pointerExited()
        XCTAssertEqual(owner.dismisses, 0, "The swapped-in grace applies to this exit")

        scheduler.popoverHoverChanged(true)
        spin(for: margin)
        XCTAssertEqual(owner.dismisses, 0, "And so does the swapped-in hold")

        scheduler.popoverHoverChanged(false)
        spin(for: margin)
        XCTAssertEqual(owner.dismisses, 1)
    }

    func testCancelPendingWorkDropsBothSidesWithoutFiring() {
        let (opening, openOwner) = makeScheduler(
            openDelay: delay, closeGrace: 0, holdsWhilePointerOnPopover: false
        )
        opening.pointerEntered()
        opening.cancelPendingWork()
        spin(for: margin)
        XCTAssertEqual(openOwner.presents, 0)

        let (closing, closeOwner) = makeScheduler(
            openDelay: 0, closeGrace: delay, holdsWhilePointerOnPopover: false
        )
        closing.pointerEntered()
        closing.pointerExited()
        closing.cancelPendingWork()
        spin(for: margin)
        XCTAssertEqual(closeOwner.dismisses, 0)
    }
}

import CoreGraphics
import XCTest
@testable import ThreadingMobile

/// The rule under every scrub surface on the phone — the identity picker's runtime strip and
/// login rows, the model-by-effort matrix — pinned without a finger: what a touch ticks, and
/// what a lift takes.
final class MobileScrubSurfaceTests: XCTestCase {

    func testATapTicksTheItemBeneathItOnceAndCommitsIt() {
        var tracker = MobileScrubTracker<String>()
        XCTAssertEqual(tracker.touch("codex"), "codex", "touch-down lights the item under the finger")
        XCTAssertNil(tracker.touch("codex"), "a finger resting on the item does not tick again")
        XCTAssertEqual(tracker.lift("codex"), "codex")
        XCTAssertNil(tracker.scrubbed, "the tracker rests after a lift")
    }

    func testADragTicksAtEveryCrossingAndCommitsWhereItLifts() {
        var tracker = MobileScrubTracker<Int>()
        let ticks = [0, 0, 1, 1, 1, 2, 3, 3].compactMap { tracker.touch($0) }
        XCTAssertEqual(ticks, [0, 1, 2, 3])
        XCTAssertEqual(tracker.lift(3), 3)
    }

    /// Outside the surface is nothing rather than the nearest edge, so a drag that wanders off
    /// keeps what it had and lifting there still takes it.
    func testADragThatLeavesTheSurfaceHoldsTheLastItemItCrossed() {
        var tracker = MobileScrubTracker<Int>()
        XCTAssertEqual(tracker.touch(1), 1)
        XCTAssertEqual(tracker.touch(2), 2)
        XCTAssertNil(tracker.touch(nil), "off the surface is not a crossing")
        XCTAssertEqual(tracker.scrubbed, 2, "the item stays lit while the finger is off the surface")
        XCTAssertEqual(tracker.lift(nil), 2)
    }

    func testComingBackOntoTheHeldItemIsNotACrossingButOntoAnotherIs() {
        var tracker = MobileScrubTracker<Int>()
        XCTAssertEqual(tracker.touch(1), 1)
        XCTAssertNil(tracker.touch(nil))
        XCTAssertNil(tracker.touch(1))
        XCTAssertEqual(tracker.touch(2), 2)
    }

    func testATouchThatNeverFindsAnItemCommitsNothing() {
        var tracker = MobileScrubTracker<Int>()
        XCTAssertNil(tracker.touch(nil))
        XCTAssertNil(tracker.lift(nil))
        XCTAssertNil(tracker.scrubbed)
    }

    /// A wrapped strip pads its last row with blanks; a finger that lands on one and slides onto
    /// a runtime takes that runtime.
    func testATouchBeginningOnBlankPaddingCommitsWhatItReaches() {
        var tracker = MobileScrubTracker<Int>()
        XCTAssertNil(tracker.touch(nil))
        XCTAssertEqual(tracker.touch(4), 4)
        XCTAssertEqual(tracker.lift(4), 4)
    }

    func testTheNextTouchAfterALiftStartsFresh() {
        var tracker = MobileScrubTracker<Int>()
        XCTAssertEqual(tracker.touch(2), 2)
        XCTAssertEqual(tracker.lift(2), 2)
        XCTAssertEqual(tracker.touch(2), 2, "a second tap on the same item ticks again")
    }

    /// The strip's arithmetic and the tracker together: a finger drawn across five runtimes
    /// ticks each one once, in order, and lifting on the last takes it.
    func testADragAcrossTheRuntimeStripTicksEachRuntimeOnceAndCommitsTheLast() {
        let size = CGSize(width: 300, height: 68)
        var tracker = MobileScrubTracker<Int>()
        var ticks: [Int] = []
        for x in stride(from: CGFloat(0), to: size.width, by: 1) {
            let index = MobileIdentityPickerHitTest.tile(
                at: CGPoint(x: x, y: 34), in: size, tilesPerRow: 5, count: 5
            )
            if let tick = tracker.touch(index) { ticks.append(tick) }
        }
        XCTAssertEqual(ticks, [0, 1, 2, 3, 4])
        XCTAssertEqual(
            tracker.lift(MobileIdentityPickerHitTest.tile(
                at: CGPoint(x: 320, y: 34), in: size, tilesPerRow: 5, count: 5
            )),
            4,
            "lifting past the strip's edge takes the runtime the finger left it on"
        )
    }
}

import XCTest
@testable import Threading

/// A usage bar travelling to a new reading rather than appearing at it.
///
/// The clock is driven by hand throughout (`advanceAnimation(now:)`), so nothing here waits on
/// a display link and the feel is pinned as arithmetic rather than as a screenshot taken at an
/// unspecified moment.
@MainActor
final class UsageBarTravelTests: XCTestCase {

    private var window: NSWindow!

    override func setUp() {
        super.setUp()
        Design.Motion.reduceMotionOverrideForTesting = false
        // Built, never shown: a bar refuses to travel outside a window, and an ordered-on-screen
        // window would queue this host's own termination (see CLAUDE.md).
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
    }

    override func tearDown() {
        Design.Motion.reduceMotionOverrideForTesting = nil
        window = nil
        super.tearDown()
    }

    // MARK: - Travel

    func testApplyTravelsTheFillRatherThanLandingOnIt() {
        let bar = hostedBar(startingAt: 0.2)

        let start = CACurrentMediaTime()
        bar.apply(fraction: 0.8, tint: .systemGreen, timeMark: nil, animated: true)

        XCTAssertEqual(bar.displayedFraction, 0.2, accuracy: 0.0001,
                       "the travel starts from what was drawn, not from the new value")

        bar.advanceAnimation(now: start + Design.Motion.standard / 2)
        let midway = bar.displayedFraction
        XCTAssertGreaterThan(midway, 0.2)
        XCTAssertLessThan(midway, 0.8)
    }

    func testTravelLandsExactlyOnTheRequestedValue() {
        let bar = hostedBar(startingAt: 0.2)

        let start = CACurrentMediaTime()
        bar.apply(fraction: 0.8, tint: .systemGreen, timeMark: nil, animated: true)
        bar.advanceAnimation(now: start + Design.Motion.standard * 2)

        XCTAssertEqual(bar.displayedFraction, 0.8, accuracy: 0.0001)
    }

    /// The reason this curve is not `ThemedToggle`'s: a gauge that overshot would report a level
    /// the account never reached.
    func testTravelNeverDrawsAValueBeyondTheOneRequested() {
        for step in 0...100 {
            let phase = Double(step) / 100
            let eased = UsageBarView.Motion.travel(at: phase)
            XCTAssertGreaterThanOrEqual(eased, 0, "phase \(phase) drew below the start")
            XCTAssertLessThanOrEqual(eased, 1, "phase \(phase) drew past the target")
        }
        XCTAssertEqual(UsageBarView.Motion.travel(at: 0), 0, accuracy: 0.0001)
        XCTAssertEqual(UsageBarView.Motion.travel(at: 1), 1, accuracy: 0.0001)
    }

    /// The property moving is not the point — the fill has to move. Asserted on the geometry
    /// `layout()` actually computed, because that is the step between the two.
    func testTheTravelReachesTheDrawnFillAndNotJustTheValue() {
        let bar = hostedBar(startingAt: 0)
        bar.layoutSubtreeIfNeeded()
        XCTAssertEqual(drawnFillWidth(of: bar), 0, accuracy: 0.5)

        let start = CACurrentMediaTime()
        bar.apply(fraction: 1, tint: .systemGreen, timeMark: nil, animated: true)
        bar.advanceAnimation(now: start + Design.Motion.standard / 2)
        bar.layoutSubtreeIfNeeded()

        let midway = drawnFillWidth(of: bar)
        XCTAssertGreaterThan(midway, 0)
        XCTAssertLessThan(midway, bar.bounds.width)

        bar.advanceAnimation(now: start + Design.Motion.standard * 2)
        bar.layoutSubtreeIfNeeded()
        XCTAssertEqual(drawnFillWidth(of: bar), bar.bounds.width, accuracy: 0.5)
    }

    func testTravelEasesOutRatherThanRunningLinearly() {
        // Past the halfway mark at the halfway point is what "eased out" means; a linear tween
        // would sit exactly on it.
        XCTAssertGreaterThan(UsageBarView.Motion.travel(at: 0.5), 0.6)
    }

    // MARK: - Landing

    func testReduceMotionLandsTheFillWithNoTravel() {
        Design.Motion.reduceMotionOverrideForTesting = true
        let bar = hostedBar(startingAt: 0.2)

        bar.apply(fraction: 0.8, tint: .systemGreen, timeMark: nil, animated: true)

        XCTAssertEqual(bar.displayedFraction, 0.8, accuracy: 0.0001,
                       "under Reduce Motion the value is the caller's now, not one frame from now")
    }

    func testABarOutsideAWindowLandsRatherThanTravellingUnseen() {
        let bar = UsageBarView()
        bar.fraction = 0.2

        bar.apply(fraction: 0.8, tint: .systemGreen, timeMark: nil, animated: true)

        XCTAssertEqual(bar.displayedFraction, 0.8, accuracy: 0.0001)
    }

    func testAssigningFractionDirectlyLandsAndCancelsTravelInFlight() {
        let bar = hostedBar(startingAt: 0.2)

        bar.apply(fraction: 0.8, tint: .systemGreen, timeMark: nil, animated: true)
        bar.fraction = 0.35

        XCTAssertEqual(bar.displayedFraction, 0.35, accuracy: 0.0001)

        // The cancelled travel must not resume on a later frame.
        bar.advanceAnimation(now: CACurrentMediaTime() + Design.Motion.standard * 2)
        XCTAssertEqual(bar.displayedFraction, 0.35, accuracy: 0.0001)
    }

    func testLeavingTheWindowLandsTheFill() {
        let bar = hostedBar(startingAt: 0.2)
        bar.apply(fraction: 0.8, tint: .systemGreen, timeMark: nil, animated: true)

        bar.removeFromSuperview()

        XCTAssertEqual(bar.displayedFraction, 0.8, accuracy: 0.0001,
                       "a bar that stops being visible arrives rather than freezing part-way")
    }

    func testATravelTurnedAroundMidFlightStartsFromWhatIsDrawn() {
        let bar = hostedBar(startingAt: 0)

        let start = CACurrentMediaTime()
        bar.apply(fraction: 1, tint: .systemGreen, timeMark: nil, animated: true)
        bar.advanceAnimation(now: start + Design.Motion.standard / 2)
        let turnedAt = bar.displayedFraction

        bar.apply(fraction: 0, tint: .systemGreen, timeMark: nil, animated: true)
        XCTAssertEqual(bar.displayedFraction, turnedAt, accuracy: 0.0001,
                       "the second travel starts where the first had reached, not at either end")
    }

    // MARK: - Fixtures

    private func hostedBar(startingAt fraction: Double) -> UsageBarView {
        let bar = UsageBarView()
        bar.frame = NSRect(x: 0, y: 0, width: 200, height: UsageBarDefaults.height)
        bar.fraction = fraction
        window.contentView?.addSubview(bar)
        return bar
    }

    /// The fill is the first subview the bar adds, under the pace mark.
    /// Asked of the bar by name rather than by subview index: the fill stopped being
    /// `subviews.first` the day the capped track was inserted below it, and this helper reported
    /// zero for a bar that was drawing perfectly well.
    private func drawnFillWidth(of bar: UsageBarView) -> CGFloat {
        bar.drawnFillWidth
    }

}

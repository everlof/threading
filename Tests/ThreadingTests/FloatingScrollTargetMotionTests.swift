import XCTest
@testable import Threading

// MARK: - Floating Scroll Target Motion

/// The down-arrow that returns a scrolling surface to its live end, arriving and leaving.
///
/// The affordance itself is one shared component (`ThemedButton.floatingScrollToEnd`), and both
/// hosts — Git Review's diff and the native conversation — used to switch it on and off with
/// `isHidden`. Switching is the one thing a target floating over content must not do: it appears
/// at the moment the reader is looking somewhere else in the pane, so the arrow either travels
/// into place where the eye can follow it, or it is simply *there* the next time they look up.
///
/// What these tests hold is what a screenshot cannot: that the arrival starts below its resting
/// place and smaller, that the departure is not over the instant it is asked for, that a reader
/// who scrolls back up mid-departure gets the arrow back rather than a second animation fighting
/// the first, and that the whole thing collapses to an applied state under Reduce Motion.
///
/// The fixture window is built and never shown — the presence transitions need a render tree,
/// not a visible one — so this belongs in `fast`.
@MainActor
final class FloatingScrollTargetMotionTests: XCTestCase {

    private enum Fixture {
        static let paneSize = NSSize(width: 420, height: 320)
        /// Long enough for a departure of `Design.Motion.vanish` to have finished, short enough
        /// that a broken completion fails the test rather than stalling the suite.
        static let settleWindow: TimeInterval = 1

        /// How many points the arrival is sampled at. Finer than a frame at 60Hz, so a curve
        /// that carries the arrow through the middle of its rise cannot slip between samples.
        static let arrivalSamples = 24

        /// What each sample gives the render server to publish a presented layer. The clock is
        /// the layer's own `timeOffset`, so this is a handoff rather than a wait for real time.
        static let presentationSettle: TimeInterval = 0.005

        /// Halvings used to invert a timing curve's x. Sixty are far past the point where the
        /// answer stops changing in a `Double`; the loop is cheap and the exactness is free.
        static let bezierRefinements = 60
    }

    /// A pane whose y axis runs the other way, for the one thing that cannot be asserted from a
    /// single host: that "below" is read from the geometry rather than written down.
    private final class FlippedPane: NSView {
        override var isFlipped: Bool { true }
    }

    /// Held for the length of the test. A pane that outlives its window is a pane with no render
    /// tree, and these transitions are exactly the thing that needs one.
    private var windows: [NSWindow] = []

    override func tearDown() {
        Design.Motion.reduceMotionOverrideForTesting = nil
        for window in windows { window.contentView = nil }
        windows.removeAll()
        super.tearDown()
    }

    // MARK: - Arrival

    func testTheTargetArrivesFromBelowItsRestingPlaceAndSmallerThanFullSize() throws {
        Design.Motion.reduceMotionOverrideForTesting = false
        let button = makeTarget(in: makePane(flipped: false))

        button.setFloatingPresence(true)

        XCTAssertTrue(button.isFloatingPresent)
        XCTAssertFalse(button.isHidden, "The target is on screen for the whole of its arrival")

        let arrival = try XCTUnwrap(
            button.layer?.animation(forKey: FloatingTargetMotion.animationKey) as? CAAnimationGroup,
            "The arrival is a group: the rise and the fade are one movement"
        )
        let start = try startingTransform(of: arrival)
        XCTAssertEqual(
            startingOffset(of: start, on: button).y,
            -FloatingTargetMotion.rise,
            accuracy: 0.001,
            "The arrow's own centre starts one rise below where it comes to rest"
        )
        XCTAssertEqual(
            startingOffset(of: start, on: button).x,
            0,
            accuracy: 0.001,
            "…and directly under it: the travel is vertical"
        )
        XCTAssertEqual(start.m11, FloatingTargetMotion.arriveScale, accuracy: 0.001)
        XCTAssertLessThan(
            start.m11,
            1,
            "The arrow grows into its resting size rather than landing at it"
        )
        XCTAssertEqual(arrival.duration, Design.Motion.floatingTargetArrive, accuracy: 0.001)
    }

    /// The model is left at rest throughout, so an arrival interrupted by *anything* — a theme
    /// sweep, a resize, the window closing — leaves the arrow exactly where it belongs rather
    /// than parked at the picture it was passing through.
    func testTheArrivalMovesNothingButThePresentation() {
        Design.Motion.reduceMotionOverrideForTesting = false
        let button = makeTarget(in: makePane(flipped: false))

        button.setFloatingPresence(true)

        XCTAssertEqual(button.alphaValue, 1)
        XCTAssertTrue(CATransform3DIsIdentity(button.layer?.transform ?? CATransform3DIdentity))
    }

    func testBelowIsReadFromTheHostsGeometryRatherThanWrittenDown() throws {
        Design.Motion.reduceMotionOverrideForTesting = false
        let upward = makeTarget(in: makePane(flipped: false))
        let downward = makeTarget(in: makePane(flipped: true))

        upward.setFloatingPresence(true)
        downward.setFloatingPresence(true)

        let fromUpward = startingOffset(
            of: try startingTransform(of: XCTUnwrap(
                upward.layer?.animation(forKey: FloatingTargetMotion.animationKey)
                    as? CAAnimationGroup
            )),
            on: upward
        )
        let fromDownward = startingOffset(
            of: try startingTransform(of: XCTUnwrap(
                downward.layer?.animation(forKey: FloatingTargetMotion.animationKey)
                    as? CAAnimationGroup
            )),
            on: downward
        )

        // Same distance, opposite sign: in an unflipped pane y grows upward and in a flipped one
        // it grows downward, and the arrow starts under its resting place in both.
        XCTAssertEqual(fromUpward.y, -FloatingTargetMotion.rise, accuracy: 0.001)
        XCTAssertEqual(fromDownward.y, FloatingTargetMotion.rise, accuracy: 0.001)
    }

    /// The one thing a timing function cannot be reviewed by reading it: whether the movement it
    /// describes is actually *seen*.
    ///
    /// This samples the presented layer through a paused animation, which is the same thing the
    /// render server hands the screen. It matters because the obvious curve here is the `glide`
    /// every other arrival in the app uses, and over a rise this short glide crosses about four
    /// fifths of the distance inside three frames at 60Hz: every assertion above still passes,
    /// the arrow still starts 20pt low and 86% of its size, and a reader sees it switch on.
    /// What this holds is the part that made it a rise — that the arrow is caught in the middle
    /// of the trip, not only at its ends.
    func testTheRiseIsSpreadAcrossTheArrivalRatherThanBeingOverAtOnce() throws {
        Design.Motion.reduceMotionOverrideForTesting = false
        let button = makeTarget(in: makePane(flipped: false))

        button.setFloatingPresence(true)
        let layer = try XCTUnwrap(button.layer)

        // Pausing the layer and stepping its own clock: Core Animation resolves the curve, so
        // this reads the real interpolation rather than a reimplementation of it here.
        layer.speed = 0
        var offsets: [CGFloat] = []
        for step in 0...Fixture.arrivalSamples {
            layer.timeOffset =
                Double(step) / Double(Fixture.arrivalSamples) * Design.Motion.floatingTargetArrive
            RunLoop.main.run(until: Date(timeIntervalSinceNow: Fixture.presentationSettle))
            guard let presented = layer.presentation() else { continue }
            offsets.append(abs(startingOffset(of: presented.transform, on: button).y))
        }

        XCTAssertGreaterThan(offsets.count, 1, "The presented layer never reported a position")
        XCTAssertEqual(
            try XCTUnwrap(offsets.first),
            FloatingTargetMotion.rise,
            accuracy: 0.5,
            "The first frame shown is the arrow at the bottom of its rise"
        )
        XCTAssertEqual(
            try XCTUnwrap(offsets.last),
            0,
            accuracy: 0.5,
            "The last is the arrow at rest"
        )
        XCTAssertEqual(
            offsets,
            offsets.sorted(by: >),
            "The arrow closes on its resting place throughout: it never backs up or overshoots"
        )

        let midway = offsets.filter {
            $0 > FloatingTargetMotion.rise * 0.3 && $0 < FloatingTargetMotion.rise * 0.7
        }
        XCTAssertFalse(
            midway.isEmpty,
            "The arrow is seen partway up: sampled offsets were \(offsets)"
        )
    }

    /// The same claim as the sampling above, made where it cannot be missed between two frames.
    ///
    /// Sampling proves the interpolation runs; it cannot prove the movement is *spread*, because
    /// a fine enough sample finds the middle of any curve, including one that passes through it
    /// in a millisecond. This asks the curve directly how far along the arrow is a quarter of the
    /// way through the arrival. `lift` answers about two fifths — the eye gets the rest of the
    /// trip over the remaining three quarters. `glide`, the curve every larger arrival here uses,
    /// answers about six sevenths, which is the whole reason this affordance does not use it.
    func testAQuarterOfTheWayInMostOfTheRiseIsStillToCome() throws {
        Design.Motion.reduceMotionOverrideForTesting = false
        let button = makeTarget(in: makePane(flipped: false))

        button.setFloatingPresence(true)

        let arrival = try XCTUnwrap(
            button.layer?.animation(forKey: FloatingTargetMotion.animationKey) as? CAAnimationGroup
        )
        let travelled = progress(
            of: try XCTUnwrap(arrival.timingFunction),
            atFractionOfDuration: 0.25
        )
        XCTAssertLessThan(
            travelled,
            0.6,
            "A quarter of the way in the arrow is barely past half its rise, not sitting down"
        )
        XCTAssertGreaterThan(
            travelled,
            0.2,
            "…and it is moving: a curve that waits reads as a delay, not as an approach"
        )
    }

    // MARK: - Departure

    func testTheTargetIsStillDrawnWhileItLeavesAndIsHiddenOnlyWhenItHasGone() {
        Design.Motion.reduceMotionOverrideForTesting = false
        let button = makeTarget(in: makePane(flipped: false))
        button.setFloatingPresence(true)

        button.setFloatingPresence(false)

        XCTAssertFalse(button.isFloatingPresent, "It stops being on offer the moment it is taken")
        XCTAssertFalse(button.isHidden, "…and stays drawn for as long as it is still leaving")
        XCTAssertNotNil(button.layer?.animation(forKey: FloatingTargetMotion.animationKey))

        waitForDeparture(of: button)

        XCTAssertTrue(button.isHidden)
        XCTAssertEqual(button.alphaValue, 1, "Hidden at full opacity, ready for the next arrival")
        XCTAssertNil(button.layer?.animation(forKey: FloatingTargetMotion.animationKey))
    }

    /// The hosts ask this question from a scroll callback — every wheel event, every resize —
    /// so the answer they already gave has to cost nothing. A target that re-ran its arrival on
    /// each of those would pulse for the whole of a scroll.
    func testAskingAgainForAStateItIsAlreadyInAnimatesNothing() {
        Design.Motion.reduceMotionOverrideForTesting = false
        let button = makeTarget(in: makePane(flipped: false))
        button.setFloatingPresence(true)
        waitForArrival(of: button)

        button.setFloatingPresence(true)

        XCTAssertTrue(button.isFloatingPresent)
        XCTAssertNil(
            button.layer?.animation(forKey: FloatingTargetMotion.animationKey),
            "A second yes to a target already there is not a second arrival"
        )

        button.setFloatingPresence(false)
        waitForDeparture(of: button)
        button.setFloatingPresence(false)

        XCTAssertTrue(button.isHidden)
        XCTAssertNil(
            button.layer?.animation(forKey: FloatingTargetMotion.animationKey),
            "Nor a second no to one already gone a second departure"
        )
    }

    func testScrollingBackUpMidDepartureBringsTheSameArrowBack() {
        Design.Motion.reduceMotionOverrideForTesting = false
        let button = makeTarget(in: makePane(flipped: false))
        button.setFloatingPresence(true)
        button.setFloatingPresence(false)

        button.setFloatingPresence(true)

        XCTAssertTrue(button.isFloatingPresent)
        XCTAssertFalse(button.isHidden)
        XCTAssertEqual(button.alphaValue, 1, "The fade it was in the middle of is called off")

        // The departure's completion belongs to a transition that no longer exists: whatever it
        // has to say about hiding the view, it must not say it now.
        waitForSettling()
        XCTAssertFalse(button.isHidden)
        XCTAssertTrue(button.isFloatingPresent)
    }

    // MARK: - Reduce Motion

    func testUnderReduceMotionTheTargetIsSimplyThereOrNotThere() {
        Design.Motion.reduceMotionOverrideForTesting = true
        let button = makeTarget(in: makePane(flipped: false))

        button.setFloatingPresence(true)
        XCTAssertFalse(button.isHidden)
        XCTAssertNil(button.layer?.animation(forKey: FloatingTargetMotion.animationKey))

        button.setFloatingPresence(false)
        XCTAssertTrue(button.isHidden, "No beat to wait out: the state is applied")
        XCTAssertNil(button.layer?.animation(forKey: FloatingTargetMotion.animationKey))
    }

    func testAHostReplacingItsContentTakesTheTargetWithIt() {
        Design.Motion.reduceMotionOverrideForTesting = false
        let button = makeTarget(in: makePane(flipped: false))
        button.setFloatingPresence(true)

        button.setFloatingPresence(false, animated: false)

        XCTAssertTrue(button.isHidden)
        XCTAssertNil(button.layer?.animation(forKey: FloatingTargetMotion.animationKey))
    }

    // MARK: - Fixture

    private func makePane(flipped: Bool) -> NSView {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Fixture.paneSize),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let pane = flipped ? FlippedPane() : NSView()
        pane.wantsLayer = true
        window.contentView = pane
        windows.append(window)
        return pane
    }

    private func makeTarget(in pane: NSView) -> ThemedButton {
        let button = ThemedButton.floatingScrollToEnd(
            accessibility: "Scroll to end",
            target: nil,
            action: nil
        )
        button.isHidden = true
        pane.addSubview(button)
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: pane.centerXAnchor),
            button.bottomAnchor.constraint(
                equalTo: pane.bottomAnchor,
                constant: -Design.Spacing.inset
            )
        ])
        pane.layoutSubtreeIfNeeded()
        return button
    }

    /// Where the arrow's own centre sits at the start of the movement, relative to where it comes
    /// to rest.
    ///
    /// Read from the centre rather than from the matrix's translation, because the two are not
    /// the same number: a scale composed about the centre contributes translation of its own, and
    /// AppKit hands a layer-backed view an anchor point in its **corner**, so the correction is
    /// half the button. What the eye is being promised is where the glyph starts, which is this.
    private func startingOffset(of transform: CATransform3D, on button: ThemedButton) -> CGPoint {
        let anchor = button.layer?.anchorPoint ?? CGPoint(x: 0.5, y: 0.5)
        let centre = CGPoint(
            x: (0.5 - anchor.x) * button.bounds.width,
            y: (0.5 - anchor.y) * button.bounds.height
        )
        let moved = CGPoint(
            x: transform.m11 * centre.x + transform.m21 * centre.y + transform.m41,
            y: transform.m12 * centre.x + transform.m22 * centre.y + transform.m42
        )
        return CGPoint(x: moved.x - centre.x, y: moved.y - centre.y)
    }

    /// How much of the distance a timing function has covered at some fraction of its duration.
    ///
    /// A media timing function is a cubic bezier from (0,0) to (1,1) whose two control points it
    /// will hand back, and its shape is read the way Core Animation reads it: find the curve
    /// parameter whose x is the elapsed fraction, then take that point's y.
    private func progress(
        of curve: CAMediaTimingFunction,
        atFractionOfDuration fraction: Double
    ) -> Double {
        var first = [Float](repeating: 0, count: 2)
        var second = [Float](repeating: 0, count: 2)
        curve.getControlPoint(at: 1, values: &first)
        curve.getControlPoint(at: 2, values: &second)
        let along = { (u: Double, a: Double, b: Double) in
            3 * u * pow(1 - u, 2) * a + 3 * pow(u, 2) * (1 - u) * b + pow(u, 3)
        }
        var low = 0.0
        var high = 1.0
        for _ in 0..<Fixture.bezierRefinements {
            let mid = (low + high) / 2
            if along(mid, Double(first[0]), Double(second[0])) < fraction {
                low = mid
            } else {
                high = mid
            }
        }
        return along((low + high) / 2, Double(first[1]), Double(second[1]))
    }

    private func startingTransform(of group: CAAnimationGroup) throws -> CATransform3D {
        let move = try XCTUnwrap(
            group.animations?.compactMap({ $0 as? CABasicAnimation })
                .first { $0.keyPath == FloatingTargetMotion.transformKeyPath }
        )
        return try XCTUnwrap(move.fromValue as? NSValue).caTransform3DValue
    }

    private func waitForDeparture(of button: ThemedButton) {
        let deadline = Date(timeIntervalSinceNow: Fixture.settleWindow)
        while !button.isHidden, Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
    }

    /// An arrival is over when Core Animation has taken the animation off the layer, which is
    /// not the same as its nominal duration having elapsed. Waiting a multiple of the duration
    /// instead passed alone and on an idle machine, and failed in a full run of the target —
    /// the removal lands after the wall clock says it should when 5,000 other cases are
    /// competing for the main thread. Poll for the departure's condition, as its wait does.
    private func waitForArrival(of button: ThemedButton) {
        let deadline = Date(timeIntervalSinceNow: Fixture.settleWindow)
        while button.layer?.animation(forKey: FloatingTargetMotion.animationKey) != nil,
              Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
    }

    private func waitForSettling() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: Design.Motion.vanish * 3))
    }
}

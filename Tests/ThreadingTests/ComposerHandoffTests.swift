import AppKit
import XCTest
@testable import Threading

/// The composer's box becoming the conversation's reply box.
///
/// Two halves, tested apart because they fail apart: the animator, which is geometry and alphas
/// over plain views, and the pane's mark, which decides whether a swap is a handoff at all. The
/// mark carries the sharper rule — every attach spends it, so a start nobody made in the
/// composer can never inherit one.
@MainActor
final class ComposerHandoffTests: XCTestCase {

    /// `cacheDisplay` asks AppKit views to draw; it does not promise to composite a bare
    /// backing layer into the cache. Draw the layer fill explicitly so the snapshot assertion
    /// observes the colour the handoff repaired rather than the window background underneath.
    private final class CachedLayerSurfaceView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            guard let background = layer?.backgroundColor,
                  let color = NSColor(cgColor: background) else { return }
            color.setFill()
            NSBezierPath(rect: dirtyRect).fill()
        }
    }

    private enum Fixture {
        static let paneSize = NSSize(width: 900, height: 640)
        static let boxSize = NSSize(width: 600, height: 90)
        /// Bounded: the whole point of `handoff` is that it is over inside half a second.
        static let flightTimeout: TimeInterval = 3
    }

    override func tearDown() {
        Design.Motion.reduceMotionOverrideForTesting = nil
        super.tearDown()
    }

    /// The first pane is a placeholder while a stored selection is restored. Hooking up the
    /// coordinator must not construct the complete hidden composer behind that placeholder.
    func testContainerDefersTheComposerUntilAComposerRouteRequestsIt() {
        var constructionCount = 0
        let container = TerminalContainerViewController(
            recovery: false,
            sessionComposerFactory: {
                constructionCount += 1
                return SessionComposerViewController(customizationLookup: { _ in .empty })
            }
        )

        XCTAssertEqual(constructionCount, 0)
        _ = container.composerViewController
        XCTAssertEqual(constructionCount, 1)
        _ = container.composerViewController
        XCTAssertEqual(constructionCount, 1, "the requested composer was rebuilt")
    }

    // MARK: - The Animator

    /// Reduce Motion collapses the token to zero, and the honest reduced form of a move is the
    /// thing already being where it lands. One path and one final state: nothing is built,
    /// nothing is faded, and the completion still runs.
    func testUnderReduceMotionTheHandoffLandsItsEndStateWithNoGhostAtAll() throws {
        Design.Motion.reduceMotionOverrideForTesting = true

        let stage = makeStage()
        let snapshot = try handoffSnapshot(stage)
        let animator = ComposerHandoffAnimator()

        var completed = 0
        animator.run(
            snapshot,
            in: stage.host,
            below: stage.overlay,
            into: stage.destinationBox,
            revealing: [stage.content],
            completion: { completed += 1 }
        )

        XCTAssertEqual(completed, 1, "the reduced path still has to report that it is done")
        XCTAssertFalse(animator.isRunning)
        XCTAssertTrue(ghosts(in: stage.host).isEmpty, "Reduce Motion built a ghost")
        XCTAssertEqual(stage.destinationBox.alphaValue, 1)
        XCTAssertEqual(stage.content.alphaValue, 1)
    }

    /// With motion on, the two ghosts are on the pane for the length of the move and gone after
    /// it, they sit over the conversation and under the pane's own floating card, and every
    /// alpha the transition borrowed is handed back.
    func testTheGhostsFlyOverTheConversationAndLeaveEveryAlphaBehindThem() throws {
        Design.Motion.reduceMotionOverrideForTesting = false

        let stage = makeStage()
        let snapshot = try handoffSnapshot(stage)
        let animator = ComposerHandoffAnimator()

        let landed = expectation(description: "the handoff completes")
        animator.run(
            snapshot,
            in: stage.host,
            below: stage.overlay,
            into: stage.destinationBox,
            revealing: [stage.content],
            completion: { landed.fulfill() }
        )

        XCTAssertTrue(animator.isRunning)
        XCTAssertEqual(ghosts(in: stage.host).count, 2, "the pane is missing a ghost")

        let order = stage.host.subviews
        let conversation = try XCTUnwrap(order.firstIndex(of: stage.conversation))
        let overlay = try XCTUnwrap(order.firstIndex(of: stage.overlay))
        let ghostPositions = order.indices.filter { order[$0] is NSImageView }
        XCTAssertTrue(
            ghostPositions.allSatisfy { $0 > conversation && $0 < overlay },
            "the ghosts belong over the conversation and under the git status card"
        )

        wait(for: [landed], timeout: Fixture.flightTimeout)

        XCTAssertFalse(animator.isRunning)
        XCTAssertTrue(ghosts(in: stage.host).isEmpty, "a ghost outlived the handoff")
        XCTAssertEqual(stage.destinationBox.alphaValue, 1)
        XCTAssertEqual(stage.content.alphaValue, 1)
    }

    /// A layer-backed composer can be built before its window supplies an appearance. The
    /// snapshot boundary must repair those frozen CGColors; drawing under Dark Aqua alone does
    /// not mutate a layer that was filled under Aqua.
    func testSnapshotRepairsAFieldBuiltUnderTheWrongAppearance() throws {
        let light = try XCTUnwrap(NSAppearance(named: .aqua))
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        let stage = makeStage()

        light.performAsCurrentDrawingAppearance {
            stage.sourceBox.applySurface(fill: Design.Surface.field, radius: .panel)
        }
        stage.window.appearance = dark

        let snapshot = try handoffSnapshot(stage)
        let bitmap = try XCTUnwrap(
            snapshot.boxImage.representations.first as? NSBitmapImageRep,
            "the handoff box did not retain its cached bitmap"
        )
        let actual = try XCTUnwrap(bitmap.colorAt(
            x: bitmap.pixelsWide / 2,
            y: bitmap.pixelsHigh / 2
        )?.usingColorSpace(.sRGB))
        var resolvedExpected: NSColor?
        var resolvedLight: NSColor?
        dark.performAsCurrentDrawingAppearance {
            resolvedExpected = NSColor(cgColor: Design.Surface.field.cgColor)?.usingColorSpace(.sRGB)
        }
        light.performAsCurrentDrawingAppearance {
            resolvedLight = NSColor(cgColor: Design.Surface.field.cgColor)?.usingColorSpace(.sRGB)
        }
        let expected = try XCTUnwrap(resolvedExpected)
        let stale = try XCTUnwrap(resolvedLight)
        let repairedCGColor = try XCTUnwrap(stage.sourceBox.layer?.backgroundColor)
        let repairedLayer = try XCTUnwrap(
            NSColor(cgColor: repairedCGColor)?.usingColorSpace(.sRGB)
        )

        XCTAssertEqual(repairedLayer.redComponent, expected.redComponent, accuracy: 0.01)
        XCTAssertEqual(repairedLayer.greenComponent, expected.greenComponent, accuracy: 0.01)
        XCTAssertEqual(repairedLayer.blueComponent, expected.blueComponent, accuracy: 0.01)

        func squaredDistance(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat {
            pow(lhs.redComponent - rhs.redComponent, 2)
                + pow(lhs.greenComponent - rhs.greenComponent, 2)
                + pow(lhs.blueComponent - rhs.blueComponent, 2)
        }
        XCTAssertLessThan(
            squaredDistance(actual, expected),
            squaredDistance(actual, stale),
            "the cached ghost remained closer to the light field than the dark one"
        )
        XCTAssertLessThan(
            (actual.redComponent + actual.greenComponent + actual.blueComponent) / 3,
            0.35,
            "the cached composer ghost is still a light rectangle over a dark conversation"
        )
    }

    /// Something else taking the pane cancels the move. It lands on the same end state the
    /// completion would have reached, and reports it exactly once however late the animation's
    /// own completion arrives.
    func testAnythingElseTakingThePaneLandsTheEndStateImmediately() throws {
        Design.Motion.reduceMotionOverrideForTesting = false

        let stage = makeStage()
        let snapshot = try handoffSnapshot(stage)
        let animator = ComposerHandoffAnimator()

        var completed = 0
        animator.run(
            snapshot,
            in: stage.host,
            below: stage.overlay,
            into: stage.destinationBox,
            revealing: [stage.content],
            completion: { completed += 1 }
        )
        XCTAssertTrue(animator.isRunning)

        animator.finish()

        XCTAssertFalse(animator.isRunning)
        XCTAssertTrue(ghosts(in: stage.host).isEmpty, "cancelling left a ghost on the pane")
        XCTAssertEqual(stage.destinationBox.alphaValue, 1)
        XCTAssertEqual(stage.content.alphaValue, 1)
        XCTAssertEqual(completed, 1)

        // The animation underneath is still running; its own completion has to find nothing
        // left to do rather than report a second landing.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: Design.Motion.handoff * 2))
        XCTAssertEqual(completed, 1, "the cancelled run reported itself twice")
        XCTAssertTrue(ghosts(in: stage.host).isEmpty)
    }

    /// A second start cancels the first rather than layering two sets of ghosts over one pane.
    func testASecondHandoffReplacesTheFirstRatherThanStackingOnIt() throws {
        Design.Motion.reduceMotionOverrideForTesting = false

        let stage = makeStage()
        let snapshot = try handoffSnapshot(stage)
        let animator = ComposerHandoffAnimator()

        animator.run(
            snapshot,
            in: stage.host,
            below: stage.overlay,
            into: stage.destinationBox,
            revealing: [stage.content]
        )
        let landed = expectation(description: "the second handoff completes")
        animator.run(
            snapshot,
            in: stage.host,
            below: stage.overlay,
            into: stage.destinationBox,
            revealing: [stage.content],
            completion: { landed.fulfill() }
        )

        XCTAssertEqual(ghosts(in: stage.host).count, 2, "the first run's ghosts were left behind")

        wait(for: [landed], timeout: Fixture.flightTimeout)
        XCTAssertTrue(ghosts(in: stage.host).isEmpty)
    }

    // MARK: - The Pane's Mark

    /// The mark names one session, and the pane spends it on that session alone.
    func testAMarkLeftForOneSessionIsNotSpentByAnother() {
        let container = makeContainer()

        let started = SessionID()
        container.prepareComposerHandoff(for: started)

        XCTAssertFalse(
            container.consumeComposerHandoff(for: SessionID()),
            "another session inherited the composer's handoff"
        )
        XCTAssertFalse(
            container.consumeComposerHandoff(for: started),
            "the mark survived an attach that was not its own"
        )
    }

    /// The composer has to still be the surface on screen: what a handoff moves is a box the
    /// user is looking at, and there is nothing to lift off a pane already showing something
    /// else.
    func testAMarkIsOnlySpentWhileTheComposerIsTheSurfaceOnScreen() {
        let container = makeContainer()

        let started = SessionID()
        container.prepareComposerHandoff(for: started)
        XCTAssertTrue(container.consumeComposerHandoff(for: started))

        container.composerViewController.view.isHidden = true
        container.prepareComposerHandoff(for: started)
        XCTAssertFalse(
            container.consumeComposerHandoff(for: started),
            "a hidden composer still handed a box over"
        )
    }

    /// Going back to the composer — or to any other surface — clears the mark rather than
    /// leaving it standing for whatever is selected next.
    func testAnotherSurfaceTakingThePaneClearsTheMark() {
        let container = makeContainer()

        let started = SessionID()
        container.prepareComposerHandoff(for: started)
        container.showComposer(projectID: nil)

        XCTAssertFalse(
            container.consumeComposerHandoff(for: started),
            "the composer reopening left the handoff mark standing on the pane"
        )
    }

    // MARK: - Fixture

    private struct Stage {
        let host: NSView
        let window: NSWindow
        let composer: NSView
        let sourceBox: NSView
        let conversation: NSView
        let content: NSView
        let destinationBox: NSView
        let overlay: NSView
    }

    /// The pane's shape without the pane: a composer with a box in it, the conversation that
    /// replaces it, and the git status card floating over both. Built in an unshown window,
    /// which is all `cacheDisplay` and an animation group need.
    private func makeStage() -> Stage {
        let host = NSView(frame: NSRect(origin: .zero, size: Fixture.paneSize))
        host.wantsLayer = true

        let composer = NSView(frame: host.bounds)
        let sourceBox = CachedLayerSurfaceView(
            frame: NSRect(
                x: (Fixture.paneSize.width - Fixture.boxSize.width) / 2,
                y: 24,
                width: Fixture.boxSize.width,
                height: Fixture.boxSize.height
            )
        )
        composer.addSubview(sourceBox)

        let conversation = NSView(frame: host.bounds)
        let content = NSView(frame: NSRect(x: 0, y: 140, width: Fixture.paneSize.width, height: 500))
        let destinationBox = NSView(
            frame: NSRect(x: 20, y: 20, width: Fixture.paneSize.width - 40, height: 110)
        )
        conversation.addSubview(content)
        conversation.addSubview(destinationBox)

        let overlay = NSView(frame: NSRect(x: 700, y: 560, width: 180, height: 60))

        host.addSubview(composer)
        host.addSubview(conversation)
        host.addSubview(overlay)

        let window = NSWindow(
            contentRect: host.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()

        return Stage(
            host: host,
            window: window,
            composer: composer,
            sourceBox: sourceBox,
            conversation: conversation,
            content: content,
            destinationBox: destinationBox,
            overlay: overlay
        )
    }

    /// Captured while the composer is still visible and hidden immediately after, which is the
    /// order the pane itself takes: the picture is what stands in for it from then on.
    private func handoffSnapshot(_ stage: Stage) throws -> ComposerHandoffAnimator.Snapshot {
        let snapshot = try XCTUnwrap(
            ComposerHandoffAnimator.snapshot(
                composer: stage.composer,
                box: stage.sourceBox,
                in: stage.host
            )
        )
        stage.composer.isHidden = true
        return snapshot
    }

    private func makeContainer() -> TerminalContainerViewController {
        let container = TerminalContainerViewController()
        container.view.frame = NSRect(origin: .zero, size: Fixture.paneSize)
        container.view.layoutSubtreeIfNeeded()
        container.showComposer(projectID: nil)
        return container
    }

    private func ghosts(in host: NSView) -> [NSImageView] {
        host.subviews.compactMap { $0 as? NSImageView }
    }
}

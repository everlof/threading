import AppKit
import XCTest
@testable import Threading

/// The ghost a review row wears while its diff body is deferred or still loading.
///
/// Everything here holds one contract: the skeleton is a silhouette of the file's own counts,
/// never invented content — a file with no removals must not ghost red bars — and its breathing
/// is presentation only: present in a window, gone under Reduce Motion, with the still bars
/// remaining as the status either way.
@MainActor
final class DiffSkeletonViewTests: XCTestCase {

    override func tearDown() {
        AppThemePalette.set(.system)
        Design.Motion.reduceMotionOverrideForTesting = nil
        super.tearDown()
    }

    // MARK: - Fixture

    private func skeleton(added: Int, removed: Int, size: NSSize = NSSize(width: 360, height: 240)) -> DiffSkeletonView {
        let view = DiffSkeletonView(added: added, removed: removed)
        // Without an appearance the offscreen draw resolves no dynamic colour and comes out
        // blank — the same trap `ColorPairSpecimenTests` documents.
        view.appearance = NSAppearance(named: .darkAqua)
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        return view
    }

    /// The kinds of the first few blocks' bars — enough repetition to see the whole cycle.
    private func kinds(of view: DiffSkeletonView, bars: Int = 36) -> Set<DiffSkeletonView.BarKind> {
        Set((0..<bars).map { view.barKind(at: $0) })
    }

    // MARK: - Silhouette

    func testUnknownCountsGhostOnlyContextBars() {
        XCTAssertEqual(kinds(of: skeleton(added: 0, removed: 0)), [.context])
    }

    func testAnAddedOnlyFileInventsNoRemovals() {
        let kinds = kinds(of: skeleton(added: 120, removed: 0))
        XCTAssertTrue(kinds.contains(.added))
        XCTAssertFalse(kinds.contains(.removed))
    }

    func testARemovedOnlyFileInventsNoAdditions() {
        let kinds = kinds(of: skeleton(added: 0, removed: 55))
        XCTAssertTrue(kinds.contains(.removed))
        XCTAssertFalse(kinds.contains(.added))
    }

    func testAMixedFileShowsBothKindsBesideContext() {
        XCTAssertEqual(
            kinds(of: skeleton(added: 90, removed: 30)),
            [.context, .added, .removed]
        )
    }

    /// One removal against nine hundred additions is still a removal: rounding must not erase
    /// the minority kind from the silhouette.
    func testATinyMinorityKindStillGetsItsBar() {
        let kinds = kinds(of: skeleton(added: 900, removed: 1))
        XCTAssertTrue(kinds.contains(.added))
        XCTAssertTrue(kinds.contains(.removed))
    }

    // MARK: - Pulse

    func testThePulseNeedsAWindowAndYieldsToReduceMotion() {
        Design.Motion.reduceMotionOverrideForTesting = false
        let view = skeleton(added: 10, removed: 5)
        XCTAssertFalse(view.isPulsing, "an animation added outside a layer tree is dropped")

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        defer { window.orderOut(nil) }
        window.contentView?.addSubview(view)
        XCTAssertTrue(view.isPulsing, "hosted in a window, the ghost breathes")

        Design.Motion.reduceMotionOverrideForTesting = true
        NotificationCenter.default.post(AccessibilityDisplayOptionsDidChange())
        XCTAssertFalse(
            view.isPulsing,
            "Reduce Motion removes the perpetual animation rather than slowing it"
        )
        XCTAssertFalse(view.isHidden, "the still bars remain — the ghost content is the status")

        Design.Motion.reduceMotionOverrideForTesting = false
        NotificationCenter.default.post(AccessibilityDisplayOptionsDidChange())
        XCTAssertTrue(view.isPulsing, "the preference flipping back restores the breath")
    }

    func testARehostedSkeletonKeepsItsPulse() {
        Design.Motion.reduceMotionOverrideForTesting = false
        let view = skeleton(added: 10, removed: 5)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        defer { window.orderOut(nil) }

        window.contentView?.addSubview(view)
        view.removeFromSuperview()
        // A virtual table rehosts rows constantly, and the layer tree drops animations on the
        // way out; re-entering the window must bring the breath back by itself.
        window.contentView?.addSubview(view)
        XCTAssertTrue(view.isPulsing)
    }

    // MARK: - Appearance

    /// A claim about a drawn component is checked by looking at a render. Under System and two
    /// deliberately different themes, the ghost must put visible ink inside its bounds.
    func testItDrawsInkUnderSystemAndTwoStyledThemes() throws {
        for theme in [.system, AppThemeStyles.cyberpunk, AppThemeStyles.swissMinimalist] {
            AppThemePalette.set(theme)
            let view = skeleton(added: 40, removed: 20)
            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)

            var inked = 0
            for x in stride(from: 0, to: rep.pixelsWide, by: 4) {
                for y in stride(from: 0, to: rep.pixelsHigh, by: 4) where
                    (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 {
                    inked += 1
                }
            }
            XCTAssertGreaterThan(
                inked,
                20,
                "the skeleton drew nothing under \(theme.name)"
            )
        }
    }

    /// The rect a capture hands a layer-backed view is `CGRectInfinite`, not its bounds: its
    /// origin is -CGFloat.greatestFiniteMagnitude / 2. Deriving a row index from that by
    /// dividing and converting to `Int` overflows and traps the process — the app died this way
    /// in `-[NSBitmapImageRep _captureDrawing:]` while snapshotting a window whose review pane
    /// was wearing this ghost. Drawing must clip to `bounds` before it counts rows.
    func testItSurvivesTheUnclippedRectACaptureHandsIt() throws {
        let view = skeleton(added: 40, removed: 20)
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }
        // Stated directly rather than left to AppKit's ordering of the two passes.
        view.draw(.infinite)

        var inked = 0
        for x in stride(from: 0, to: rep.pixelsWide, by: 4) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 4) where
                (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 {
                inked += 1
            }
        }
        XCTAssertGreaterThan(inked, 20, "clipping the unclipped rect must draw the bars, not skip them")
    }

    func testAThemeChangeRedrawsTheBars() {
        // The recorded preference can arrive as any palette, and `set` declines a switch to
        // the theme already up — so state the baseline instead of assuming it.
        AppThemePalette.set(.system)
        let view = skeleton(added: 10, removed: 5)
        // `needsDisplay` is a fact about a window's display cycle: outside one, a layer-backed
        // view neither keeps nor reports the mark, and the assertion reads false whether or not
        // the redraw wiring worked. The window stays unshown — dirty tracking needs a backing
        // store, not pixels on screen.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        window.contentView?.addSubview(view)
        window.contentView?.layoutSubtreeIfNeeded()
        view.needsDisplay = false
        AppThemePalette.set(AppThemeStyles.cyberpunk)
        XCTAssertTrue(view.needsDisplay, "a live theme switch must reach a drawn component")
    }

    // MARK: - Accessibility

    func testItIsDecorative() {
        let view = skeleton(added: 10, removed: 5)
        XCTAssertFalse(
            view.isAccessibilityElement(),
            "the row's header carries the loading state; the ghost is decoration"
        )
    }
}

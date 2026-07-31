import AppKit
import XCTest
@testable import Threading

/// The window's own silhouette: what is drawn at its edges, and therefore what its rounded
/// corners are cut out of.
///
/// This exists because of a bug that was invisible in every assertion in the suite and obvious
/// in a photograph. The display panel starts collapsed, and `NSSplitViewController` keeps a
/// collapsed item's divider so it can be dragged back — which put a `Design.Radius.border`-thick
/// seam, in the theme's rule ink, hard against the *window's* trailing edge. Sampled off the
/// running window it was RGB (16, 16, 16) for two to three points down the full height, byte for
/// byte the same ink as the sidebar's own divider. Nothing about that is a divider: there is no
/// second pane on the far side of it. What it did instead was cut a straight dark bar through
/// the window's rounded corners, which is how it was reported — the top-right corner "isn't
/// really rounded, it's cut off and turns black".
///
/// So the assertion is on pixels, at the edge, from a real split-view controller: the trailing
/// column of a window whose trailing pane is collapsed must be that pane's neighbour, not a rule.
/// Confirmed to have teeth by stubbing the fix out — the seam reappears in the last column.
@MainActor
final class WindowEdgeTests: XCTestCase {

    private enum Fixture {
        static let size = NSSize(width: 400, height: 200)
        /// The panes fill themselves, so "is this pixel a pane or the seam" has one answer.
        /// Saturated green because no theme's rule ink is anywhere near it — a failure then
        /// names the divider rather than a near-miss on some surface.
        static let paneFill = NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
        /// Wide enough that an open trailing pane is genuinely on screen, so the seam this
        /// test looks for is *between* the panes rather than at the window's edge again.
        static let openTrailingWidth: CGFloat = 120
    }

    private final class FilledPane: NSViewController {
        override func loadView() {
            let view = NSView()
            view.wantsLayer = true
            view.layer?.backgroundColor = Fixture.paneFill.cgColor
            self.view = view
        }
    }

    // MARK: - Helpers

    /// A two-pane controller in a real (never shown) window, with the trailing pane optionally
    /// collapsed. The window is what makes this real: a split view lays its dividers out against
    /// the window's content view, which is where the seam met the corner.
    private func render(collapsingTrailingPane collapse: Bool) throws -> NSBitmapImageRep {
        let controller = SidebarSplitViewController()

        let leading = NSSplitViewItem(viewController: FilledPane())
        let trailing = NSSplitViewItem(viewController: FilledPane())
        trailing.canCollapse = true
        trailing.minimumThickness = Fixture.openTrailingWidth
        controller.addSplitViewItem(leading)
        controller.addSplitViewItem(trailing)
        trailing.isCollapsed = collapse

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Fixture.size),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.setContentSize(Fixture.size)
        controller.view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        let view = controller.view
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// Compares **every** channel. The first version of this compared green alone and passed
    /// against a white divider, which shares the pane's green exactly — a test that could not
    /// see the thing it was written for.
    private func isPaneFill(_ colour: NSColor) -> Bool {
        let fill = Fixture.paneFill
        return abs(colour.redComponent - fill.redComponent) < 0.1
            && abs(colour.greenComponent - fill.greenComponent) < 0.1
            && abs(colour.blueComponent - fill.blueComponent) < 0.1
    }

    private func colour(_ rep: NSBitmapImageRep, x: Int, y: Int) throws -> NSColor {
        try XCTUnwrap(XCTUnwrap(rep.colorAt(x: x, y: y)).usingColorSpace(.sRGB))
    }

    // MARK: - Tests

    /// The bug: with the trailing pane collapsed, the window's trailing column was the seam.
    func testACollapsedTrailingPaneLeavesNoSeamAtTheWindowsEdge() throws {
        let rep = try render(collapsingTrailingPane: true)
        let middleRow = rep.pixelsHigh / 2

        // Every column, not just the last: the seam is thicker than a pixel under a heavy
        // ruling theme, and the point is that there is no rule anywhere in a one-pane window.
        for x in 0..<rep.pixelsWide {
            let sampled = try colour(rep, x: x, y: middleRow)
            XCTAssertTrue(
                isPaneFill(sampled),
                "a collapsed pane left its divider drawn at x=\(x) of \(rep.pixelsWide): \(sampled)"
            )
        }
    }

    /// And the seam is not simply gone: two open panes still have one between them, or this
    /// would be a fix that deleted the divider rather than the bar at the edge.
    func testTwoOpenPanesStillHaveASeamBetweenThem() throws {
        let rep = try render(collapsingTrailingPane: false)
        let middleRow = rep.pixelsHigh / 2

        let seam = try (0..<rep.pixelsWide).first { x in
            try !isPaneFill(colour(rep, x: x, y: middleRow))
        }
        let found = try XCTUnwrap(seam, "the two panes run together with no seam between them")
        XCTAssertLessThan(
            found,
            rep.pixelsWide - 1,
            "the seam is at the window's edge rather than between the panes"
        )
    }
}

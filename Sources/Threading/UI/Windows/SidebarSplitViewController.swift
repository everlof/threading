import AppKit

/// Split view controller whose sidebar can actually be restored once collapsed.
///
/// `NSSplitViewController.toggleSidebar(_:)` collapses the sidebar but does not bring it
/// back here, which leaves no way to reach it again. The app-owned toolbar button and the View
/// menu both route through this method, so overriding it fixes every entry point at once.
final class SidebarSplitViewController: NSSplitViewController {

    /// Reports the requested stable state after AppKit has finished the visual transition and
    /// the split view has committed its final frames.
    var sidebarTransitionDidComplete: ((Bool) -> Void)?

    // MARK: - Initialization

    /// The split view is replaced before any item is added, which is the only window in which
    /// `NSSplitViewController` accepts one: it creates a stock split view lazily the first time
    /// the property is read, and adding an item reads it.
    init() {
        super.init(nibName: nil, bundle: nil)
        splitView = ThemedSplitView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Dividers

    /// A collapsed pane's seam is not a seam, and at the window's edge it is a black bar.
    ///
    /// `NSSplitViewController` keeps a collapsed item's divider so it can be dragged back open.
    /// That is reasonable in the middle of a window and wrong at its edge, which is where both
    /// of this window's collapsible panes live: the display panel starts collapsed, so its
    /// divider sat hard against the window's **trailing** edge, and the sidebar's lands on the
    /// leading one the moment it is toggled shut. Measured off the running window, that seam is
    /// `Design.Radius.border` thick and drawn in the theme's rule ink — 2 to 3 points of near
    /// black down the full height of the window, byte-identical to the sidebar's own divider —
    /// and it does not stop at the corner: the rounded corners are cut into by a straight dark
    /// bar, which is why the window's top-right read as clipped and blackened rather than round.
    ///
    /// Hiding rather than not *drawing* it: a divider that is merely undrawn still takes its
    /// thickness out of the layout, and the window's own background would show through the gap
    /// — the same bar in the system's colour instead of the theme's. Neither pane loses a way
    /// back, because neither is opened by dragging: the sidebar has its toolbar button and the
    /// View menu, the panel its own control.
    ///
    /// **Strictly additive to `super`, and that is not a formality.** `NSSplitViewController`
    /// answers this question for its own purposes, and one of the things it answers is part of
    /// how a pane dragged past its minimum decides to collapse: an override that returned a
    /// plain `false` where the base said otherwise left the sidebar stopping dead at its floor
    /// instead of shutting — caught by `testSidebarStopsWhereTheWindowControlsEnd`, and not by
    /// anything about dividers. So whatever AppKit already wants hidden stays hidden, and this
    /// only ever hides *more*.
    override func splitView(_ splitView: NSSplitView, shouldHideDividerAt index: Int) -> Bool {
        if super.splitView(splitView, shouldHideDividerAt: index) { return true }
        return [index, index + 1]
            .filter { splitViewItems.indices.contains($0) }
            .contains { splitViewItems[$0].isCollapsed }
    }

    // MARK: - Actions

    override func toggleSidebar(_ sender: Any?) {
        guard let sidebarItem = splitViewItems.first else {
            super.toggleSidebar(sender)
            return
        }

        let targetIsCollapsed = !sidebarItem.isCollapsed
        NSAnimationContext.runAnimationGroup(
            { context in
                context.duration = Design.Motion.standard
                context.allowsImplicitAnimation = true
                sidebarItem.isCollapsed = targetIsCollapsed
            },
            completionHandler: { [weak self] in
                // The completion runs before AppKit commits the split views' final model
                // frames. Measure one main-loop turn later, after that layout transaction.
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.splitView.layoutSubtreeIfNeeded()
                    self.sidebarTransitionDidComplete?(targetIsCollapsed)
                }
            }
        )
    }
}

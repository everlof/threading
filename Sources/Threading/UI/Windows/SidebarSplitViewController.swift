import AppKit

/// Split view controller whose collapsible panes all come and go by one route.
///
/// `NSSplitViewController.toggleSidebar(_:)` collapses the sidebar but does not bring it
/// back here, which leaves no way to reach it again. The app-owned toolbar button and the View
/// menu both route through this method, so overriding it fixes every entry point at once.
/// `setCollapsed(_:on:)` is the route everything then shares — the toggle, the panel's reveal,
/// a divider pushed past either pane — so a pane shut one way arrives in the same state, with
/// the same motion, as one shut any other.
final class SidebarSplitViewController: NSSplitViewController {

#if DEBUG
    struct CollapseStatePhaseDurations {
        var itemNanoseconds: UInt64 = 0
        var notificationNanoseconds: UInt64 = 0
        var geometryNanoseconds: UInt64 = 0
    }

    private(set) var lastCollapseStatePhaseDurations = CollapseStatePhaseDurations()
#endif

    /// Reports an item's model-state change immediately, before the visual transition
    /// finishes. Controls whose value represents visibility use this callback; geometry
    /// consumers use `paneTransitionDidComplete` below, after AppKit has committed the final
    /// frames.
    var paneCollapseStateDidChange: ((NSSplitViewItem, Bool) -> Void)?

    /// Reports the requested stable state after AppKit has finished the visual transition and
    /// the split view has committed its final frames.
    var paneTransitionDidComplete: ((NSSplitViewItem, Bool) -> Void)?

    /// Whether an otherwise-animated split-pane transition should actually move geometry.
    ///
    /// The main window supplies one answer for both edge panes. A live terminal makes every
    /// intermediate width an expensive backing-tree layout and potential terminal-grid resize,
    /// so both the sidebar and display panel commit their final geometry immediately there.
    /// Native conversation/content surfaces keep the standard pane motion. Keeping this policy
    /// at the shared collapse route prevents the two window edges from drifting again depending
    /// on which caller happened to request the change.
    var allowsAnimatedPaneTransitions: () -> Bool = { true }

#if DEBUG
    /// The animation answer after the caller request and shared pane policy were combined.
    /// Tests use this to prove both edge panes go through the same decision even in an unshown
    /// fixture, where `PaneTransition` correctly suppresses presentation motion of its own.
    private(set) var lastCollapseUsedAnimatedGeometry = false
#endif

    // MARK: - Initialization

    /// The split view is replaced before any item is added, which is the only window in which
    /// `NSSplitViewController` accepts one: it creates a stock split view lazily the first time
    /// the property is read, and adding an item reads it.
    init() {
        super.init(nibName: nil, bundle: nil)
        let themedSplitView = ThemedSplitView()
        splitView = themedSplitView
        themedSplitView.dividerDragDidEnd = { [weak self] index, pointerX in
            self?.shutPaneIfPushedPast(dividerAt: index, releasedAt: pointerX)
        }
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

    // MARK: - Collapsing by Drag

    /// Shuts a pane the moment the divider has been pushed past it, rather than a hundred points
    /// later.
    ///
    /// **In the running app a dragged divider has never shut this column.** Not "stopped
    /// working" — never, on the report of the person dragging it. Every collapse it has ever
    /// done came from the toolbar, the View menu, or a test calling `setPosition`.
    ///
    /// AppKit is not simply refusing. Driven through the same tracking loop in a fixture it
    /// collapses a `canCollapse` pane at *half the pane's floor* — with the floor at 207pt,
    /// released at 120 the column stayed and at 90 it shut — so the machinery is there and
    /// something about the real window keeps it from firing. Whatever that is, the threshold
    /// was never reachable in practice anyway: past the floor the divider stops dead under the
    /// pointer, so a hundred points are travelled blind, against a column that has visibly
    /// stopped. Nothing about carrying on says the column is about to go.
    ///
    /// So the answer is ours rather than AppKit's, and it is `PaneTransition.dragShutsPane` —
    /// near enough to the stop that the push is one gesture. AppKit's rule is left in place
    /// underneath: if it ever does fire, a longer push is still a push.
    ///
    /// **Both of the divider's neighbours are candidates.** The sidebar is pushed *leftward*
    /// past its floor and the display panel *rightward* past its own — the same gesture
    /// mirrored — and only one of the two can be past its floor at once, because the pointer
    /// is on one side of the divider or the other. The middle pane cannot collapse, so a push
    /// toward it answers nothing.
    private func shutPaneIfPushedPast(dividerAt index: Int, releasedAt pointerX: CGFloat) {
        guard splitViewItems.indices.contains(index),
              splitViewItems.indices.contains(index + 1),
              splitView.arrangedSubviews.indices.contains(index + 1) else { return }

        // Measured from where each pane starts (or ends), so the answer is the pane's own
        // would-be thickness rather than a window x — true by construction for the window's
        // edge panes, and stated so it stays true if this window ever grows a fourth.
        let candidates: [(item: NSSplitViewItem, thickness: CGFloat)] = [
            (splitViewItems[index],
             pointerX - splitView.arrangedSubviews[index].frame.minX),
            (splitViewItems[index + 1],
             splitView.arrangedSubviews[index + 1].frame.maxX - pointerX)
        ]
        let pushedPast = candidates.first { item, thickness in
            item.canCollapse && !item.isCollapsed
                && PaneTransition.dragShutsPane(thickness: thickness, floor: item.minimumThickness)
        }
        guard let item = pushedPast?.item else { return }

        // One turn later, because the release is still unwinding the divider's tracking loop:
        // a collapse begun inside that unwind applies its final state without its motion — the
        // one shut in the window that snapped while every other one slid. An ordinary turn of
        // the run loop later it is an ordinary collapse.
        DispatchQueue.main.async { [weak self] in
            guard let self, !item.isCollapsed else { return }
            self.setCollapsed(true, on: item)
        }
    }

    // MARK: - Actions

    override func toggleSidebar(_ sender: Any?) {
        guard let sidebarItem = splitViewItems.first else {
            super.toggleSidebar(sender)
            return
        }

        setCollapsed(!sidebarItem.isCollapsed, on: sidebarItem)
    }

    // MARK: - Collapsing

    /// The one place a pane's collapse is animated and reported, so a pane shut at its divider
    /// arrives in the same state, by the same route, as one shut from the toolbar — and the
    /// panel on the other side of the window moves the way the sidebar does.
    ///
    /// A bare `isCollapsed` assignment, deliberately not the item's `animator()`: inside the
    /// group, `allowsImplicitAnimation` already carries the collapse, and the animator's own
    /// uncollapse commits asynchronously even at zero duration — measured as a revealed
    /// panel that swallowed the `setPosition` applied a full turn later and relaid itself to
    /// its chrome floor. The direct set flips the model immediately in both branches, which
    /// is what lets every `isCollapsed` read stay ignorant of whether a transition is in
    /// flight.
    ///
    /// `geometryChanges` lets a caller place the revealed pane at its stable divider position
    /// inside the same group as the collapse state. `completion` runs with
    /// `paneTransitionDidComplete`, after the split view has committed its final frames —
    /// `PaneTransition.run`'s deferred-turn contract plus one explicit layout pass, because the
    /// animation's own completion fires a frame too early to measure.
    func setCollapsed(
        _ collapsed: Bool,
        on item: NSSplitViewItem,
        animated: Bool = true,
        geometryChanges: (() -> Void)? = nil,
        completion: (@MainActor @Sendable () -> Void)? = nil
    ) {
        let animatesGeometry = animated && allowsAnimatedPaneTransitions()
#if DEBUG
        lastCollapseUsedAnimatedGeometry = animatesGeometry
#endif
        PaneTransition.run(
            in: splitView,
            animated: animatesGeometry,
            changes: {
#if DEBUG
                let itemStarted = DispatchTime.now().uptimeNanoseconds
#endif
                item.isCollapsed = collapsed
#if DEBUG
                let itemEnded = DispatchTime.now().uptimeNanoseconds
#endif
                paneCollapseStateDidChange?(item, collapsed)
#if DEBUG
                let notificationEnded = DispatchTime.now().uptimeNanoseconds
#endif
                geometryChanges?()
#if DEBUG
                let geometryEnded = DispatchTime.now().uptimeNanoseconds
                self.lastCollapseStatePhaseDurations = CollapseStatePhaseDurations(
                    itemNanoseconds: itemEnded - itemStarted,
                    notificationNanoseconds: notificationEnded - itemEnded,
                    geometryNanoseconds: geometryEnded - notificationEnded
                )
#endif
            },
            completion: { [weak self] in
                guard let self else {
                    completion?()
                    return
                }
                self.splitView.layoutSubtreeIfNeeded()
                self.paneTransitionDidComplete?(item, collapsed)
                completion?()
            }
        )
    }
}

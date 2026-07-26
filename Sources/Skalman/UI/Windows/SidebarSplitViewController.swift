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

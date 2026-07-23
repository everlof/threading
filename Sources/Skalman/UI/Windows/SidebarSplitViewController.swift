import AppKit

/// Split view controller whose sidebar can actually be restored once collapsed.
///
/// `NSSplitViewController.toggleSidebar(_:)` collapses the sidebar but does not bring it
/// back here, which leaves no way to reach it again. The app-owned toolbar button and the View
/// menu both route through this method, so overriding it fixes every entry point at once.
final class SidebarSplitViewController: NSSplitViewController {

    // MARK: - Actions

    override func toggleSidebar(_ sender: Any?) {
        guard let sidebarItem = splitViewItems.first else {
            super.toggleSidebar(sender)
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Design.Motion.standard
            context.allowsImplicitAnimation = true
            sidebarItem.isCollapsed.toggle()
        }
    }
}

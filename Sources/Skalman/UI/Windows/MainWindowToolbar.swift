import AppKit

// MARK: - Toolbar Item Identifiers

extension NSToolbarItem.Identifier {
    /// Names the project and session currently shown.
    static let sessionTitle = NSToolbarItem.Identifier("SkalmanSessionTitle")

    /// Shows the current account's rate-limit usage, at the window's trailing edge.
    static let accountUsage = NSToolbarItem.Identifier("SkalmanAccountUsage")
}

// MARK: - NSToolbarDelegate

extension MainWindowController: NSToolbarDelegate {

    /// Builds the window's toolbar.
    ///
    /// A real toolbar is what keeps the sidebar control pinned beside the traffic lights in
    /// both states. `.toggleSidebar` and `.sidebarTrackingSeparator` are system items: the
    /// first drives the split view's first item, the second keeps a divider aligned with the
    /// split position as it moves.
    func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: MainWindowDefaults.toolbarIdentifier)
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.showsBaselineSeparator = false

        return toolbar
    }

    // MARK: Delegate

    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .sessionTitle, .flexibleSpace, .accountUsage]
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    public func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case .sidebarTrackingSeparator:
            return NSTrackingSeparatorToolbarItem(
                identifier: itemIdentifier,
                splitView: splitViewController.splitView,
                dividerIndex: 0
            )

        case .sessionTitle:
            return makeSessionTitleItem(identifier: itemIdentifier)

        case .accountUsage:
            return makeAccountUsageItem(identifier: itemIdentifier)

        default:
            // .toggleSidebar and the spacers are supplied by the system.
            return nil
        }
    }

    // MARK: Item Construction

    private func makeSessionTitleItem(identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.view = sessionTitleItemView
        item.visibilityPriority = .high

        // This item is a label, not a control. Without this the system draws a bezel behind
        // it, which reads as a button.
        item.isBordered = false

        sessionTitleItemView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            sessionTitleItemView.widthAnchor.constraint(
                greaterThanOrEqualToConstant: SessionTitleDefaults.minWidth
            ),
            sessionTitleItemView.widthAnchor.constraint(
                lessThanOrEqualToConstant: SessionTitleDefaults.maxWidth
            )
        ])

        return item
    }

    private func makeAccountUsageItem(identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.view = accountUsageItemView

        // The pill draws its own surface; the system bezel would double it.
        item.isBordered = false

        accountUsageItemView.translatesAutoresizingMaskIntoConstraints = false

        return item
    }
}

import AppKit

// MARK: - Open In Menu

/// The list of installed apps a folder or a file can be handed to, in the two forms the app
/// needs it: an `NSMenu` submenu for the platform's context menus, and themed entries for a
/// control that opens its own dropdown.
///
/// One builder for both, because the two are the same offer made from different surfaces — a
/// header button, a sidebar row, a file tree, a diff. A second list that quietly held fewer
/// apps is exactly the drift `populateSessionActions` exists to prevent for session actions.
///
/// Every item carries its app's `id` in `representedObject`; `app(in:)` reads it back. The
/// *target* is not carried, because a context menu's subject is decided when it opens, not when
/// it was built — each call site recomputes it from its own clicked row, exactly as its
/// neighbouring items already do.
@MainActor
enum OpenInMenu {

    /// The submenu item, or nil when nothing installed can take this target.
    ///
    /// Nil rather than a disabled item: an "Open in" that offers nothing is a dead row in a
    /// menu the user opened for something else, and the design system's own rule is that a
    /// control offering a single dead option hides instead.
    static func item(
        for target: ExternalAppTarget,
        action: Selector,
        owner: AnyObject
    ) -> NSMenuItem? {
        let apps = ExternalAppLauncher.shared.installed(for: target)
        guard !apps.isEmpty else { return nil }

        let submenu = NSMenu(title: OpenInMenuDefaults.title)
        for app in apps {
            let item = NSMenuItem(title: app.name, action: action, keyEquivalent: "")
            item.representedObject = app.id
            item.image = ExternalAppLauncher.shared.icon(for: app)
            item.target = owner
            submenu.addItem(item)
        }

        let item = NSMenuItem(title: OpenInMenuDefaults.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    /// The app a chosen item names, or nil if the menu was built before it was uninstalled.
    static func app(in sender: NSMenuItem) -> ExternalApp? {
        guard let id = sender.representedObject as? String else { return nil }
        return ExternalApps.app(id: id)
    }

    /// The same list for a themed dropdown, each row drawing the app's own icon.
    ///
    /// The preferred app is marked selected, which is what tells the user which one the plain
    /// press beside the chevron would have used.
    static func entries(
        for target: ExternalAppTarget,
        onChoose: @escaping (ExternalApp) -> Void
    ) -> [ThemedMenuEntry] {
        let launcher = ExternalAppLauncher.shared
        let apps = launcher.installed(for: target)
        guard !apps.isEmpty else {
            return [.item(ThemedMenuItem(title: L10n.string("No apps found"), isEnabled: false))]
        }

        let preferred = launcher.preferred(for: target)
        return apps.map { app in
            .item(ThemedMenuItem(
                title: app.name,
                image: launcher.icon(for: app),
                representedValue: app.id,
                isSelected: app.id == preferred?.id,
                onChoose: { onChoose(app) }
            ))
        }
    }
}

// MARK: - Defaults

enum OpenInMenuDefaults {
    /// Deliberately not "Open in…": the ellipsis promises a dialog, and this opens a submenu.
    static var title: String { L10n.string("Open in") }

    /// Wide enough for the longest app name the registry can show without the dropdown sizing
    /// itself to a two-letter list.
    static let menuWidth: CGFloat = 200
}

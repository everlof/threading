import AppKit

// MARK: - Open In Menu

/// The list of installed apps a folder or a file can be handed to, in the two forms the app
/// needs it: a submenu entry for the context menus, and a flat list for a control that opens
/// its own dropdown.
///
/// One builder for both, because the two are the same offer made from different surfaces — a
/// header button, a sidebar row, a file tree, a diff. A second list that quietly held fewer
/// apps is exactly the drift `sessionActionEntries` exists to prevent for session actions.
///
/// The *target* is captured by the closures at build time, because a context menu is built
/// per open for the row under the pointer — the same rule its neighbouring items follow.
@MainActor
enum OpenInMenu {

    /// The "Open in" parent entry, or nil when nothing installed can take this target.
    ///
    /// Nil rather than a disabled item: an "Open in" that offers nothing is a dead row in a
    /// menu the user opened for something else, and the design system's own rule is that a
    /// control offering a single dead option hides instead.
    ///
    /// The default choice hands the target to the chosen app; pass `onChoose` where the call
    /// site owns more of the launch (recording a preference, refreshing a control).
    static func submenuEntry(
        for target: ExternalAppTarget,
        onChoose: ((ExternalApp) -> Void)? = nil
    ) -> ThemedMenuEntry? {
        let apps = ExternalAppLauncher.shared.installed(for: target)
        guard !apps.isEmpty else { return nil }

        // The fold takes the header control's own glyph rather than the preferred app's icon:
        // the rows below it are the apps, and leading them with one of their number reads as
        // "Open in Xcode ▸" — a claim about where the submenu goes that its first row then
        // contradicts.
        return .item(ThemedMenuItem(
            title: OpenInMenuDefaults.title,
            image: ThemedMenuIcon.symbol(OpenInToolbarDefaults.fallbackSymbol),
            submenu: apps.map { app in
                .item(ThemedMenuItem(
                    title: app.name,
                    image: ExternalAppLauncher.shared.icon(for: app),
                    representedValue: app.id,
                    onChoose: {
                        if let onChoose {
                            onChoose(app)
                        } else {
                            ExternalAppLauncher.shared.open(target, in: app)
                        }
                    }
                ))
            }
        ))
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

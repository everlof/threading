import AppKit

// MARK: - Theme Choice

/// What one item in the Theme submenu would do: which record it themes, and with what.
///
/// Carried on the item itself rather than read from the controller when it fires, because the
/// submenu is built from several places — a session's `⋯`, a session's right-click, a
/// project's menu, the toolbar's context button — and ambient "whichever row was last
/// clicked" state is exactly what gets stale between them.
struct ThemeMenuChoice {

    enum Target {
        case session(SessionID)
        case project(ProjectID)
    }

    let target: Target

    /// Nil clears the assignment, so the record inherits again.
    let themeID: TerminalThemeID?
}

// MARK: - Theme Menu Builder

/// Builds the Theme submenu, offered wherever a theme is chosen at the thing it applies to:
/// the sidebar rows' menus, and the toolbar's context button.
///
/// A class rather than free functions because the items need a stable target for their
/// actions; each presenter keeps one and tells it how "Edit Themes…" reaches Settings.
@MainActor
final class ThemeMenuBuilder: NSObject {

    /// Opens the Themes settings page, in whatever way the presenter reaches Settings.
    var onEditThemes: (() -> Void)?

    /// A session's theme: its own choice, or inheriting whatever its project and the default
    /// resolve to.
    func sessionThemeItem(for sessionID: SessionID) -> NSMenuItem {
        makeThemeItem(
            target: .session(sessionID),
            assigned: ThemeAssignments.themeID(forSession: sessionID),
            inherited: ThemeAssignments.inheritedName(forSession: sessionID)
        )
    }

    /// A project's theme, which every session inside it follows unless it names its own.
    func projectThemeItem(for projectID: ProjectID) -> NSMenuItem {
        makeThemeItem(
            target: .project(projectID),
            assigned: ThemeAssignments.themeID(forProject: projectID),
            inherited: ThemeAssignments.inheritedName(forProject: projectID)
        )
    }

    // MARK: - Private Methods

    /// One builder for both scopes: they differ in what they read and write, not in what
    /// they offer.
    ///
    /// "Inherit" names what it inherits, because it is otherwise the one choice in the list
    /// whose result the user cannot see.
    private func makeThemeItem(
        target: ThemeMenuChoice.Target,
        assigned: TerminalThemeID?,
        inherited: String
    ) -> NSMenuItem {
        let submenu = NSMenu()

        submenu.addItem(themeChoiceItem(
            title: "Inherit (\(inherited))",
            choice: ThemeMenuChoice(target: target, themeID: nil),
            isChecked: assigned == nil
        ))
        submenu.addItem(.separator())

        // Above the list and separated from it, because it is not one of the palettes — it is
        // the answer "whatever the app theme says", which changes when the app theme does.
        let followsApp = themeChoiceItem(
            title: TerminalThemeNames.followsAppTheme,
            choice: ThemeMenuChoice(target: target, themeID: .followsAppTheme),
            isChecked: assigned == .followsAppTheme
        )
        followsApp.image = ThemeSwatchImage.menuSwatch(for: AppThemeLibrary.current.terminalPalette)
        submenu.addItem(followsApp)
        submenu.addItem(.separator())

        for theme in ThemeManager.shared.allThemes {
            let item = themeChoiceItem(
                title: theme.name,
                choice: ThemeMenuChoice(target: target, themeID: theme.id),
                isChecked: theme.id == assigned
            )
            item.image = ThemeSwatchImage.menuSwatch(for: theme)
            submenu.addItem(item)
        }

        submenu.addItem(.separator())
        let edit = NSMenuItem(
            title: "Edit Themes…",
            action: #selector(editThemesClicked),
            keyEquivalent: ""
        )
        edit.target = self
        submenu.addItem(edit)

        let item = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    private func themeChoiceItem(
        title: String,
        choice: ThemeMenuChoice,
        isChecked: Bool
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(themeChoiceClicked(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = choice
        item.state = isChecked ? .on : .off
        return item
    }

    // MARK: - Handlers

    @objc private func themeChoiceClicked(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? ThemeMenuChoice else { return }

        switch choice.target {
        case .session(let sessionID):
            ThemeAssignments.setTheme(id: choice.themeID, forSession: sessionID)
        case .project(let projectID):
            ThemeAssignments.setTheme(id: choice.themeID, forProject: projectID)
        }
    }

    @objc private func editThemesClicked() {
        onEditThemes?()
    }
}

// MARK: - Sidebar Wrappers

/// The submenu sits in a row's own menu rather than in Settings because a scope is chosen
/// *at* the thing it applies to — the same placement as the surface switch and the project
/// icon. The app-wide default stays in Settings, which is the scope with no row to hang from.
extension ProjectSidebarViewController {

    func makeSessionThemeItem(for sessionID: SessionID) -> NSMenuItem {
        sidebarThemeBuilder().sessionThemeItem(for: sessionID)
    }

    func makeProjectThemeItem(for projectID: ProjectID) -> NSMenuItem {
        sidebarThemeBuilder().projectThemeItem(for: projectID)
    }

    private func sidebarThemeBuilder() -> ThemeMenuBuilder {
        themeMenuBuilder.onEditThemes = { [weak self] in
            guard let self else { return }
            self.delegate?.projectSidebar(
                self,
                didSelectSettingsPage: SettingsPages.themesID
            )
        }
        return themeMenuBuilder
    }
}

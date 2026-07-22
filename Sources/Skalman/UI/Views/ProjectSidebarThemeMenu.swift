import AppKit

// MARK: - Theme Choice

/// What one item in the Theme submenu would do: which record it themes, and with what.
///
/// Carried on the item itself rather than read from the controller when it fires, because the
/// submenu is built from three places — a session's `⋯`, a session's right-click, a project's
/// menu — and ambient "whichever row was last clicked" state is exactly what gets stale
/// between them.
struct ThemeMenuChoice {

    enum Target {
        case session(SessionID)
        case project(ProjectID)
    }

    let target: Target

    /// Nil clears the assignment, so the record inherits again.
    let themeName: String?
}

// MARK: - Theme Menu

/// The Theme submenu, offered on a session row and on a project row alike.
///
/// It sits in the row's own menu rather than in Settings because a scope is chosen *at* the
/// thing it applies to — the same placement as the surface switch and the project icon. The
/// app-wide default stays in Settings, which is the scope with no row to hang from.
extension ProjectSidebarViewController {

    /// A session's theme: its own choice, or inheriting whatever its project and the default
    /// resolve to.
    func makeSessionThemeItem(for sessionID: SessionID) -> NSMenuItem {
        makeThemeItem(
            target: .session(sessionID),
            assigned: ThemeAssignments.themeName(forSession: sessionID),
            inherited: ThemeAssignments.inheritedName(forSession: sessionID)
        )
    }

    /// A project's theme, which every session inside it follows unless it names its own.
    func makeProjectThemeItem(for projectID: ProjectID) -> NSMenuItem {
        makeThemeItem(
            target: .project(projectID),
            assigned: ThemeAssignments.themeName(forProject: projectID),
            inherited: ThemeAssignments.inheritedName(forProject: projectID)
        )
    }

    /// One builder for both scopes: they differ in what they read and write, not in what
    /// they offer.
    ///
    /// "Inherit" names what it inherits, because it is otherwise the one choice in the list
    /// whose result the user cannot see.
    private func makeThemeItem(
        target: ThemeMenuChoice.Target,
        assigned: String?,
        inherited: String
    ) -> NSMenuItem {
        let submenu = NSMenu()

        submenu.addItem(themeChoiceItem(
            title: "Inherit (\(inherited))",
            choice: ThemeMenuChoice(target: target, themeName: nil),
            isChecked: assigned == nil
        ))
        submenu.addItem(.separator())

        for theme in ThemeManager.shared.allThemes {
            let item = themeChoiceItem(
                title: theme.name,
                choice: ThemeMenuChoice(target: target, themeName: theme.name),
                isChecked: theme.name == assigned
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
            ThemeAssignments.setTheme(named: choice.themeName, forSession: sessionID)
        case .project(let projectID):
            ThemeAssignments.setTheme(named: choice.themeName, forProject: projectID)
        }
    }

    @objc private func editThemesClicked() {
        guard let index = SettingsPages.index(ofTitle: SettingsPages.themesTitle) else { return }
        delegate?.projectSidebar(self, didSelectSettingsPage: index)
    }
}

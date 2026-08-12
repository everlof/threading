import AppKit

// MARK: - Theme Choice

/// What one item in the Theme submenu would do: which record it themes, and with what.
///
/// Carried in the row's own closure rather than read from the controller when it fires,
/// because the submenu is built from several places — a session's `⋯`, a session's
/// right-click, a project's menu, the toolbar's context button — and ambient "whichever row
/// was last clicked" state is exactly what gets stale between them.
struct ThemeMenuChoice {

    enum Target {
        case session(SessionID)
        case terminal(TerminalID)
        case project(ProjectID)
    }

    let target: Target

    /// Nil clears the assignment, so the record inherits again.
    let themeID: TerminalThemeID?
}

// MARK: - Theme Menu Builder

/// Builds the Theme submenu, offered wherever a theme is chosen at the thing it applies to:
/// the sidebar rows' menus, and the pane header's Context button.
///
/// A class rather than free functions because "Edit Themes…" needs a way to Settings that the
/// presenter owns; each presenter keeps one and tells it how that door opens.
@MainActor
final class ThemeMenuBuilder {

    /// Opens the Themes settings page, in whatever way the presenter reaches Settings.
    var onEditThemes: (() -> Void)?

    /// A session's theme: its own choice, or inheriting whatever its project and the default
    /// resolve to.
    func sessionThemeEntry(for sessionID: SessionID) -> ThemedMenuEntry {
        makeThemeEntry(
            target: .session(sessionID),
            assigned: ThemeAssignments.themeID(forSession: sessionID),
            inherited: ThemeAssignments.inheritedName(forSession: sessionID)
        )
    }

    /// A project's theme, which every session inside it follows unless it names its own.
    func projectThemeEntry(for projectID: ProjectID) -> ThemedMenuEntry {
        makeThemeEntry(
            target: .project(projectID),
            assigned: ThemeAssignments.themeID(forProject: projectID),
            inherited: ThemeAssignments.inheritedName(forProject: projectID)
        )
    }

    func terminalThemeEntry(for terminalID: TerminalID) -> ThemedMenuEntry {
        makeThemeEntry(
            target: .terminal(terminalID),
            assigned: ThemeAssignments.themeID(forTerminal: terminalID),
            inherited: ThemeAssignments.inheritedName(forTerminal: terminalID)
        )
    }

    // MARK: - Private Methods

    /// One builder for both scopes: they differ in what they read and write, not in what
    /// they offer.
    ///
    /// "Inherit" names what it inherits, because it is otherwise the one choice in the list
    /// whose result the user cannot see.
    private func makeThemeEntry(
        target: ThemeMenuChoice.Target,
        assigned: TerminalThemeID?,
        inherited: String
    ) -> ThemedMenuEntry {
        var rows: [ThemedMenuEntry] = [
            themeChoiceEntry(
                title: L10n.format("Inherit (%@)", inherited),
                choice: ThemeMenuChoice(target: target, themeID: nil),
                isChecked: assigned == nil
            ),
            .separator
        ]

        // Above the list and separated from it, because it is not one of the palettes — it is
        // the answer "whatever the app theme says", which changes when the app theme does.
        rows.append(themeChoiceEntry(
            title: TerminalThemeNames.followsAppTheme,
            choice: ThemeMenuChoice(target: target, themeID: .followsAppTheme),
            isChecked: assigned == .followsAppTheme,
            image: ThemeSwatchImage.menuSwatch(for: AppThemeLibrary.current.terminalPalette)
        ))
        rows.append(.separator)

        for theme in ThemeManager.shared.allThemes {
            rows.append(themeChoiceEntry(
                title: theme.name,
                choice: ThemeMenuChoice(target: target, themeID: theme.id),
                isChecked: theme.id == assigned,
                image: ThemeSwatchImage.menuSwatch(for: theme)
            ))
        }

        rows.append(.separator)
        rows.append(.item(ThemedMenuItem(
            title: L10n.string("Edit Themes…"),
            onChoose: { [weak self] in self?.onEditThemes?() }
        )))

        return .item(ThemedMenuItem(
            title: L10n.string("Theme"),
            image: ThemedMenuIcon.symbol("paintpalette"),
            submenu: rows
        ))
    }

    private func themeChoiceEntry(
        title: String,
        choice: ThemeMenuChoice,
        isChecked: Bool,
        image: NSImage? = nil
    ) -> ThemedMenuEntry {
        .item(ThemedMenuItem(
            title: title,
            image: image,
            representedValue: choice,
            isSelected: isChecked,
            onChoose: { Self.apply(choice) }
        ))
    }

    // MARK: - Handlers

    private static func apply(_ choice: ThemeMenuChoice) {
        switch choice.target {
        case .session(let sessionID):
            ThemeAssignments.setTheme(id: choice.themeID, forSession: sessionID)
        case .terminal(let terminalID):
            ThemeAssignments.setTheme(id: choice.themeID, forTerminal: terminalID)
        case .project(let projectID):
            ThemeAssignments.setTheme(id: choice.themeID, forProject: projectID)
        }
    }
}

// MARK: - Sidebar Wrappers

/// The submenu sits in a row's own menu rather than in Settings because a scope is chosen
/// *at* the thing it applies to — the same placement as the surface switch and the project
/// icon. The app-wide default stays in Settings, which is the scope with no row to hang from.
extension ProjectSidebarViewController {

    func sessionThemeEntry(for sessionID: SessionID) -> ThemedMenuEntry {
        sidebarThemeBuilder().sessionThemeEntry(for: sessionID)
    }

    func projectThemeEntry(for projectID: ProjectID) -> ThemedMenuEntry {
        sidebarThemeBuilder().projectThemeEntry(for: projectID)
    }

    func terminalThemeEntry(for terminalID: TerminalID) -> ThemedMenuEntry {
        sidebarThemeBuilder().terminalThemeEntry(for: terminalID)
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

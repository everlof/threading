import Foundation

/// The command names only a theme. Its second input carries an explicit, freshly validated
/// assignment scope; no active tab or ambient selection can redirect it.
enum TerminalThemeCommandScope: Equatable {
    case defaultTheme
    case project(ProjectID)
    case session(SessionID)
    case terminal(TerminalID)

    var id: String {
        switch self {
        case .defaultTheme: return "default"
        case .project(let id): return "project." + id.uuidString.lowercased()
        case .session(let id): return "session." + id.uuidString.lowercased()
        case .terminal(let id): return "terminal." + id.uuidString.lowercased()
        }
    }

    init?(id: String) {
        if id == "default" { self = .defaultTheme; return }
        let parts = id.split(separator: ".", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let value = String(parts[1])
        switch parts[0] {
        case "project": guard let id = ProjectID(uuidString: value) else { return nil }; self = .project(id)
        case "session": guard let id = SessionID(uuidString: value) else { return nil }; self = .session(id)
        case "terminal": guard let id = TerminalID(uuidString: value) else { return nil }; self = .terminal(id)
        default: return nil
        }
    }
}

@MainActor
enum TerminalThemeCommands {
    static func options(projects: [Project]) -> [HostCommandInputOption] {
        var result = [HostCommandInputOption(id: TerminalThemeCommandScope.defaultTheme.id,
                                            title: L10n.string("Default terminal theme"),
                                            detail: L10n.string("Terminals without a project or session override"))]
        for project in projects {
            result.append(.init(id: TerminalThemeCommandScope.project(project.id).id,
                                title: project.name, detail: L10n.string("Project")))
            result += project.sessions.filter { !$0.isArchived }.map { session in
                .init(id: TerminalThemeCommandScope.session(session.id).id,
                      title: session.displayTitle,
                      detail: L10n.format("Session · %@", project.name))
            }
            result += project.terminals.map { terminal in
                .init(id: TerminalThemeCommandScope.terminal(terminal.id).id,
                      title: terminal.displayTitle, detail: L10n.format("Terminal · %@", project.name))
            }
        }
        return result
    }

    static func apply(themeID: String, targetID: String) -> String? {
        guard let theme = ThemeAssignments.selectableTheme(withID: TerminalThemeID(rawValue: themeID)) else {
            return AppearanceActivationError.themeUnavailable.localizedDescription
        }
        guard let target = TerminalThemeCommandScope(id: targetID) else {
            return L10n.string("That selection is no longer available.")
        }
        let result: ProjectMutationResult
        switch target {
        case .defaultTheme:
            ThemeAssignments.setDefaultTheme(theme)
            return nil
        case .project(let id): result = ThemeAssignments.setTheme(id: theme.id, forProject: id)
        case .session(let id): result = ThemeAssignments.setTheme(id: theme.id, forSession: id)
        case .terminal(let id): result = ThemeAssignments.setTheme(id: theme.id, forTerminal: id)
        }
        return result.succeeded ? nil : L10n.string("The terminal theme could not be saved for that selection.")
    }
}

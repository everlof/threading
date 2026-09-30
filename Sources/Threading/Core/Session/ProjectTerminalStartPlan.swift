import Foundation

/// Resolves a saved terminal's start directory from host-provided availability. The terminal
/// keeps its owning project even when its recorded directory lies in another checkout.
/// Hosts retain directory probes, launch admission, shell/profile setup and persistence.
struct ProjectTerminalStartPlan: Sendable {
    let terminalID: TerminalID
    let projectID: ProjectID
    let directory: URL

    init(terminal: ProjectTerminal, project: Project, preferredDirectoryIsAvailable: Bool) {
        terminalID = terminal.id
        projectID = project.id
        directory = preferredDirectoryIsAvailable
            ? URL(fileURLWithPath: terminal.currentDirectory, isDirectory: true)
            : project.folderURL
    }
}

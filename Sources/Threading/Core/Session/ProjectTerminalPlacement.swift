import Foundation

/// Decides where a standalone terminal belongs in the sidebar from its reported cwd.
///
/// A terminal only moves to another project when that project is already known and contains
/// the cwd in the same git worktree. Moving through an unrelated directory therefore leaves it
/// in its home project instead of silently adding or guessing a project.
enum ProjectTerminalPlacement {
    static func projectID(
        for terminal: ProjectTerminal,
        homeProject: Project,
        projects: [Project]
    ) -> ProjectID {
        let directory = normalized(terminal.currentDirectory)
        guard let identity = GitInfo.worktreeIdentity(for: directory) else {
            return homeProject.id
        }

        let matches = projects.filter { project in
            contains(directory, in: normalized(project.folderPath))
                && GitInfo.worktreeIdentity(for: project.folderPath) == identity
        }

        return matches.max { lhs, rhs in
            normalized(lhs.folderPath).count < normalized(rhs.folderPath).count
        }?.id ?? homeProject.id
    }

    private static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func contains(_ path: String, in folder: String) -> Bool {
        path == folder || path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
    }
}

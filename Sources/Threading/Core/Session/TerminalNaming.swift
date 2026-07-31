import Foundation

/// What a terminal is called when nobody has named it.
///
/// A standalone terminal used to be born `"Terminal"` and stay that way, because under
/// Threading a stock `zsh` reports no title at all: Apple's title hook lives in
/// `/etc/zshrc_Apple_Terminal` and `/etc/zshrc` sources it only when `TERM_PROGRAM` says
/// `Apple_Terminal`, which ours says `Threading`. Copying that value to inherit the hook would
/// be a lie the rest of the environment has to keep — every tool that branches on
/// `TERM_PROGRAM` would branch wrongly.
///
/// It would not help much anyway. Even in Terminal.app that hook only reports the **directory**
/// (OSC 7); Terminal composes the tab's name itself from the directory and whatever is running.
/// So does this. The ladder, highest first:
///
/// 1. `custom` — an explicit rename, which wins and stops following, exactly as it does for a
///    conversation (`AgentSession.displayTitle`).
/// 2. `reported` — an OSC 0/2 title, set by `vim`, `ssh`, `tmux` or anything else that names
///    its own window. A program that has said what it is has said it better than we can.
///    Whoever stores this is responsible for dropping it when the program that set it exits;
///    nothing resets a title here, so a kept one goes stale. See
///    `TerminalSession.refreshForegroundProcess()`.
/// 3. `derived` — the directory, or the command running in it.
/// 4. `TerminalNamingDefaults.fallback`, which now names only a record whose shell never ran.
///
/// The derived rung deliberately does **not** use the directory's last component alone. A
/// terminal's sidebar row sits directly beneath its project's row, which already carries the
/// folder name, so a terminal at the project root would simply repeat the line above it. The
/// codebase reached the same conclusion once before from the other direction:
/// `SessionNaming.isNoiseTitle` rejects an agent title equal to the project name or its folder
/// basename. Naming relative to the project keeps the row saying the part the project does not
/// already say — *which* terminal this is, and where it has got to.
enum TerminalNaming {

    // MARK: - The Ladder

    /// The whole ladder, resolved. `directory` and `shellPath` are the only required inputs
    /// because they are the only two that always exist — a dormant terminal has both.
    static func displayTitle(
        custom: String?,
        reported: String?,
        directory: String,
        projectRoot: String?,
        foregroundProcess: String?,
        shellPath: String
    ) -> String {
        if let custom = trimmed(custom) { return custom }
        if let reported = trimmed(reported), !isPlaceholder(reported) { return reported }
        return derived(
            directory: directory,
            projectRoot: projectRoot,
            foregroundProcess: foregroundProcess,
            shellPath: shellPath
        )
    }

    /// The name a terminal earns from where it is and what it is doing.
    ///
    /// A running command wins over the directory for the reason Terminal.app makes the same
    /// choice: while `npm run dev` is up, *that* is what the tab is, and the directory is
    /// already implied by it. When the command exits the directory comes back on its own,
    /// because this is computed rather than stored.
    static func derived(
        directory: String,
        projectRoot: String?,
        foregroundProcess: String?,
        shellPath: String
    ) -> String {
        if let foreground = trimmed(foregroundProcess) { return foreground }

        let shell = shellName(shellPath)
        let directory = normalized(directory)
        guard !directory.isEmpty, directory != "/" else { return shell }

        if let root = projectRoot.map(normalized), !root.isEmpty {
            // At the project's own folder the row above already says the name; say what this
            // terminal *is* instead, which is a shell sitting at the top of the project.
            if directory == root { return shell }
            if let relative = relativePath(of: directory, under: root) { return relative }
        }

        return outsideProjectName(for: directory) ?? shell
    }

    /// Whether a stored title says nothing — the literal `"Terminal"` every record created
    /// before this ladder existed still carries, or a bare shell path.
    ///
    /// Checked rather than migrated: the placeholder is not wrong, only empty, and a record
    /// that has never been renamed has nothing to preserve. Recognising it costs one comparison
    /// and spares a state-version bump.
    static func isPlaceholder(_ title: String) -> Bool {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty || title == TerminalNamingDefaults.fallback { return true }
        // `TerminalSession.title` starts life as the profile's shell path, so a caller that
        // reads it before the first OSC report hands us `/bin/zsh` rather than a name.
        return title.hasPrefix("/") && !title.contains(" ")
    }

    // MARK: - Private Methods

    /// The shell's own name, as `ps` would print it. A login shell is conventionally exec'd
    /// with a leading dash (`-zsh`), which names the same program.
    private static func shellName(_ shellPath: String) -> String {
        var name = (shellPath as NSString).lastPathComponent
        if name.hasPrefix("-") { name.removeFirst() }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? TerminalNamingDefaults.fallback : trimmed
    }

    /// `Sources/Threading` rather than `Threading`: the leaf alone is ambiguous across a
    /// project with parallel folders, and the path is what answers "where has this one got to".
    private static func relativePath(of directory: String, under root: String) -> String? {
        let root = root.hasSuffix("/") ? String(root.dropLast()) : root
        guard directory.hasPrefix(root + "/") else { return nil }
        let relative = String(directory.dropFirst(root.count + 1))
        return relative.isEmpty ? nil : relative
    }

    /// A directory that belongs to no project. Home reads as `~`; anything else keeps its last
    /// two components, which is enough to tell `client/src` from `server/src` without spending
    /// the width a full path would.
    private static func outsideProjectName(for directory: String) -> String? {
        let home = normalized(NSHomeDirectory())
        if directory == home { return TerminalNamingDefaults.homeName }

        let components = directory.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return nil }
        return components.suffix(TerminalNamingDefaults.pathComponentsShown).joined(separator: "/")
    }

    /// The same normalization `ProjectTerminalPlacement` uses, and deliberately so: that is what
    /// decides which project a terminal is shown under, and a name stated relative to a project
    /// must agree with it about what "under" means. A cwd arrives here already symlink-resolved
    /// (`ProjectStore.updateTerminalLocation`) while a project folder is stored as the user
    /// added it, so `/tmp/x` and `/private/tmp/x` would otherwise fail to match.
    private static func normalized(_ path: String) -> String {
        let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return "" }
        return URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        return value
    }
}

// MARK: - Standalone Terminals

/// Gathers the two inputs `TerminalNaming` needs that a `ProjectTerminal` record does not hold:
/// the project it is currently *shown* under, and the command running in it right now.
///
/// Split from the rules themselves so the rules stay pure — they can be tested against a
/// directory and a string without a process, a store or a window.
@MainActor
enum ProjectTerminalTitle {

    /// The name to show when the caller already knows which project the terminal sits under.
    ///
    /// The sidebar must use this form. `ProjectTerminalPlacement` reads git metadata off disk
    /// for every project to decide placement, and the tree builder has already paid that once
    /// for the whole tree — a row that resolved it again would pay it per row, per reload.
    static func displayTitle(for terminal: ProjectTerminal, projectRoot: String?) -> String {
        TerminalNaming.displayTitle(
            custom: terminal.customTitle,
            reported: terminal.title,
            directory: terminal.currentDirectory,
            projectRoot: projectRoot,
            foregroundProcess: ProjectTerminalRuntime.shared
                .controller(for: terminal.id)?
                .session
                .foregroundProcessName,
            shellPath: ProfileStorage.shared.defaultProfile.shellPath
        )
    }

    /// The same, for the callers that hold a terminal with no tree around it — the toolbar
    /// title, a rename sheet's placeholder, the notice when a shell exits.
    static func displayTitle(for terminal: ProjectTerminal) -> String {
        displayTitle(
            for: terminal,
            projectRoot: ProjectStore.shared
                .displayProject(forTerminalID: terminal.id)?
                .folderPath
        )
    }
}

// MARK: - Defaults

enum TerminalNamingDefaults {
    /// What a terminal is called with nothing to go on: no directory, no shell, no process.
    ///
    /// Deliberately **not** localized, unlike the same word on a menu item or a rename sheet.
    /// This value is written into the store as a record's placeholder title and read back by
    /// `TerminalNaming.isPlaceholder`; translated, it would stop matching the moment the user
    /// changed language, and every terminal named before the switch would look renamed.
    static let fallback = "Terminal"

    /// The home folder, written the way every other path in this app is written.
    static let homeName = "~"

    /// How much of a path outside any project a name keeps. Two components distinguish sibling
    /// folders; three start costing more sidebar width than they explain.
    static let pathComponentsShown = 2
}

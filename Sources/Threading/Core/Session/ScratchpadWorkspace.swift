import Foundation

// MARK: - Defaults

/// Where the scratchpad lives, and what Threading puts in it the first time.
enum ScratchpadDefaults {

    /// The container Threading owns in the user's home directory. A container rather than a
    /// bare `Threading Scratchpad`, so anything else the app ever has to keep somewhere the
    /// user can reach has a home already named — and so the path has no space in it, which
    /// matters for a folder people `cd` into.
    static let containerName = "Threading"

    static let folderName = "Scratchpad"

    static let readmeName = "README.md"
    static let gitignoreName = ".gitignore"

    /// Deliberately tiny. This is a folder the user writes in; an opinionated ignore list
    /// would be Threading deciding what their notes are allowed to contain.
    static let ignoredEntries = [".DS_Store"]

    /// The override, under `PreferenceStore` rather than `AppSettings`: this records a
    /// *choice*, and a hosted test that wrote it to `.standard` would repoint the developer's
    /// real scratchpad at whatever fixture path it happened to use.
    static let folderPathKey = "scratchpadFolderPath"
}

// MARK: - Workspace

/// The folder behind scratchpad chats — the ones that belong to no project.
///
/// **Why the home directory and not Application Support.** Reset Everything renames the whole
/// Application Support ▸ Threading directory into a dated backup (`AppDataReset`), which is
/// right for state the app derived and wrong for prose the user wrote: the app would come back
/// "as if newly installed" with their notes sitting in a folder they will never look in. A
/// managed worktree can live there because it is reproducible from a real checkout. A
/// scratchpad is reproducible from nothing. Putting it under the home directory takes it out of
/// the reset's blast radius *by construction*, so there is no exclusion list for someone to
/// delete later.
///
/// **Why not `~/Documents` or `~/Desktop`.** TCC attributes a supervised child's file access to
/// the app that spawned it, so the agent's first write would raise Threading's Documents
/// prompt — spending a permission dialog on a user's first scratchpad message. Those folders
/// are also what iCloud's "Desktop & Documents" syncs, and a `.git` directory inside a synced
/// folder is a known corruption and performance hazard. See
/// [`permissions.md`](../../../../docs/architecture/permissions.md).
///
/// The folder is created lazily, on the first scratchpad — nobody gets a directory in their
/// home for a feature they never used.
enum ScratchpadWorkspace {

    // MARK: - Failure

    enum Failure: LocalizedError, Equatable {
        case notADirectory(String)
        case couldNotCreate(String)
        case destinationExists(String)
        case couldNotMove(String)

        var errorDescription: String? {
            switch self {
            case .notADirectory(let path):
                return L10n.format("Something that is not a folder is already at %@.", path)
            case .couldNotCreate(let reason):
                return L10n.format("The scratchpad folder could not be created: %@", reason)
            case .destinationExists(let path):
                return L10n.format("Something is already at %@.", path)
            case .couldNotMove(let reason):
                return L10n.format("The scratchpad folder could not be moved: %@", reason)
            }
        }
    }

    // MARK: - Location

    /// One spelling for a folder, so a URL that has been through the preference store as a path
    /// compares equal to the one an open panel just handed back.
    ///
    /// Not cosmetic. `URL(fileURLWithPath:)` produces a URL without the trailing slash that
    /// `appendingPathComponent(_:isDirectory: true)` leaves on, and the two are *unequal* while
    /// naming the same directory. `relocate` decides whether there is anything to do by
    /// comparing them, so without this, choosing the folder the scratchpad is already in read as
    /// a move onto itself — and failed with "something is already there".
    private static func directoryURL(_ url: URL) -> URL {
        URL(fileURLWithPath: url.standardizedFileURL.path, isDirectory: true)
    }

    /// `~/Threading/Scratchpad`.
    static var defaultFolderURL: URL {
        directoryURL(
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(ScratchpadDefaults.containerName, isDirectory: true)
                .appendingPathComponent(ScratchpadDefaults.folderName, isDirectory: true)
        )
    }

    /// The user's override, or nil when they have not moved it.
    static var configuredFolderURL: URL? {
        get {
            guard let path = PreferenceStore.shared.string(
                forKey: ScratchpadDefaults.folderPathKey
            ), path.hasPrefix("/") else { return nil }
            return directoryURL(URL(fileURLWithPath: path))
        }
        set {
            guard let newValue else {
                PreferenceStore.shared.removeObject(forKey: ScratchpadDefaults.folderPathKey)
                return
            }
            PreferenceStore.shared.set(
                newValue.standardizedFileURL.path,
                forKey: ScratchpadDefaults.folderPathKey
            )
        }
    }

    /// Where the scratchpad is now — the override if there is one, the default otherwise.
    static var folderURL: URL {
        configuredFolderURL ?? defaultFolderURL
    }

    // MARK: - Provisioning

    /// Creates the folder if it is not there, makes it a git repository, and seeds it — all
    /// idempotent, so every "New Scratchpad" can call it without asking what happened before.
    ///
    /// **The directory is required; the repository is not.** `/usr/bin/git` is the Command Line
    /// Tools shim, so on a Mac without them installed every git call here fails (and pops
    /// Apple's installer). A scratchpad without history is still a scratchpad, so git failure is
    /// logged and swallowed: what the caller gets back either way is a folder it can launch an
    /// agent in. Seeded files left uncommitted by a missing `user.email` simply show up as
    /// untracked in Git Review, which is the honest picture.
    @discardableResult
    static func prepare(at target: URL? = nil) throws -> URL {
        let root = directoryURL(target ?? folderURL)
        try makeDirectory(at: root)
        provisionRepository(at: root)
        return root
    }

    /// Moves an existing scratchpad to a new location and records the choice, or simply records
    /// it when there is nothing on disk yet. Returns the folder the scratchpad now answers to.
    ///
    /// The move is a rename rather than a copy-and-delete: the user's notes are the payload, and
    /// a half-copied folder is the one outcome that must not be reachable.
    @discardableResult
    static func relocate(to destination: URL?) throws -> URL {
        let source = folderURL
        let target = directoryURL(destination ?? defaultFolderURL)

        guard target != source else { return source }

        if isDirectory(at: source) {
            guard !FileManager.default.fileExists(atPath: target.path) else {
                throw Failure.destinationExists(target.path)
            }
            let parent = target.deletingLastPathComponent()
            do {
                try FileManager.default.createDirectory(
                    at: parent,
                    withIntermediateDirectories: true
                )
                try FileManager.default.moveItem(at: source, to: target)
            } catch {
                throw Failure.couldNotMove(error.localizedDescription)
            }
        }

        configuredFolderURL = target == defaultFolderURL ? nil : target
        ThreadingLogger.app.notice("Scratchpad relocated")
        return target
    }

    // MARK: - Private Methods

    private static func makeDirectory(at root: URL) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw Failure.notADirectory(root.path) }
            return
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            throw Failure.couldNotCreate(error.localizedDescription)
        }
    }

    /// `git init`, the seed files, and one commit — each step skipped when it has already
    /// happened, and none of them fatal.
    ///
    /// Plain `git init` rather than `--initial-branch`: naming the branch here would override
    /// whatever the user set `init.defaultBranch` to, in the one repository that is entirely
    /// theirs.
    private static func provisionRepository(at root: URL) {
        let entry = root.appendingPathComponent(GitDefaults.gitEntry)
        if !FileManager.default.fileExists(atPath: entry.path) {
            guard succeeds(["init"], in: root) else {
                ThreadingLogger.app.notice("Scratchpad git init unavailable; folder only")
                return
            }
        }

        seedFile(
            named: ScratchpadDefaults.readmeName,
            contents: readmeContents,
            in: root
        )
        seedFile(
            named: ScratchpadDefaults.gitignoreName,
            contents: ScratchpadDefaults.ignoredEntries.joined(separator: "\n") + "\n",
            in: root
        )

        // Only the very first time: after that the working tree is the user's business, and an
        // app that committed on their behalf would be rewriting a history it does not own.
        //
        // A repository with no commits answers this with a non-zero exit, which is an answer
        // rather than a failure — hence the probe form, so an empty scratchpad does not report
        // a git error every time one is opened.
        let hasCommits = succeeds(
            ["rev-parse", "--verify", "HEAD"],
            in: root,
            isProbe: true
        )
        guard !hasCommits else { return }

        let seeds = [ScratchpadDefaults.readmeName, ScratchpadDefaults.gitignoreName]
        guard succeeds(["add", "--"] + seeds, in: root),
              succeeds(["commit", "-m", L10n.string("Create the scratchpad")], in: root)
        else {
            ThreadingLogger.app.notice("Scratchpad initial commit skipped")
            return
        }
    }

    /// Writes the file only when it is absent — a README the user edited is theirs, and a
    /// second scratchpad must not overwrite it.
    private static func seedFile(named name: String, contents: String, in root: URL) {
        let url = root.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? contents.write(to: url, atomically: true, encoding: .utf8)
    }

    /// What somebody finds when they open this folder in Finder months later with no memory of
    /// agreeing to it.
    private static var readmeContents: String {
        "# " + L10n.string("Scratchpad") + "\n\n" + L10n.string(
            "Threading created this folder to hold chats that are not about any project. "
                + "It is an ordinary git repository, so nothing you write here is lost — and "
                + "nothing outside it belongs to Threading. You can move it, or point "
                + "Threading somewhere else, in Settings."
        ) + "\n"
    }

    /// `isProbe` marks a call whose non-zero exit is an ordinary negative answer rather than a
    /// failure, so it is not reported as one.
    private static func succeeds(
        _ arguments: [String],
        in root: URL,
        isProbe: Bool = false
    ) -> Bool {
        (try? GitProcess.run(arguments, in: root, reportsRejectedExit: !isProbe)) != nil
    }

    private static func isDirectory(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }
}

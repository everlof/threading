import Darwin
import Foundation

// MARK: - Command Line Tool Defaults

/// Names, permissions and bounds for the directory Threading publishes its command-line tools in.
///
/// One namespace, so the launch that refreshes the directory, the Settings row that installs a
/// link into it and the environment that puts it on `PATH` cannot each pick a different name.
enum ThreadingCommandLineToolDefaults {

    /// The directory under Application Support holding one symlink per public tool.
    ///
    /// A sibling of `bridge/` and `pty/`, and deliberately unlike both: those two are `0700`
    /// because the directory's permissions *are* the boundary around a socket and a token. This
    /// one holds no secret. Every entry is a symlink into a signed application bundle, and what
    /// is behind it is already readable by anyone who can read `/Applications`. So it is the
    /// ordinary `0755` of a `bin` directory a shell resolves through, and calling it a boundary
    /// would be claiming a protection it does not provide.
    static let directoryName = "bin"

    static let directoryPermissions = 0o755

    /// Where the app bundle keeps its `product-type.tool` helpers. Taken from `PTYHostDefaults`
    /// rather than spelled again: it is one fact about the bundle's layout, and two copies would
    /// be two places for "where are the helpers" to disagree.
    static let helpersDirectoryPath = PTYHostDefaults.helpersDirectoryPath

    /// Where a tool is installed for the user: `~/.local/bin`.
    ///
    /// No `sudo`, and nothing under `/usr/local`. This is the user's own directory, it is where
    /// the agent CLIs already install themselves, and it is one Threading may create without
    /// asking for an authorization it has no business holding.
    static let userBinaryDirectoryPath = ".local/bin"

    /// Created `0755` for the reason above: a directory the user's own shell resolves through.
    static let userBinaryDirectoryPermissions = 0o755

    /// A shim being written carries this prefix until `rename(2)` puts it in place, so the name
    /// a shell resolves is never a half-written directory entry. Left behind only by a crash
    /// between the two calls, and swept by the next refresh.
    static let temporaryShimPrefix = ".threading-shim-"
}

// MARK: - Threading Command Line Tools

/// The command-line tools Threading publishes, and the per-user directory it publishes them in.
///
/// **The indirection is the point.** A tool lives inside the app bundle, and the bundle moves:
/// `scripts/autoinstall.sh` replaces `/Applications/Threading.app` wholesale on every commit to
/// master, and a Debug build runs from a `Threading-<hash>` directory under DerivedData that is
/// a different path again. A symlink the user made straight into `Contents/Helpers` would break
/// the first time either happened, and would break *silently* — `command -v` still finds the
/// name, and the exec fails. So `~/.local/bin/threading-ptyd` points at a shim here, this
/// directory is rewritten at every launch to name the bundle that is actually running, and the
/// user-facing link never has to change.
///
/// Resolved through `StateManager`'s hosted-test redirect like every other per-user location. A
/// test bundle is hosted **inside** the shipping app, so without it a refresh in a test would
/// rewrite the developer's own shims to point at the test host's bundle.
enum ThreadingCommandLineTools {

    // MARK: - Public Tools

    /// Every tool Threading publishes, named once.
    ///
    /// Adding a name here is the whole of adding a tool: the launch refresh links it, the
    /// Settings row can install it, and the opt-in `PATH` entry finds it. `threading-ptyd` is
    /// the first because it is the one process that outlives the app, so "what is still running"
    /// is a question worth being able to ask from a terminal.
    static let publicTools: [String] = [PTYHostDefaults.helperName]

    // MARK: - Locations

    /// `~/Library/Application Support/Threading`, or this test process's scratch root.
    static var supportRoot: URL {
        StateManager.isHostedTest
            ? StateManager.hostedTestDirectory()
            : AppDataLocations.supportDirectory
    }

    /// The directory holding one symlink per public tool.
    static var directory: URL {
        supportRoot.appendingPathComponent(
            ThreadingCommandLineToolDefaults.directoryName,
            isDirectory: true
        )
    }

    /// The shim a user-facing link points at. Stable across bundle moves, which is its whole job.
    static func shimURL(
        for tool: String,
        in directory: URL = ThreadingCommandLineTools.directory
    ) -> URL {
        directory.appendingPathComponent(tool, isDirectory: false)
    }

    /// Where the tool lives inside a bundle, whether or not it is there.
    ///
    /// A *candidate*, exactly as `PTYHostLocation.helperURL(in:)` is: existence is checked once,
    /// by the refresh, rather than by two callers that can disagree.
    ///
    /// Addressed by bundle **URL** rather than by `Bundle`, so a test can stand up a directory
    /// that holds a helper and one that does not. The bundle's identity is not in the question:
    /// this is a path inside it.
    static func helperURL(for tool: String, inBundleAt bundleURL: URL) -> URL {
        bundleURL
            .appendingPathComponent(
                ThreadingCommandLineToolDefaults.helpersDirectoryPath,
                isDirectory: true
            )
            .appendingPathComponent(tool, isDirectory: false)
    }

    // MARK: - Refresh

    /// What a refresh did. Empty everywhere is the ordinary launch, and the reason nothing is
    /// journalled per launch.
    struct RefreshOutcome: Equatable {
        var created: [String] = []
        var replaced: [String] = []
        var removed: [String] = []
        /// Published tools this bundle does not ship. Not a failure: a build without the helper
        /// gets no link rather than a link to a file that is not there.
        var unavailable: [String] = []
        /// Names a public tool claims where something that is not our symlink already sits. Left
        /// exactly as found.
        var foreign: [String] = []

        var changedAnything: Bool {
            !created.isEmpty || !replaced.isEmpty || !removed.isEmpty
        }
    }

    /// Rewrites the shim directory to name the running bundle.
    ///
    /// Idempotent by construction: a link already pointing where it should is left untouched, so
    /// the ordinary launch performs one `readlink` per tool and writes nothing. A link that is
    /// wrong is replaced through `rename(2)` rather than unlink-then-create, so no window exists
    /// in which the name resolves to nothing.
    ///
    /// **Only our own entries are touched.** A name a public tool claims that holds something
    /// other than a symlink is reported and left alone, and an entry that is not one of ours is
    /// removed only when it is a symlink into some bundle's `Contents/Helpers` under its own
    /// name — which is the shape this method writes and nothing else does.
    @discardableResult
    static func refresh(
        bundleURL: URL = Bundle.main.bundleURL,
        directory: URL = ThreadingCommandLineTools.directory,
        fileManager: FileManager = .default
    ) -> RefreshOutcome {
        var outcome = RefreshOutcome()
        guard prepareDirectory(directory, fileManager: fileManager) else { return outcome }

        for tool in publicTools {
            let link = shimURL(for: tool, in: directory)
            let helper = helperURL(for: tool, inBundleAt: bundleURL)
            let existing = entry(at: link, fileManager: fileManager)

            guard fileManager.isExecutableFile(atPath: helper.path) else {
                // A build that does not ship this tool, or a tool being retired. A dangling link
                // is worse than no link: the shell still finds the name and the exec fails.
                if case .symbolicLink = existing, unlink(link.path) == 0 {
                    outcome.removed.append(tool)
                }
                outcome.unavailable.append(tool)
                continue
            }

            switch existing {
            case .symbolicLink(let destination) where destination == helper.path:
                continue
            case .symbolicLink:
                if replaceSymbolicLink(at: link, withDestination: helper) {
                    outcome.replaced.append(tool)
                }
            case .missing:
                if replaceSymbolicLink(at: link, withDestination: helper) {
                    outcome.created.append(tool)
                }
            case .other:
                outcome.foreign.append(tool)
            }
        }

        outcome.removed.append(
            contentsOf: removeObsoleteEntries(in: directory, fileManager: fileManager)
        )
        return outcome
    }

    /// The launch call: refreshes, and writes one journal line when the set actually moved.
    ///
    /// Nothing is recorded on an unchanged launch, which is every launch after the first from a
    /// given bundle. A line here means the tools now point somewhere else, which is exactly the
    /// fact worth having when `threading-ptyd` in a terminal starts answering differently.
    static func refreshAtLaunch(bundleURL: URL = Bundle.main.bundleURL) {
        let outcome = refresh(bundleURL: bundleURL)
        guard outcome.changedAnything else { return }

        var detail: [String: String] = ["directory": directory.path]
        if !outcome.created.isEmpty { detail["created"] = outcome.created.joined(separator: " ") }
        if !outcome.replaced.isEmpty {
            detail["replaced"] = outcome.replaced.joined(separator: " ")
        }
        if !outcome.removed.isEmpty { detail["removed"] = outcome.removed.joined(separator: " ") }
        EventLog.shared.record(.app, "Command line tools refreshed", detail)
    }

    // MARK: - Directory

    /// Creates the directory if it is missing and re-applies its permissions either way, the
    /// same correction `PTYHostLocation.prepareDirectory` makes and for the same reason: it may
    /// already exist from a build that created it under a different mask.
    @discardableResult
    static func prepareDirectory(
        _ directory: URL = ThreadingCommandLineTools.directory,
        permissions: Int = ThreadingCommandLineToolDefaults.directoryPermissions,
        fileManager: FileManager = .default
    ) -> Bool {
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: permissions]
            )
            try fileManager.setAttributes(
                [.posixPermissions: permissions],
                ofItemAtPath: directory.path
            )
            return true
        } catch {
            ThreadingLogger.app.error(
                """
                Could not prepare the command-line tools directory: \
                \(error.localizedDescription, privacy: .private(mask: .hash))
                """
            )
            return false
        }
    }

    // MARK: - Links

    /// What sits at a path, without following the last symlink.
    enum Entry: Equatable {
        case missing
        case symbolicLink(destination: String)
        /// A regular file, a directory, or anything else. Never ours, never touched.
        case other
    }

    static func entry(at url: URL, fileManager: FileManager = .default) -> Entry {
        // `attributesOfItem` is `lstat`-shaped: it describes the link rather than its target,
        // which is the only question worth asking about a directory of symlinks.
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
            return .missing
        }
        guard attributes[.type] as? FileAttributeType == .typeSymbolicLink else { return .other }
        guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: url.path) else {
            return .other
        }
        return .symbolicLink(destination: destination)
    }

    /// Points `link` at `destination`, replacing whatever link was there, atomically.
    ///
    /// `symlink(2)` into a uniquely named neighbour and then `rename(2)` over the final name.
    /// `rename` replaces the destination in one step and does not follow it, so a shell that
    /// resolves the name at any instant gets either the old tool or the new one and never
    /// nothing. Unlinking first would open exactly that window on every launch.
    @discardableResult
    static func replaceSymbolicLink(at link: URL, withDestination destination: URL) -> Bool {
        let temporary = link
            .deletingLastPathComponent()
            .appendingPathComponent(
                ThreadingCommandLineToolDefaults.temporaryShimPrefix + UUID().uuidString,
                isDirectory: false
            )
        guard symlink(destination.path, temporary.path) == 0 else { return false }
        guard rename(temporary.path, link.path) == 0 else {
            unlink(temporary.path)
            return false
        }
        return true
    }

    // MARK: - Private Methods

    /// Removes what this directory used to publish and no longer does, and nothing else.
    ///
    /// Two shapes qualify: a leftover temporary from a crash between `symlink` and `rename`, and
    /// a symlink named `<tool>` pointing at `…/Contents/Helpers/<tool>` for a `<tool>` that is
    /// no longer public. Everything else in the directory belongs to whoever put it there.
    private static func removeObsoleteEntries(
        in directory: URL,
        fileManager: FileManager
    ) -> [String] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
            return []
        }

        var removed: [String] = []
        for name in names.sorted() where !publicTools.contains(name) {
            let url = directory.appendingPathComponent(name, isDirectory: false)
            guard case .symbolicLink(let destination) = entry(at: url, fileManager: fileManager)
            else { continue }

            let isLeftoverTemporary = name.hasPrefix(
                ThreadingCommandLineToolDefaults.temporaryShimPrefix
            )
            let helpersSuffix =
                "/\(ThreadingCommandLineToolDefaults.helpersDirectoryPath)/\(name)"
            guard isLeftoverTemporary || destination.hasSuffix(helpersSuffix) else { continue }
            guard unlink(url.path) == 0 else { continue }
            removed.append(name)
        }
        return removed
    }
}

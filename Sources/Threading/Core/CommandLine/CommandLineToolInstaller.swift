import Darwin
import Foundation

// MARK: - Errors

enum CommandLineToolInstallError: LocalizedError, Equatable {
    /// Something that is not one of our links already holds the name.
    case pathOccupied(path: String)
    /// The link exists and points somewhere Threading did not put it.
    case pathNotOurs(path: String, destination: String)
    case directoryUnavailable(path: String)
    case linkFailed(path: String)

    var errorDescription: String? {
        switch self {
        case .pathOccupied(let path):
            return L10n.format("Something else is already at %@, so Threading left it alone.", path)
        case .pathNotOurs(let path, let destination):
            return L10n.format(
                "%1$@ already points at %2$@, so Threading left it alone.",
                path,
                destination
            )
        case .directoryUnavailable(let path):
            return L10n.format("Threading could not create %@.", path)
        case .linkFailed(let path):
            return L10n.format("Threading could not write %@.", path)
        }
    }
}

// MARK: - Status

/// What the user-facing link for one tool looks like right now.
struct CommandLineToolStatus: Equatable {

    /// Where the link is, or would be.
    enum Placement: Equatable {
        /// The link is there and points at Threading's shim.
        case installed
        /// Nothing holds the name.
        case absent
        /// A link is there pointing somewhere else. Not ours to move.
        case foreignLink(destination: String)
        /// A regular file or directory holds the name. Not ours to move either.
        case occupied
    }

    let tool: String
    let linkURL: URL
    let shimURL: URL
    let placement: Placement

    /// Whether `~/.local/bin` is on the login shell's `PATH`.
    ///
    /// Optional because the answer costs a login shell and arrives after the page has drawn.
    /// Nil means "not asked yet", which the row says nothing about rather than guessing.
    let directoryIsOnPATH: Bool?

    var isInstalled: Bool { placement == .installed }
}

// MARK: - Installer

/// Installs one of Threading's command-line tools where the user's shell will find it.
///
/// One symlink, `~/.local/bin/<tool>`, pointing at the shim under Application Support rather than
/// into the app bundle. The bundle moves — the autoinstall hook replaces `/Applications/Threading.app`
/// wholesale, and a Debug build runs from DerivedData — so a link straight into `Contents/Helpers`
/// would rot, and rot invisibly. The shim absorbs that, which is why the user-facing link is
/// written once and never has to be written again. See `ThreadingCommandLineTools`.
///
/// **No `sudo`, and nothing under `/usr/local`.** `~/.local/bin` is the user's own directory, it
/// is where the agent CLIs already put themselves, and creating it needs no authorization.
/// Threading also never edits a shell profile: if the directory is not on `PATH` the row says the
/// line to add, and adding it stays the user's decision.
enum CommandLineToolInstaller {

    // MARK: - Locations

    static func binaryDirectory(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home.appendingPathComponent(
            ThreadingCommandLineToolDefaults.userBinaryDirectoryPath,
            isDirectory: true
        )
    }

    static func linkURL(
        for tool: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        binaryDirectory(home: home).appendingPathComponent(tool, isDirectory: false)
    }

    // MARK: - Status

    static func status(
        for tool: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        shimDirectory: URL = ThreadingCommandLineTools.directory,
        directoryIsOnPATH: Bool? = nil,
        fileManager: FileManager = .default
    ) -> CommandLineToolStatus {
        let link = linkURL(for: tool, home: home)
        let shim = ThreadingCommandLineTools.shimURL(for: tool, in: shimDirectory)
        let placement: CommandLineToolStatus.Placement

        switch ThreadingCommandLineTools.entry(at: link, fileManager: fileManager) {
        case .missing:
            placement = .absent
        case .symbolicLink(let destination) where destination == shim.path:
            placement = .installed
        case .symbolicLink(let destination):
            placement = .foreignLink(destination: destination)
        case .other:
            placement = .occupied
        }

        return CommandLineToolStatus(
            tool: tool,
            linkURL: link,
            shimURL: shim,
            placement: placement,
            directoryIsOnPATH: directoryIsOnPATH
        )
    }

    // MARK: - Install and Remove

    /// Points `~/.local/bin/<tool>` at the shim, creating the directory if it is missing.
    ///
    /// Refuses rather than overwrites when the name holds something that is not one of our
    /// links. A tool named the same as one the user installed themselves is a collision worth
    /// reporting, not a file to replace on their behalf.
    static func install(
        tool: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        shimDirectory: URL = ThreadingCommandLineTools.directory,
        fileManager: FileManager = .default
    ) throws {
        let directory = binaryDirectory(home: home)
        guard ThreadingCommandLineTools.prepareDirectory(
            directory,
            permissions: ThreadingCommandLineToolDefaults.userBinaryDirectoryPermissions,
            fileManager: fileManager
        ) else {
            throw CommandLineToolInstallError.directoryUnavailable(path: directory.path)
        }

        let link = linkURL(for: tool, home: home)
        let shim = ThreadingCommandLineTools.shimURL(for: tool, in: shimDirectory)

        switch ThreadingCommandLineTools.entry(at: link, fileManager: fileManager) {
        case .other:
            throw CommandLineToolInstallError.pathOccupied(path: link.path)
        case .symbolicLink(let destination)
            where destination != shim.path && !isOursByShape(destination, tool: tool):
            throw CommandLineToolInstallError.pathNotOurs(
                path: link.path,
                destination: destination
            )
        case .missing, .symbolicLink:
            break
        }

        guard ThreadingCommandLineTools.replaceSymbolicLink(at: link, withDestination: shim) else {
            throw CommandLineToolInstallError.linkFailed(path: link.path)
        }
    }

    /// Removes the link, and only when it is one of ours.
    static func remove(
        tool: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        shimDirectory: URL = ThreadingCommandLineTools.directory,
        fileManager: FileManager = .default
    ) throws {
        let link = linkURL(for: tool, home: home)
        let shim = ThreadingCommandLineTools.shimURL(for: tool, in: shimDirectory)

        switch ThreadingCommandLineTools.entry(at: link, fileManager: fileManager) {
        case .missing:
            return
        case .other:
            throw CommandLineToolInstallError.pathOccupied(path: link.path)
        case .symbolicLink(let destination):
            guard destination == shim.path || isOursByShape(destination, tool: tool) else {
                throw CommandLineToolInstallError.pathNotOurs(
                    path: link.path,
                    destination: destination
                )
            }
            guard unlink(link.path) == 0 else {
                throw CommandLineToolInstallError.linkFailed(path: link.path)
            }
        }
    }

    // MARK: - PATH

    /// Whether `directory` is one of the entries in a `PATH` value.
    ///
    /// Pure and injectable, because the interesting cases are all about the string: a trailing
    /// slash, a `~` an older profile never expanded, an empty entry from a `PATH` that ends in a
    /// colon. The subprocess that produces the string is a separate concern below.
    nonisolated static func directory(_ directory: String, isOn pathVariable: String) -> Bool {
        let wanted = normalized(directory)
        guard !wanted.isEmpty else { return false }
        return pathVariable
            .split(separator: ":", omittingEmptySubsequences: false)
            .contains { normalized(String($0)) == wanted }
    }

    /// The user's login-shell `PATH`, read the way the launcher discovers the agent CLIs.
    ///
    /// The same login shell `AgentLauncher` starts a session in, so this answer and what a
    /// session actually resolves cannot disagree — a GUI app does not inherit the interactive
    /// `PATH`, and the whole question here is what the user's own profile adds to it.
    ///
    /// `/usr/bin/env` rather than an `echo "$PATH"`: `ShellCommand` quotes every word it is
    /// given, so no expansion syntax can be emitted, and an environment dump needs none.
    nonisolated static func loginShellPATH(
        shell: String,
        timeout: TimeInterval = CommandLineToolInstallerDefaults.pathProbeTimeout,
        maximumOutputBytes: Int = CommandLineToolInstallerDefaults.pathProbeOutputBytes
    ) -> String? {
        let command = ShellCommand(word: CommandLineToolInstallerDefaults.environmentCommand)
        guard let result = try? BoundedChildProcess.run(
            executable: shell,
            arguments: ["-l", "-c", command.source],
            timeout: timeout,
            maximumOutputBytes: maximumOutputBytes,
            output: .standardOutput
        ), result.termination == .exited(0), !result.outputWasTruncated else { return nil }

        return path(fromEnvironmentOutput: String(decoding: result.output, as: UTF8.self))
    }

    /// The pure half: the first `PATH=` line of an environment dump.
    nonisolated static func path(fromEnvironmentOutput output: String) -> String? {
        let prefix = "\(EnvironmentKeys.path)="
        for line in output.split(separator: "\n", omittingEmptySubsequences: false)
        where line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count))
        }
        return nil
    }

    /// The line to add to a shell profile when `~/.local/bin` is not on `PATH`.
    ///
    /// Shown, never written. Editing somebody's `.zprofile` is not a thing a settings row does.
    static var profileLine: String {
        "export PATH=\"$HOME/\(ThreadingCommandLineToolDefaults.userBinaryDirectoryPath):$PATH\""
    }

    // MARK: - Private Methods

    /// A link Threading wrote for this tool, recognised by shape rather than by an exact path.
    ///
    /// The shim directory moves between the real support directory and a hosted test's scratch
    /// root, and a link written by one build should still be replaceable by the next. The shape
    /// is narrow enough to be ours: `…/<directoryName>/<tool>`.
    private static func isOursByShape(_ destination: String, tool: String) -> Bool {
        destination.hasSuffix(
            "/\(ThreadingCommandLineToolDefaults.directoryName)/\(tool)"
        )
    }

    private static func normalized(_ entry: String) -> String {
        var path = (entry as NSString).expandingTildeInPath
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return (path as NSString).standardizingPath
    }
}

// MARK: - Defaults

enum CommandLineToolInstallerDefaults {
    /// One login shell, bounded like every other probe that starts one.
    static let pathProbeTimeout: TimeInterval = 5
    static let pathProbeOutputBytes = 64 * 1024
    static let environmentCommand = "/usr/bin/env"
}

// MARK: - Surface

/// The Advanced page's view of one installable tool, held apart from the page.
///
/// Everything that makes the answer specific to a machine is injectable — the home directory,
/// the shim directory, the bundle the tool would come from, and the login shell's `PATH` — for
/// two reasons. A render or a test can hold the row in any of its states without a link existing
/// on the developer's own machine; and a hosted test bundle runs *inside* the shipping app, so a
/// surface built by one must never be able to write into the developer's `~/.local/bin`.
///
/// The `PATH` answer arrives late on purpose. It costs a login shell, which is the only way to
/// see what the user's own profile exports, so the page draws immediately without it and gains
/// the sentence when the shell answers. Asked once per surface.
@MainActor
final class CommandLineToolsSurface {

    // MARK: - Properties

    /// Called when the answer moves and the page should redraw.
    var onChange: (() -> Void)?

    let tool: String

    private let home: URL
    private let shimDirectory: URL
    private let bundleURL: URL
    private let asksLoginShell: Bool
    private var loginShellPATH: String?
    private var didAskLoginShell = false

    private(set) var status: CommandLineToolStatus

    // MARK: - Initialization

    init(
        tool: String = ThreadingCommandLineTools.publicTools.first ?? PTYHostDefaults.helperName,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        shimDirectory: URL = ThreadingCommandLineTools.directory,
        bundleURL: URL = Bundle.main.bundleURL,
        loginShellPATH: String? = nil,
        asksLoginShell: Bool = !StateManager.isHostedTest
    ) {
        self.tool = tool
        self.home = home
        self.shimDirectory = shimDirectory
        self.bundleURL = bundleURL
        self.loginShellPATH = loginShellPATH
        self.asksLoginShell = asksLoginShell
        self.status = Self.read(
            tool: tool,
            home: home,
            shimDirectory: shimDirectory,
            loginShellPATH: loginShellPATH
        )
    }

    // MARK: - Public Methods

    /// Where the link is installed, shown in the row rather than described.
    var binaryDirectory: URL { CommandLineToolInstaller.binaryDirectory(home: home) }

    /// The line to add to a shell profile. Shown, never written.
    var profileLine: String { CommandLineToolInstaller.profileLine }

    /// Whether this bundle actually ships the tool.
    ///
    /// Not an error when it does not: `threading-ptyd` is built by a target that may not be in
    /// every configuration, and a row that offered to install a link to a file that is not there
    /// would be offering a broken command.
    var isShippedInBundle: Bool {
        FileManager.default.isExecutableFile(
            atPath: ThreadingCommandLineTools.helperURL(for: tool, inBundleAt: bundleURL).path
        )
    }

    func refresh() {
        let updated = Self.read(
            tool: tool,
            home: home,
            shimDirectory: shimDirectory,
            loginShellPATH: loginShellPATH
        )
        guard updated != status else { return }
        status = updated
        onChange?()
    }

    /// Asks the user's login shell what its `PATH` is, once.
    func readLoginShellPATH() {
        guard asksLoginShell, !didAskLoginShell, loginShellPATH == nil else { return }
        didAskLoginShell = true
        let shell = AgentLauncher.loginShellPath
        Task.detached(priority: .userInitiated) {
            let path = CommandLineToolInstaller.loginShellPATH(shell: shell)
            await MainActor.run { [weak self] in
                guard let self, let path else { return }
                self.loginShellPATH = path
                self.refresh()
            }
        }
    }

    func install() throws {
        // The shims are published first, so the link is never made to a name that is not there
        // yet: the launch refresh may not have run in this process, and a dangling link is the
        // exact failure the whole indirection exists to avoid.
        ThreadingCommandLineTools.refresh(bundleURL: bundleURL, directory: shimDirectory)
        try CommandLineToolInstaller.install(
            tool: tool,
            home: home,
            shimDirectory: shimDirectory
        )
        refresh()
    }

    func remove() throws {
        try CommandLineToolInstaller.remove(
            tool: tool,
            home: home,
            shimDirectory: shimDirectory
        )
        refresh()
    }

    // MARK: - Private Methods

    private static func read(
        tool: String,
        home: URL,
        shimDirectory: URL,
        loginShellPATH: String?
    ) -> CommandLineToolStatus {
        let directory = CommandLineToolInstaller.binaryDirectory(home: home)
        return CommandLineToolInstaller.status(
            for: tool,
            home: home,
            shimDirectory: shimDirectory,
            directoryIsOnPATH: loginShellPATH.map {
                CommandLineToolInstaller.directory(directory.path, isOn: $0)
            }
        )
    }
}

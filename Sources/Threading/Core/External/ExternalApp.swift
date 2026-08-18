import AppKit

// MARK: - External App

/// An application Threading can hand a checkout or one of its files to.
///
/// "Editor" would be the shorter name and the wrong one: Finder and Terminal are on this list
/// too, and what the list actually enumerates is *somewhere else the user already works*. The
/// app is a control surface for agents, so the way out to a real editor is a first-class action
/// rather than a copied path.
///
/// **Installation is decided by bundle identifier, not by a command on `PATH`.** That is the one
/// substantive difference from how the same feature is built on other platforms, and it is the
/// difference between offering VS Code and offering nothing: `code` exists only for users who
/// ran *Shell Command: Install 'code' in PATH*, while `com.microsoft.VSCode` is there the moment
/// the app is in `/Applications`. A GUI app does not inherit the interactive `PATH` anyway —
/// the reason every agent launch here goes through a login shell (`AgentLauncher.loginShellPath`)
/// — so a `PATH` probe would have to pay for a shell before it could answer a question
/// LaunchServices answers for free.
///
/// The command is still needed for one thing a `open`-style launch cannot express: **a line
/// number**. So both are recorded, and `ExternalAppLauncher` uses whichever the target needs.
struct ExternalApp: Identifiable, Equatable, Sendable {

    /// What the app can be handed.
    ///
    /// Terminal is folders-only on purpose: handing it a *file* runs the file, which is the one
    /// outcome nobody asks an "Open in" menu for.
    struct Accepts: OptionSet, Sendable {
        let rawValue: Int
        static let folder = Accepts(rawValue: 1 << 0)
        static let file = Accepts(rawValue: 1 << 1)
        static let both: Accepts = [.folder, .file]
    }

    /// How this app is told which line to land on, on the command line.
    ///
    /// Measured against each family's own CLI rather than assumed: the VS Code family takes
    /// `--goto path:line:column`, the JetBrains IDEs take `--line N path`, Sublime Text takes
    /// the position glued to the path, and Xcode's `xed` takes `--line N`. An app with no way
    /// to say it opens the file and lands wherever it last was.
    enum LinePosition: Sendable {
        case unsupported
        case gotoArgument
        case lineArgument
        case pathSuffix
    }

    /// Stable across releases: this is what the user's last choice is stored under, so renaming
    /// it silently forgets which app they picked.
    let id: String

    /// The app's own name, as its vendor spells it. Not localized — these are proper nouns.
    let name: String

    /// In preference order; the first one installed wins. More than one because an app can ship
    /// under two identifiers over its life, and because a family shares this list with its
    /// siblings only by name.
    let bundleIdentifiers: [String]

    /// The command-line tool, for the line-number path only.
    let commands: [String]

    let linePosition: LinePosition
    let accepts: Accepts

    init(
        id: String,
        name: String,
        bundleIdentifiers: [String],
        commands: [String] = [],
        linePosition: LinePosition = .unsupported,
        accepts: Accepts = .both
    ) {
        self.id = id
        self.name = name
        self.bundleIdentifiers = bundleIdentifiers
        self.commands = commands
        self.linePosition = linePosition
        self.accepts = accepts
    }

    func accepts(_ target: ExternalAppTarget) -> Bool {
        switch target {
        case .folder: return accepts.contains(.folder)
        case .file: return accepts.contains(.file)
        }
    }
}

// MARK: - Target

/// What is being opened.
///
/// A line is carried rather than looked up because only the caller knows it: a diff row knows
/// which line of the *new* file it draws, and a file tree knows none.
enum ExternalAppTarget: Equatable {
    case folder(URL)
    case file(URL, line: Int?)

    var url: URL {
        switch self {
        case .folder(let url): return url
        case .file(let url, _): return url
        }
    }

    var line: Int? {
        guard case .file(_, let line) = self else { return nil }
        return line
    }
}

// MARK: - The Registry

/// Every app Threading knows how to open something in, in the order a menu lists them.
///
/// Order is deliberate and not alphabetical: the editors people run agents beside come first,
/// the IDEs after them, and the two places that are *not* editors — a terminal and the file
/// manager — last, because they answer a different question. Nothing here is shown unless it is
/// installed, so a long list costs a user with three apps nothing.
enum ExternalApps {

    static let finderID = "finder"

    static let all: [ExternalApp] = [
        ExternalApp(
            id: "vscode",
            name: "VS Code",
            bundleIdentifiers: ["com.microsoft.VSCode"],
            commands: ["code"],
            linePosition: .gotoArgument
        ),
        ExternalApp(
            id: "vscode-insiders",
            name: "VS Code Insiders",
            bundleIdentifiers: ["com.microsoft.VSCodeInsiders"],
            commands: ["code-insiders"],
            linePosition: .gotoArgument
        ),
        ExternalApp(
            id: "cursor",
            name: "Cursor",
            bundleIdentifiers: ["com.todesktop.230313mzl4w4u92"],
            commands: ["cursor"],
            linePosition: .gotoArgument
        ),
        ExternalApp(
            id: "windsurf",
            name: "Windsurf",
            bundleIdentifiers: ["com.exafunction.windsurf"],
            commands: ["windsurf"],
            linePosition: .gotoArgument
        ),
        ExternalApp(
            id: "vscodium",
            name: "VSCodium",
            bundleIdentifiers: ["com.vscodium"],
            commands: ["codium"],
            linePosition: .gotoArgument
        ),
        ExternalApp(
            id: "zed",
            name: "Zed",
            bundleIdentifiers: ["dev.zed.Zed"],
            commands: ["zed"],
            linePosition: .pathSuffix
        ),
        ExternalApp(
            id: "sublime",
            name: "Sublime Text",
            bundleIdentifiers: ["com.sublimetext.4", "com.sublimetext.3"],
            commands: ["subl"],
            linePosition: .pathSuffix
        ),
        ExternalApp(
            id: "xcode",
            name: "Xcode",
            bundleIdentifiers: ["com.apple.dt.Xcode"],
            commands: ["xed"],
            linePosition: .lineArgument
        ),
        ExternalApp(
            id: "android-studio",
            name: "Android Studio",
            bundleIdentifiers: ["com.google.android.studio"],
            commands: ["studio"],
            linePosition: .lineArgument
        ),
        ExternalApp(
            id: "idea",
            name: "IntelliJ IDEA",
            bundleIdentifiers: ["com.jetbrains.intellij", "com.jetbrains.intellij.ce"],
            commands: ["idea"],
            linePosition: .lineArgument
        ),
        ExternalApp(
            id: "pycharm",
            name: "PyCharm",
            bundleIdentifiers: ["com.jetbrains.pycharm", "com.jetbrains.pycharm.ce"],
            commands: ["pycharm"],
            linePosition: .lineArgument
        ),
        ExternalApp(
            id: "webstorm",
            name: "WebStorm",
            bundleIdentifiers: ["com.jetbrains.WebStorm"],
            commands: ["webstorm"],
            linePosition: .lineArgument
        ),
        ExternalApp(
            id: "goland",
            name: "GoLand",
            bundleIdentifiers: ["com.jetbrains.goland"],
            commands: ["goland"],
            linePosition: .lineArgument
        ),
        ExternalApp(
            id: "clion",
            name: "CLion",
            bundleIdentifiers: ["com.jetbrains.CLion"],
            commands: ["clion"],
            linePosition: .lineArgument
        ),
        ExternalApp(
            id: "rustrover",
            name: "RustRover",
            bundleIdentifiers: ["com.jetbrains.rustrover"],
            commands: ["rustrover"],
            linePosition: .lineArgument
        ),
        ExternalApp(
            id: "rubymine",
            name: "RubyMine",
            bundleIdentifiers: ["com.jetbrains.rubymine"],
            commands: ["rubymine"],
            linePosition: .lineArgument
        ),
        ExternalApp(
            id: "phpstorm",
            name: "PhpStorm",
            bundleIdentifiers: ["com.jetbrains.PhpStorm"],
            commands: ["phpstorm"],
            linePosition: .lineArgument
        ),
        ExternalApp(
            id: "rider",
            name: "Rider",
            bundleIdentifiers: ["com.jetbrains.rider"],
            commands: ["rider"],
            linePosition: .lineArgument
        ),
        ExternalApp(
            id: "terminal",
            name: "Terminal",
            bundleIdentifiers: ["com.apple.Terminal"],
            accepts: .folder
        ),
        ExternalApp(
            id: "iterm",
            name: "iTerm2",
            bundleIdentifiers: ["com.googlecode.iterm2"],
            accepts: .folder
        ),
        ExternalApp(
            id: "ghostty",
            name: "Ghostty",
            bundleIdentifiers: ["com.mitchellh.ghostty"],
            accepts: .folder
        ),
        ExternalApp(
            id: "warp",
            name: "Warp",
            bundleIdentifiers: ["dev.warp.Warp-Stable"],
            accepts: .folder
        ),
        // Always last, always installed, and the only one that *reveals* rather than opens.
        ExternalApp(
            id: finderID,
            name: "Finder",
            bundleIdentifiers: ["com.apple.finder"]
        )
    ]

    static func app(id: String) -> ExternalApp? {
        all.first { $0.id == id }
    }

    /// Which app a stored choice names, among the ones that are actually on offer.
    ///
    /// Pure, and separate from the launcher, because the *rule* is what has to hold: a stored
    /// app that has since been uninstalled — or that cannot take this target, which is Terminal
    /// beside a file — falls back to the first on offer rather than leaving the control dead.
    /// A launcher's own answer depends on what this Mac has installed, so only this half can be
    /// asserted.
    static func resolvePreferred(storedID: String?, among apps: [ExternalApp]) -> ExternalApp? {
        if let storedID, let stored = apps.first(where: { $0.id == storedID }) { return stored }
        return apps.first
    }
}

// MARK: - Launcher

/// Finds the installed apps, remembers which one was used last, and opens things in them.
///
/// The detected list is cached because a LaunchServices lookup per app is not something a
/// header repaint should pay for; `refresh()` is called when a picker opens, which is the one
/// moment the answer can have changed since it was last needed and the one moment it is about
/// to be read.
@MainActor
final class ExternalAppLauncher {

    static let shared = ExternalAppLauncher()

    private var detected: [ExternalApp]?
    private var iconCache: [String: NSImage] = [:]

    /// Resolved absolute paths for the command-line tools, keyed by command name. A miss is
    /// recorded as well as a hit — a login shell costs ~100ms, and asking twice for a tool the
    /// user has not installed is the common case, not the rare one.
    private var resolvedCommands: [String: String?] = [:]

    private init() {}

    // MARK: Installed Apps

    /// Every registered app that is actually installed, in registry order.
    var installed: [ExternalApp] {
        if let detected { return detected }
        let found = ExternalApps.all.filter { applicationURL(for: $0) != nil }
        detected = found
        return found
    }

    /// Which of them can take this target — a menu for a *file* must not offer Terminal.
    func installed(for target: ExternalAppTarget) -> [ExternalApp] {
        installed.filter { $0.accepts(target) }
    }

    /// Drops the cached answer, so the next read asks LaunchServices again.
    func refresh() {
        detected = nil
        iconCache.removeAll()
    }

    func applicationURL(for app: ExternalApp) -> URL? {
        app.bundleIdentifiers.lazy
            .compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            .first
    }

    /// The app's own icon, at the size a menu row or a header button draws it.
    ///
    /// The system's, not a symbol of ours, for the same reason the file tree shows Finder's
    /// icons: the user recognises the app they are about to be sent to, and no glyph we could
    /// draw says "Xcode" faster than Xcode's own hammer.
    func icon(for app: ExternalApp) -> NSImage? {
        if let cached = iconCache[app.id] { return cached }
        guard let url = applicationURL(for: app) else { return nil }

        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(
            width: ExternalAppDefaults.iconPointSize,
            height: ExternalAppDefaults.iconPointSize
        )
        iconCache[app.id] = icon
        return icon
    }

    // MARK: Preference

    /// The app a plain press opens: the last one used, or the first installed one.
    ///
    /// Last-used-wins rather than a Settings row, because the choice is made in the act of
    /// opening. A stored choice that has since been uninstalled falls back rather than
    /// disabling the control.
    var preferred: ExternalApp? {
        ExternalApps.resolvePreferred(storedID: storedPreferenceID, among: installed)
    }

    /// The preferred app for a specific target, so the header's folder button and a file row's
    /// menu do not disagree about what "the last one" was when the last one cannot take files.
    func preferred(for target: ExternalAppTarget) -> ExternalApp? {
        ExternalApps.resolvePreferred(storedID: storedPreferenceID, among: installed(for: target))
    }

    private var storedPreferenceID: String? {
        PreferenceStore.shared.string(forKey: ExternalAppDefaults.preferredKey)
    }

    func setPreferred(_ app: ExternalApp) {
        PreferenceStore.shared.set(app.id, forKey: ExternalAppDefaults.preferredKey)
    }

    // MARK: Opening

    /// Opens the target, and remembers the app as the new preference.
    ///
    /// Failure beeps rather than raising a sheet: the whole action is one press, the app either
    /// came forward or it did not, and an alert about a launch the user can simply repeat is a
    /// worse interruption than the silence. The cache is dropped on the way out, so an app
    /// deleted since it was detected leaves the menu on the next open.
    func open(_ target: ExternalAppTarget, in app: ExternalApp) {
        setPreferred(app)

        guard app.accepts(target) else {
            SystemAlert.refuse()
            return
        }

        if app.id == ExternalApps.finderID {
            revealInFinder(target)
            return
        }

        guard let applicationURL = applicationURL(for: app) else {
            refresh()
            SystemAlert.refuse()
            ThreadingLogger.agent.warning(
                "Cannot open in \(app.name, privacy: .public): not installed"
            )
            return
        }

        if let line = target.line, app.linePosition != .unsupported {
            openAtLine(target.url, line: line, in: app, fallingBackTo: applicationURL)
            return
        }

        launch(target.url, with: applicationURL, named: app.name)
    }

    /// Opens in whichever app the user reached for last. The header's one-press action.
    @discardableResult
    func openInPreferredApp(_ target: ExternalAppTarget) -> Bool {
        guard let app = preferred(for: target) else {
            SystemAlert.refuse()
            return false
        }
        open(target, in: app)
        return true
    }

    private func revealInFinder(_ target: ExternalAppTarget) {
        // A folder is revealed *rooted at itself* — selecting it in its parent answers "where
        // does this live", which is not what someone opening a checkout asked. A file is
        // selected in its folder, which is exactly what they asked.
        switch target {
        case .folder(let url):
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
        case .file(let url, _):
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private func launch(_ url: URL, with applicationURL: URL, named name: String) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        NSWorkspace.shared.open(
            [url],
            withApplicationAt: applicationURL,
            configuration: configuration
        ) { _, error in
            guard let error else { return }
            Task { @MainActor in
                SystemAlert.refuse()
                ThreadingLogger.agent.error(
                    "Could not open in \(name, privacy: .public): \(error.localizedDescription, privacy: .private(mask: .hash))"
                )
            }
        }
    }

    /// The one path that needs a command line, and therefore a login shell.
    ///
    /// `open` can hand an app a file and cannot say where to put the caret, so landing on a
    /// diff's own line means running the app's CLI — which a GUI app can only find the way
    /// every other tool here is found, by asking the user's login shell. That costs a process,
    /// so it happens off the main actor and only for a target that actually carries a line.
    ///
    /// A missing CLI is not a failure: the file still opens, at whatever line the editor last
    /// left it. Which is why the fallback is the plain launch rather than a beep — being one
    /// scroll away beats being told to install a shell command.
    private func openAtLine(_ url: URL, line: Int, in app: ExternalApp, fallingBackTo applicationURL: URL) {
        let arguments = app.arguments(for: url, line: line)

        resolveCommand(for: app) { [weak self] executable in
            guard let self else { return }
            guard let executable else {
                self.launch(url, with: applicationURL, named: app.name)
                return
            }
            self.run(executable, arguments: arguments, name: app.name)
        }
    }

    private func run(_ executable: String, arguments: [String], name: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            SystemAlert.refuse()
            ThreadingLogger.agent.error(
                "Could not run \(name, privacy: .public)'s command: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
        }
    }

    /// Asks the login shell where a command lives, once per command per launch.
    private func resolveCommand(
        for app: ExternalApp,
        completion: @escaping @MainActor @Sendable (String?) -> Void
    ) {
        guard let command = app.commands.first else {
            completion(nil)
            return
        }

        if let cached = resolvedCommands[command] {
            completion(cached)
            return
        }

        // Read here and carried in: the shell path comes from the profile store, which the
        // background work must not reach into.
        let commands = app.commands
        let shell = AgentLauncher.loginShellPath

        DispatchQueue.global(qos: .userInitiated).async {
            let resolved = Self.locate(commands, shell: shell)
            Task { @MainActor in
                ExternalAppLauncher.shared.resolvedCommands[command] = resolved
                completion(resolved)
            }
        }
    }

    private nonisolated static func locate(_ commands: [String], shell: String) -> String? {
        for command in commands {
            if let path = AgentCLIProbe.locate(command, shell: shell) {
                return path
            }
        }
        return nil
    }
}

// MARK: - Command Line

extension ExternalApp {

    /// The arguments this app's CLI wants for a file and a line.
    func arguments(for url: URL, line: Int) -> [String] {
        switch linePosition {
        case .unsupported:
            return [url.path]
        case .gotoArgument:
            return ["--goto", "\(url.path):\(line)"]
        case .lineArgument:
            return ["--line", String(line), url.path]
        case .pathSuffix:
            return ["\(url.path):\(line)"]
        }
    }
}

// MARK: - Defaults

enum ExternalAppDefaults {
    /// The user's last choice. A `PreferenceStore` key rather than a `.standard` one: it records
    /// something the user *chose*, and a hosted test writing it would change which app the
    /// developer's own copy opens next.
    static let preferredKey = "externalApp.preferred"
    static let iconPointSize: CGFloat = 16
}

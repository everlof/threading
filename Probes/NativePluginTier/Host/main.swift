import ThreadingPluginKit
import AppKit

// MARK: - Theme

/// Stands in for `ThreadingDesignKit`. A real host resolves these from the selected app theme; the
/// probe hard-codes two palettes so the live-theme path can be exercised without the application.
enum ProbeTheme {
    static func tokens(dark: Bool) -> PluginTheme {
        PluginTheme(
            background: dark
                ? NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.12, alpha: 1)
                : NSColor(calibratedRed: 0.99, green: 0.99, blue: 0.98, alpha: 1),
            surface: dark
                ? NSColor(calibratedRed: 0.13, green: 0.14, blue: 0.16, alpha: 1)
                : NSColor(calibratedRed: 0.95, green: 0.95, blue: 0.94, alpha: 1),
            text: dark
                ? NSColor(calibratedWhite: 0.92, alpha: 1)
                : NSColor(calibratedWhite: 0.12, alpha: 1),
            secondaryText: dark
                ? NSColor(calibratedWhite: 0.55, alpha: 1)
                : NSColor(calibratedWhite: 0.45, alpha: 1),
            accent: dark
                ? NSColor(calibratedRed: 0.98, green: 0.63, blue: 0.38, alpha: 1)
                : NSColor(calibratedRed: 0.80, green: 0.35, blue: 0.10, alpha: 1),
            monospacedFont: .monospacedSystemFont(ofSize: 11, weight: .regular),
            rowHeight: 16,
            isDark: dark
        )
    }
}

// MARK: - Host application

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var plugin: ThreadingNativePlugin?
    private var dark = true
    private let statusItem = NSTextField(labelWithString: "")
    private var themeSignalSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = CommandLine.arguments
        let bundlePath = arguments.count > 1
            ? arguments[1]
            : FileManager.default.currentDirectoryPath + "/build/LogStreamPlugin.bundle"
        let environment = ProcessInfo.processInfo.environment

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 660),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Native Plugin Tier probe"
        window.center()

        let toggle = NSButton(title: "Toggle theme", target: self, action: #selector(toggleTheme))
        toggle.bezelStyle = .rounded
        statusItem.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

        let header = NSStackView(views: [toggle, statusItem])
        header.orientation = .horizontal
        header.spacing = 12
        header.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)

        let container = NSStackView()
        container.orientation = .vertical
        container.spacing = 0
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addArrangedSubview(header)

        // Empty means "accept any bundle", which is only right for a probe. A shipping host passes
        // a non-empty set and the loader refuses everything else.
        let loader = PluginLoader(allowedTeams: environment["THREADING_PLUGIN_TEAMS"]
            .map { Set($0.split(separator: ",").map(String.init)) } ?? [])

        var pluginArguments: [String: String] = [:]
        if arguments.count > 2 { pluginArguments["udid"] = arguments[2] }
        if arguments.count > 3 { pluginArguments["predicate"] = arguments[3] }
        if let replay = environment["PROBE_REPLAY"] { pluginArguments["replayPath"] = replay }
        if let rate = environment["PROBE_REPLAY_RATE"] { pluginArguments["replayRate"] = rate }
        if let source = environment["PROBE_SOURCE"] { pluginArguments["source"] = source }
        if let filter = environment["PROBE_FILTER"] { pluginArguments["filter"] = filter }

        do {
            let loaded = try loader.load(bundleAt: URL(fileURLWithPath: bundlePath))
            plugin = loaded
            let pane = loaded.makePaneView(
                context: PluginContext(theme: ProbeTheme.tokens(dark: dark), arguments: pluginArguments)
            )
            pane.translatesAutoresizingMaskIntoConstraints = false
            container.addArrangedSubview(pane)
            statusItem.stringValue = "loaded \(loaded.pluginIdentifier)"
                + " · API \(ThreadingPluginAPI.version)"
        } catch {
            let failure = NSTextField(labelWithString: "Plugin refused: \(error)")
            failure.textColor = .systemRed
            container.addArrangedSubview(failure)
            statusItem.stringValue = "no plugin"
            FileHandle.standardError.write("Plugin refused: \(error)\n".data(using: .utf8)!)
        }

        let content = NSView()
        content.addSubview(container)
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            container.topAnchor.constraint(equalTo: content.topAnchor),
            container.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.makeKeyAndOrderFront(nil)
        // Taking the keyboard is right for a person and wrong for a scripted run: a shell driving
        // this would otherwise type its next command into the filter field, and a space on the
        // focused source popup changes which source is streaming.
        if environment["PROBE_NO_ACTIVATE"] == nil {
            NSApp.activate(ignoringOtherApps: true)
        }
        installThemeSignal()
    }

    /// `kill -USR1 <pid>` flips the theme, so the probe can be driven from a script without
    /// synthesising a click at guessed coordinates.
    private func installThemeSignal() {
        signal(SIGUSR1, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler { [weak self] in self?.toggleTheme() }
        source.resume()
        themeSignalSource = source
    }

    @objc private func toggleTheme() {
        dark.toggle()
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        plugin?.apply(theme: ProbeTheme.tokens(dark: dark))
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()

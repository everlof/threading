import AppKit
import XCTest

@testable import Threading

/// The palette in the shipping in-window overlay and native window shell. Its three captures
/// keep the ordinary command list, the session-valued next input and the inline recorder visible
/// as complete interaction states rather than isolated row fixtures.
@MainActor
final class CommandPaletteRenderTests: XCTestCase {
    private enum Render {
        static var directory: URL {
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"],
               !override.isEmpty {
                return URL(fileURLWithPath: override)
            }
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
        }

        static let size = NSSize(width: 760, height: 520)
    }

    private enum State: String, CaseIterable {
        case commands
        case sessionTarget = "session-target"
        case recording
        /// A query answered by both a command and settings rows, which is the whole shape of the
        /// settings destinations: the command that *does* it on top, then the places it is set,
        /// each naming its page and section where a shortcut would otherwise be.
        case settings
    }

    private struct Variant {
        let name: String
        let theme: AppTheme
        let appearance: NSAppearance.Name
    }

    func testRendersCommandSessionAndShortcutStatesInTheNativeShell() throws {
        try FileManager.default.createDirectory(
            at: Render.directory,
            withIntermediateDirectories: true
        )
        defer { AppThemePalette.set(.system) }

        let variants = [
            Variant(name: "system-light", theme: .system, appearance: .aqua),
            Variant(name: "system-dark", theme: .system, appearance: .darkAqua),
            Variant(name: "cyberpunk", theme: AppThemeStyles.cyberpunk, appearance: .darkAqua),
            Variant(name: "swiss", theme: AppThemeStyles.swissMinimalist, appearance: .aqua),
        ]
        var written = 0
        for variant in variants {
            for state in State.allCases {
                AppThemePalette.set(variant.theme)
                let data = try XCTUnwrap(
                    image(appearance: variant.appearance, state: state),
                    "Could not render \(state.rawValue) under \(variant.name)"
                )
                try data.write(to: Render.directory.appendingPathComponent(
                    "command-palette-\(state.rawValue)-\(variant.name).png"
                ))
                written += 1
            }
        }

        XCTAssertEqual(written, variants.count * State.allCases.count)
        print("Rendered command-palette evidence to \(Render.directory.path)")
    }

    private func image(appearance name: NSAppearance.Name, state: State) -> Data? {
        guard let appearance = NSAppearance(named: name) else { return nil }
        var data: Data?
        appearance.performAsCurrentDrawingAppearance {
            let window = TitlebarActionWindow(
                contentRect: NSRect(origin: .zero, size: Render.size),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.appearance = appearance
            installShell(in: window)

            var shortcuts = fixtureShortcuts
            let controller = CommandPaletteViewController(
                catalog: { self.descriptors(shortcuts: shortcuts) },
                inputOptions: { _ in self.sessionOptions },
                invokeRequest: { .invoked(commandID: $0.commandID) },
                shortcutEditing: CommandPaletteShortcutEditing(
                    shortcut: { shortcuts[$0] },
                    record: { id, shortcut in
                        shortcuts[id] = shortcut
                        return nil
                    }
                )
            )
            controller.present(in: window)
            drain(until: {
                controller.visibleCommandIDsForTesting.count
                    == self.fixtureCommandIDs.count + self.settingsDestinations.count
            })

            switch state {
            case .commands:
                break
            case .sessionTarget:
                controller.confirmSelectionForTesting()
                drain(until: { controller.visibleInputIDsForTesting.count == self.sessionOptions.count })
                controller.setSearchQueryForTesting("web")
                drain(until: { controller.visibleInputIDsForTesting == ["beta"] })
            case .recording:
                controller.setSearchQueryForTesting("activity")
                drain(until: { controller.visibleCommandIDsForTesting == [AppCommands.ID.files] })
                controller.view.layoutSubtreeIfNeeded()
                drain(until: {
                    controller.shortcutRecorderForTesting(commandID: AppCommands.ID.files) != nil
                })
                guard let recorder = controller.shortcutRecorderForTesting(
                    commandID: AppCommands.ID.files
                ) else { return }
                _ = recorder.performPrimaryAction()
                drain(until: { recorder.isRecording })
            case .settings:
                controller.setSearchQueryForTesting("sound")
                drain(until: {
                    controller.visibleCommandIDsForTesting.first == AppCommands.ID.silenceSounds
                        && controller.visibleCommandIDsForTesting.count > 1
                })
                // Selected one row down, so the picture carries both halves: the command that
                // performs the thing on top, and the footer a settings row changes to "Open".
                controller.moveSelectionForTesting(by: 1)
            }

            guard let root = window.contentView else { return }
            AppThemeRefresh.repaint(root)
            root.layoutSubtreeIfNeeded()
            guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return }
            root.cacheDisplay(in: root.bounds, to: rep)
            data = rep.representation(using: .png, properties: [:])
            controller.dismiss()
        }
        return data
    }

    private func installShell(in window: NSWindow) {
        guard let bounds = window.contentView?.bounds else { return }
        let root = NSView(frame: bounds)
        root.autoresizingMask = [.width, .height]
        window.contentView = root

        let sidebar = SidebarBackdropView()
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        let workspace = ThemedSurfaceView()
        workspace.translatesAutoresizingMaskIntoConstraints = false
        workspace.applySurface(fill: Design.Surface.ground, radius: .fixed(0), pattern: .backdrop)
        root.addSubview(sidebar)
        root.addSubview(workspace)

        let brand = SidebarBrandView()
        let sidebarHeader = PaneHeaderView(leading: [brand])
        sidebar.addSubview(sidebarHeader)

        let title = NSTextField(labelWithString: "Command Palette")
        title.applyFont(.heading)
        title.textColor = Design.Text.label
        let paneHeader = PaneHeaderView(leading: [title])
        workspace.addSubview(paneHeader)

        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: SidebarDefaults.defaultWidth),
            workspace.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            workspace.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            workspace.topAnchor.constraint(equalTo: root.topAnchor),
            workspace.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebarHeader.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            sidebarHeader.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            sidebarHeader.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            paneHeader.leadingAnchor.constraint(equalTo: workspace.leadingAnchor),
            paneHeader.trailingAnchor.constraint(equalTo: workspace.trailingAnchor),
            paneHeader.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
        ])
    }

    private var sessionInput: HostCommandInputRequest {
        HostCommandInputRequest(
            kind: .session,
            prompt: "Choose a session to continue.",
            searchPlaceholder: "Choose a session"
        )
    }

    private var sessionOptions: [HostCommandInputOption] {
        [
            HostCommandInputOption(id: "alpha", title: "Architecture cleanup", detail: "AnotherTerminal · Codex"),
            HostCommandInputOption(id: "beta", title: "Website polish", detail: "threading.codes · Claude"),
            HostCommandInputOption(id: "gamma", title: "Release notes", detail: "AnotherTerminal · Codex"),
            HostCommandInputOption(id: "delta", title: "Extension API", detail: "ThreadingExtensionKit · Claude"),
        ]
    }

    private var fixtureShortcuts: [String: KeyboardShortcut] {
        [
            AppCommands.ID.commandPalette: KeyboardShortcut(key: "p", modifiers: [.shift, .command]),
            AppCommands.ID.files: KeyboardShortcut(key: "p", modifiers: .command),
            AppCommands.ID.review: KeyboardShortcut(key: "r", modifiers: [.shift, .command]),
            AppCommands.ID.find: KeyboardShortcut(key: "f", modifiers: .command),
            AppCommands.ID.toggleSidebar: KeyboardShortcut(key: "b", modifiers: [.control, .command]),
        ]
    }

    private let fixtureCommandIDs = [
        AppCommands.ID.closeSession,
        AppCommands.ID.renameSession,
        AppCommands.ID.commandPalette,
        AppCommands.ID.files,
        AppCommands.ID.review,
        AppCommands.ID.find,
        AppCommands.ID.toggleSidebar,
        AppCommands.ID.newSession,
        AppCommands.ID.silenceSounds,
    ]

    /// Stated here rather than read from `SettingsPages`, so the picture does not change every
    /// time a settings row is added somewhere else in the app.
    private let settingsDestinations = [
        SettingsDestination(
            pageID: "general",
            pageTitle: "General",
            group: "App",
            section: "Notifications",
            rowTitle: "Alert sound"
        ),
        SettingsDestination(
            pageID: "general",
            pageTitle: "General",
            group: "App",
            section: "Notifications",
            rowTitle: "Terminal bell",
            keywords: ["beep", "sound"]
        ),
        SettingsDestination(
            pageID: "profiles",
            pageTitle: "Profiles",
            group: "Appearance",
            section: "Sound",
            rowTitle: "Play a sound on output"
        ),
        SettingsDestination(
            pageID: "general",
            pageTitle: "General",
            group: "App"
        ),
    ]

    private func descriptors(shortcuts: [String: KeyboardShortcut]) -> [HostCommandDescriptor] {
        fixtureCommandIDs.compactMap(AppCommands.command).map { command in
            let needsSession = [AppCommands.ID.closeSession, AppCommands.ID.renameSession]
                .contains(command.id)
            return command.hostDescriptor(
                shortcut: shortcuts[command.id]?.displayString,
                availability: needsSession
                    ? .unavailable(reason: "Select a session first.")
                    : .available,
                nextInput: needsSession ? sessionInput : nil
            )
        } + settingsDestinations.map { $0.hostDescriptor() }
    }

    private func drain(until condition: () -> Bool, timeout: TimeInterval = 2) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), "command palette evidence state did not settle")
    }
}

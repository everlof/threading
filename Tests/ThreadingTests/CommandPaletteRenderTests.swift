import AppKit
import XCTest

@testable import Threading

/// The shipping palette and attached appearance editor, including command input, shortcut
/// recording and active/degraded pack states in the native window shell.
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
        case refreshModels = "refresh-models"
        case panelActions = "panel-actions"
        case appearance
        case appearanceAttention = "appearance-attention"
        case packEditor = "pack-editor"
    }

    private struct Variant {
        let name: String
        let theme: AppTheme
        let appearance: NSAppearance.Name
    }

    func testRendersCommandSessionAndShortcutStatesInTheNativeShell() async throws {
        try FileManager.default.createDirectory(
            at: Render.directory,
            withIntermediateDirectories: true
        )
        let priorTheme = AppThemePalette.current
        let priorMotion = Design.Motion.reduceMotionOverrideForTesting
        Design.Motion.reduceMotionOverrideForTesting = true
        defer {
            AppThemePalette.set(priorTheme)
            Design.Motion.reduceMotionOverrideForTesting = priorMotion
            CommandRegistry.shared.replaceAppearanceCommands([])
        }

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
                let rendered = await image(appearance: variant.appearance, state: state)
                let data = try XCTUnwrap(
                    rendered,
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

    private func image(appearance name: NSAppearance.Name, state: State) async -> Data? {
        guard let appearance = NSAppearance(named: name) else { return nil }
        let appearanceHost = appearanceFixture(failed: state == .appearanceAttention)
        let appearanceCommands = AppearanceCommands.catalog(host: appearanceHost).filter {
            switch $0.appearanceTarget {
            case .activate, .deactivate, .toggle, .retry, .edit: return true
            case .theme(let id): return id == AppThemeStyles.cyberpunk.id.rawValue
            default: return false
            }
        }.map { command in
            command.hostDescriptor(shortcut: nil,
                availability: command.appearanceTarget.flatMap { AppearanceCommands.unavailableReason($0, host: appearanceHost) }
                    .map { .unavailable(reason: $0) } ?? .available)
        }
        let showsAppearance = state == .appearance || state == .appearanceAttention
        var presentation: (TitlebarActionWindow, CommandPaletteViewController)?
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
                catalog: { showsAppearance ? appearanceCommands : self.descriptors(shortcuts: shortcuts) },
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
            presentation = (window, controller)
        }
        guard let (window, controller) = presentation else { return nil }
        defer { controller.dismiss() }
        await drain(until: {
            controller.visibleCommandIDsForTesting.count
                == (showsAppearance ? appearanceCommands.count : self.fixtureCommandIDs.count + self.settingsDestinations.count)
        })

        switch state {
        case .commands, .appearance:
            break
        case .appearanceAttention:
            controller.setSearchQueryForTesting("Night Shift")
            await drain(until: { controller.visibleCommandIDsForTesting.count == 5 })
        case .packEditor:
            controller.dismiss()
            window.setContentSize(NSSize(width: 900, height: 740))
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            let alert = AppearancePackEditor.present(packID: appearanceHost.state?.activePackID, in: window, host: appearanceHost)
            defer { alert?.dismiss(); window.orderOut(nil) }
            await drain(until: { alert?.presentedWindow?.isVisible == true })
            guard let panel = alert?.presentedWindow else { return nil }
            try? await Task.sleep(nanoseconds: 150_000_000)
            // Follow the actual attached panel, as the application-level evidence bridge does.
            // A parent bitmap cannot include a separate child window; screen capture also
            // requires a recording grant that app-owned view rendering does not need.
            guard let content = panel.contentView else { return nil }
            AppThemeRefresh.repaint(content)
            content.layoutSubtreeIfNeeded()
            guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return nil }
            appearance.performAsCurrentDrawingAppearance {
                content.cacheDisplay(in: content.bounds, to: rep)
            }
            let data = rep.representation(using: .png, properties: [:])
            await verifyEditorSave(alert, host: appearanceHost)
            return data
        case .sessionTarget:
            controller.confirmSelectionForTesting()
            await drain(until: { controller.visibleInputIDsForTesting.count == self.sessionOptions.count })
            controller.setSearchQueryForTesting("web")
            await drain(until: { controller.visibleInputIDsForTesting == ["beta"] })
        case .recording:
            controller.setSearchQueryForTesting("activity")
            await drain(until: { controller.visibleCommandIDsForTesting == [AppCommands.ID.files] })
            controller.view.layoutSubtreeIfNeeded()
            await drain(until: {
                controller.shortcutRecorderForTesting(commandID: AppCommands.ID.files) != nil
            })
            guard let recorder = controller.shortcutRecorderForTesting(
                commandID: AppCommands.ID.files
            ) else { return nil }
            _ = recorder.performPrimaryAction()
            await drain(until: { recorder.isRecording })
        case .settings:
            controller.setSearchQueryForTesting("sound")
            await drain(until: {
                controller.visibleCommandIDsForTesting.first == AppCommands.ID.silenceSounds
                    && controller.visibleCommandIDsForTesting.count > 1
            })
            // Selected one row down, so the picture carries both halves: the command that
            // performs the thing on top, and the footer a settings row changes to "Open".
            controller.moveSelectionForTesting(by: 1)
        case .panelActions:
            controller.setSearchQueryForTesting("browser")
            await drain(until: { controller.visibleCommandIDsForTesting.count == 3 })
        case .refreshModels:
            controller.setSearchQueryForTesting("refresh models")
            await drain(until: {
                controller.visibleCommandIDsForTesting == [AppCommands.ID.refreshModels]
            })
        }


        var data: Data?
        appearance.performAsCurrentDrawingAppearance {
            guard let root = window.contentView else { return }
            AppThemeRefresh.repaint(root)
            root.layoutSubtreeIfNeeded()
            guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return }
            root.cacheDisplay(in: root.bounds, to: rep)
            data = rep.representation(using: .png, properties: [:])
        }
        return data
    }

    private func verifyEditorSave(_ alert: ThemedAlert?, host: AppearanceActivationHost) async {
        guard let root = alert?.presentedWindow?.contentView else { XCTFail("Missing editor"); return }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let views = descendants(root)
        let toggles = views.compactMap { $0 as? ThemedToggle }
        XCTAssertEqual(toggles.count, 2)
        for toggle in toggles {
            let rect = toggle.convert(toggle.bounds, to: root)
            XCTAssertGreaterThan(rect.width, 30)
            XCTAssertTrue(root.bounds.contains(rect), "member toggle outside editor: \(rect), parent \(String(describing: toggle.superview?.frame))")
        }
        guard let name = views.first(where: { $0.accessibilityIdentifier() == "appearance-pack.name" }) as? ThemedTextField,
              let save = views.compactMap({ $0 as? ThemedButton }).first(where: { $0.title == L10n.string("Save Pack") })
        else { XCTFail("Missing editor controls"); return }
        let original = host.state?.activePack
        name.stringValue = ""
        save.performClick()
        XCTAssertNotNil(alert?.presentedWindow, "invalid input keeps the editor open")
        XCTAssertEqual(host.state?.activePack, original)
        if let member = toggles.first(where: { $0.state == .on }) {
            XCTAssertTrue(member.performPrimaryAction())
            XCTAssertEqual(member.state, .off)
            XCTAssertTrue(member.performPrimaryAction())
            XCTAssertEqual(member.state, .on)
        } else { XCTFail("The reviewed member is not selected") }
        name.stringValue = "Evening"
        save.performClick()
        await drain(until: { host.state?.activePack?.name == "Evening" })
        XCTAssertNil(alert?.presentedWindow)
        XCTAssertEqual(host.state?.activePack?.recipeRevision, original?.recipeRevision)
        XCTAssertEqual(host.state?.activePack?.extensions, original?.extensions)
    }

    private func appearanceFixture(failed: Bool) -> AppearanceActivationHost {
        let digest = String(repeating: "a", count: 64)
        let pack = AppearancePack(id: UUID(), recipeRevision: UUID(), name: "Night Shift",
            themeID: AppThemeStyles.cyberpunk.id.rawValue,
            extensions: [.init(identifier: "com.example.rain", contentDigest: digest)])
        let inventory = AppearanceActivationInventory(themeIDs: Set(AppThemeLibrary.all.map { $0.id.rawValue }), extensions: [
            "com.example.rain": .init(name: "Ambient Rain", contentDigest: digest, unavailableReason: nil,
                requiredExtensionIDs: [], status: failed ? .failed("The extension stopped") : .running,
                capabilitySummary: "Window decorations · Audio playback"),
            "com.example.tools": .init(name: "Workspace Tools", contentDigest: digest, unavailableReason: nil,
                requiredExtensionIDs: [], status: .stopped, capabilitySummary: "Commands · Panels")
        ])
        let state = AppearanceActivationState(standaloneThemeID: AppTheme.system.id.rawValue,
            manuallyEnabledExtensionIDs: [], packs: [pack], activePackID: pack.id)
        let service = AppearanceActivationService(state: state, persistence: AppearanceRenderPersistence(),
            inventory: { inventory }, reconcile: { _, _ in })
        return AppearanceActivationHost(service: service, inventory: { inventory })
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
        AppCommands.ID.refreshModels,
        AppCommands.ID.browser,
        "panel.browser",
        "panel.privateBrowser",
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

    private func drain(until condition: () -> Bool, timeout: TimeInterval = 2,
                       file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "command palette evidence state did not settle", file: file, line: line)
    }
}

private struct AppearanceRenderPersistence: AppearanceActivationPersisting {
    func save(_ state: AppearanceActivationState) async throws {}
}

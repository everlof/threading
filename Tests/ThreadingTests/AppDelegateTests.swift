import AppKit
import XCTest
@testable import Threading

/// The delegate methods the system can call in an instance that never started up.
///
/// This is not a hypothetical: a hosted test bundle *is* a running `NSApplication` with this
/// delegate installed, and `applicationDidFinishLaunching` deliberately returns early there —
/// so the window controller is nil while the app is otherwise live. Any test that waits on a
/// main-queue completion pumps the run loop, and a Dock click delivered into that window used
/// to take the whole run down on a force-unwrap.
@MainActor
final class AppDelegateTests: XCTestCase {

    func testUIScenarioEvidenceConfigurationStaysInsideScenarioHome() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UIScenarioEvidence-\(UUID().uuidString)", isDirectory: true)
        let evidence = root.appendingPathComponent("evidence", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let token = UUID().uuidString
        let accepted = UIScenarioEvidenceCapture.Configuration.resolve(
            environment: [
                "THREADING_UI_SCENARIO_EVIDENCE_DIR": evidence.path,
                "THREADING_UI_SCENARIO_EVIDENCE_TOKEN": token,
            ],
            scenarioRoot: root
        )
        XCTAssertEqual(try accepted.get().outputDirectory, evidence.resolvingSymlinksInPath())

        let refused = UIScenarioEvidenceCapture.Configuration.resolve(
            environment: [
                "THREADING_UI_SCENARIO_EVIDENCE_DIR": outside.path,
                "THREADING_UI_SCENARIO_EVIDENCE_TOKEN": token,
            ],
            scenarioRoot: root
        )
        guard case .failure(let error) = refused else {
            return XCTFail("an evidence directory beside the allowed directory was accepted")
        }
        XCTAssertEqual(error, .unsafeOutputDirectory)
    }

    func testUIScenarioEvidenceNamesCannotBecomePaths() {
        XCTAssertTrue(UIScenarioEvidenceCapture.isSafeEvidenceName("stop-turn-01-working"))
        XCTAssertFalse(UIScenarioEvidenceCapture.isSafeEvidenceName("../outside"))
        XCTAssertFalse(UIScenarioEvidenceCapture.isSafeEvidenceName("Uppercase"))
        XCTAssertFalse(UIScenarioEvidenceCapture.isSafeEvidenceName("1-leading-number"))
    }

    func testSwedishStringCatalogCompilesAndKeepsPerStringFallback() throws {
        let appBundle = Bundle(for: AppDelegate.self)
        let path = try XCTUnwrap(
            appBundle.path(forResource: "sv", ofType: "lproj"),
            "the Swedish string catalogue was not copied into the app"
        )
        let swedish = try XCTUnwrap(Bundle(path: path))

        XCTAssertEqual(L10n.string("Themes", bundle: swedish), "Teman")
        XCTAssertEqual(
            L10n.string("A future untranslated string", bundle: swedish),
            "A future untranslated string"
        )
    }

    func testClosingTheLastTestWindowDoesNotTerminateTheHostedRunner() {
        XCTAssertFalse(
            AppDelegate().applicationShouldTerminateAfterLastWindowClosed(NSApp)
        )
    }

    func testFastPlanExcludesTestsThatRequireAVisibleWindow() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let planURL = repositoryRoot.appendingPathComponent("TestPlans/Threading-Fast.xctestplan")
        let plan = try String(contentsOf: planURL, encoding: .utf8)

        for testCase in ["BrowserCaptureGeometryTests", "BrowserOffScreenCaptureTests"] {
            XCTAssertTrue(
                plan.contains("\"\(testCase)\""),
                "\(testCase) orders a real window on screen and must stay outside the hosted "
                    + "fast runner"
            )
        }
    }

    func testReopenWithoutAWindowControllerDoesNotCrash() {
        let delegate = AppDelegate()

        // Both arms: `false` is the one that used to reach for the window.
        XCTAssertTrue(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
        XCTAssertTrue(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true))
    }

    /// Every window-scoped menu action, performed on a delegate that has no window.
    ///
    /// This is the same shape as the reopen crash above, spread across twenty call sites: two
    /// processes run a real `NSApplication` with this delegate and never build a window — a
    /// hosted test bundle, and a second instance that lost the single-instance lock — and a
    /// command arriving in either has nothing to act on. Doing nothing is the answer; trapping
    /// is not. Performed by selector because the actions are private, which is also how the
    /// menu itself reaches them.
    func testWindowActionsDoNothingRatherThanTrapWithoutAWindow() {
        let delegate = AppDelegate()

        let actions = [
            "showPreferences", "openTerminalTab", "openFilesTab", "openBrowser", "openReview",
            "openInfo", "toggleShell", "toggleDisplayPanel", "toggleCurrentTheme", "newSession", "addProject",
            "newProject", "closeSession", "toggleSidebar", "showFind", "inspectElement",
            "increaseFontSize", "decreaseFontSize", "showCommandPalette"
        ]

        for name in actions {
            let selector = Selector(name)
            XCTAssertTrue(
                delegate.responds(to: selector),
                "\(name) is no longer an action the menu can reach"
            )
            delegate.perform(selector)
        }
    }

    /// Adopting a folder writes the user's real store, which is the exact clobber the
    /// single-instance lock exists to prevent — so an instance that never launched, and so never
    /// took the lock, must not adopt one either.
    ///
    /// The folder is a real directory, so the `isDirectory` check inside the loop passes and the
    /// only thing standing between this call and `addProject` is the lock guard. Asserting the
    /// store is unchanged is the point: the call merely *not trapping* was all this pinned
    /// before, which the guard being deleted outright would still have satisfied.
    func testOpeningFoldersIsIgnoredWithoutTheStateLock() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AppDelegateTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let adopted = ProjectStore.shared.projects.count

        let delegate = AppDelegate()
        delegate.application(NSApp, open: [folder])

        XCTAssertEqual(
            ProjectStore.shared.projects.count, adopted,
            "a delegate without the state lock adopted a folder into the user's real store"
        )
        XCTAssertFalse(
            ProjectStore.shared.projects.contains { $0.folderURL.path == folder.path },
            "the dropped folder was adopted despite the lock guard"
        )
    }

    /// The sidebar-arrangement toggles live in the View menu with registry-backed shortcuts,
    /// and their checkmarks are stamped by `validateMenuItem` — asserted here because nothing
    /// else in the menu bar carries state, so nothing else would catch the stamping breaking.
    func testViewMenuCarriesTheArrangementTogglesWithTheirChecks() throws {
        let previousMainMenu = NSApp.mainMenu
        let previousWindowsMenu = NSApp.windowsMenu
        let previousHelpMenu = NSApp.helpMenu
        defer {
            NSApp.mainMenu = previousMainMenu
            NSApp.windowsMenu = previousWindowsMenu
            NSApp.helpMenu = previousHelpMenu
        }

        let delegate = AppDelegate()
        delegate.setupMenuBar()

        let viewMenu = try XCTUnwrap(
            NSApp.mainMenu?.items.compactMap(\.submenu).first {
                $0.title == MenuIdentifiers.viewMenu
            }
        )

        let grouping = try XCTUnwrap(viewMenu.item(withTitle: "Group Sessions by Branch"))
        XCTAssertEqual(grouping.keyEquivalent, "b")
        XCTAssertEqual(grouping.keyEquivalentModifierMask, [.command, .control])

        let lone = try XCTUnwrap(viewMenu.item(withTitle: "Headings for Lone Branches"))
        XCTAssertEqual(lone.keyEquivalent, "b")
        XCTAssertEqual(lone.keyEquivalentModifierMask, [.command, .option])

        // Validation stamps the check from the seeded defaults, which are both on.
        XCTAssertTrue(delegate.validateMenuItem(grouping))
        XCTAssertEqual(grouping.state, .on)
        XCTAssertTrue(delegate.validateMenuItem(lone))
        XCTAssertEqual(lone.state, .on)

        // With grouping off the refinement validates false — disabled, not hidden.
        UserDefaults.standard.set(false, forKey: "groupsSessionsByBranch")
        defer { UserDefaults.standard.removeObject(forKey: "groupsSessionsByBranch") }
        XCTAssertFalse(delegate.validateMenuItem(lone))
    }

    /// The global silence gate's third surface. It sits in the application menu rather than
    /// under View because it is the app's own voice rather than a view of anything — and
    /// because that menu is present with no window open, which is the state the app is most
    /// likely to be making noise nobody can trace.
    func testTheApplicationMenuCarriesTheSilenceGateWithItsCheck() throws {
        let previousMainMenu = NSApp.mainMenu
        let previousWindowsMenu = NSApp.windowsMenu
        let previousHelpMenu = NSApp.helpMenu
        let previousGate = UserDefaults.standard.object(forKey: "silencesAllSounds")
        defer {
            NSApp.mainMenu = previousMainMenu
            NSApp.windowsMenu = previousWindowsMenu
            NSApp.helpMenu = previousHelpMenu
            if let previousGate {
                UserDefaults.standard.set(previousGate, forKey: "silencesAllSounds")
            } else {
                UserDefaults.standard.removeObject(forKey: "silencesAllSounds")
            }
        }

        AppSettings.shared.silencesAllSounds = false

        let delegate = AppDelegate()
        delegate.setupMenuBar()

        // The application menu is the first, and AppKit names it from the process rather than
        // from a title of ours — so it is found by position, the way the platform builds it.
        let appMenu = try XCTUnwrap(NSApp.mainMenu?.items.first?.submenu)
        let item = try XCTUnwrap(
            appMenu.item(withTitle: L10n.string("Silence Sounds")),
            "the application menu carries no silence gate"
        )

        XCTAssertEqual(item.keyEquivalent, "s")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .shift])

        XCTAssertTrue(delegate.validateMenuItem(item))
        XCTAssertEqual(item.state, .off)

        AppSettings.shared.silencesAllSounds = true
        XCTAssertTrue(delegate.validateMenuItem(item), "the gate needs no window to be usable")
        XCTAssertEqual(item.state, .on)
    }

    func testCurrentThemeLivesInViewAndFollowsTheThemeToolCapability() throws {
        let previousMainMenu = NSApp.mainMenu
        let previousWindowsMenu = NSApp.windowsMenu
        let previousHelpMenu = NSApp.helpMenu
        let settings = AppSettings.shared
        let previousDisabled = settings.disabledToolGroupIDs
        defer {
            settings.disabledToolGroupIDs = previousDisabled
            NSApp.mainMenu = previousMainMenu
            NSApp.windowsMenu = previousWindowsMenu
            NSApp.helpMenu = previousHelpMenu
        }
        settings.setToolGroup(MCPToolCatalog.appearance.id, enabled: true)

        let delegate = AppDelegate()
        delegate.setupMenuBar()
        let menus = try XCTUnwrap(NSApp.mainMenu).items.compactMap(\.submenu)
        let view = try XCTUnwrap(menus.first { $0.title == MenuIdentifiers.viewMenu })
        let window = try XCTUnwrap(menus.first { $0.title == MenuIdentifiers.windowMenu })
        let current = try XCTUnwrap(view.item(withTitle: L10n.string("Current Theme")))

        XCTAssertFalse(current.isHidden)
        XCTAssertNil(
            window.item(withTitle: L10n.string("Current Theme")),
            "a workspace panel was put in the Window menu"
        )

        settings.setToolGroup(MCPToolCatalog.appearance.id, enabled: false)
        XCTAssertTrue(current.isHidden, "the menu promised an agent workflow with no theme tools")
    }

    func testExtensionCommandsRenderAtDeclaredHostMenuAnchors() throws {
        let previousMainMenu = NSApp.mainMenu
        let previousWindowsMenu = NSApp.windowsMenu
        let previousHelpMenu = NSApp.helpMenu
        CommandRegistry.shared.removeAllExtensionCommands()
        defer {
            CommandRegistry.shared.removeAllExtensionCommands()
            NSApp.mainMenu = previousMainMenu
            NSApp.windowsMenu = previousWindowsMenu
            NSApp.helpMenu = previousHelpMenu
        }

        CommandRegistry.shared.replaceExtensionCommands(
            extensionIdentifier: "com.example.ci",
            extensionName: "CI",
            commands: [
                .init(
                    id: "open-build",
                    title: "Open Build",
                    scope: .project,
                    menuPlacements: [.project, .view]
                )
            ]
        )

        let delegate = AppDelegate()
        delegate.setupMenuBar()

        let projectMenu = try XCTUnwrap(
            NSApp.mainMenu?.items.compactMap(\.submenu).first {
                $0.title == MenuIdentifiers.projectMenu
            }
        )
        let viewMenu = try XCTUnwrap(
            NSApp.mainMenu?.items.compactMap(\.submenu).first {
                $0.title == MenuIdentifiers.viewMenu
            }
        )
        let extensionsMenu = try XCTUnwrap(
            NSApp.mainMenu?.items.compactMap(\.submenu).first {
                $0.title == "Extensions"
            }
        )

        let projectGroup = try XCTUnwrap(projectMenu.item(withTitle: "Extensions"))
        let viewGroup = try XCTUnwrap(viewMenu.item(withTitle: "Extensions"))
        XCTAssertFalse(projectGroup.isHidden)
        XCTAssertFalse(viewGroup.isHidden)
        XCTAssertEqual(
            projectGroup.submenu?.item(withTitle: "CI")?
                .submenu?.item(withTitle: "Open Build")?.representedObject as? String,
            "extension.com.example.ci.open-build"
        )
        XCTAssertEqual(
            viewGroup.submenu?.item(withTitle: "CI")?
                .submenu?.item(withTitle: "Open Build")?.representedObject as? String,
            "extension.com.example.ci.open-build"
        )
        XCTAssertEqual(
            extensionsMenu.items.filter { !$0.isHidden }.map(\.title),
            ["No Extension Commands Here"]
        )
    }

    func testProjectScriptsUseTheRegistryBackedProjectMenuAndPaletteShortcut() throws {
        let previousMainMenu = NSApp.mainMenu
        let previousWindowsMenu = NSApp.windowsMenu
        let previousHelpMenu = NSApp.helpMenu
        let root = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("AppDelegateProjectScripts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            ProjectScriptService.shared.activate(executionDirectory: nil)
            CommandRegistry.shared.replaceProjectScripts([])
            try? FileManager.default.removeItem(at: root)
            NSApp.mainMenu = previousMainMenu
            NSApp.windowsMenu = previousWindowsMenu
            NSApp.helpMenu = previousHelpMenu
        }

        let configuration = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "scripts": [[
                "id": "check", "name": "Check project", "command": "make check"
            ]]
        ])
        try configuration.write(to: root.appendingPathComponent(".threading.json"))
        ProjectScriptService.shared.activate(executionDirectory: root)

        let delegate = AppDelegate()
        delegate.setupMenuBar()
        let project = try XCTUnwrap(
            NSApp.mainMenu?.items.compactMap(\.submenu).first {
                $0.title == MenuIdentifiers.projectMenu
            }
        )
        let scripts = try XCTUnwrap(project.item(withTitle: L10n.string("Scripts")))
        XCTAssertFalse(scripts.isHidden)
        XCTAssertEqual(
            scripts.submenu?.item(withTitle: "Check project")?.representedObject as? String,
            "project.script.check"
        )

        // The palette searches every app and extension command, not just this project's, so it
        // sits in View under the chord that means "command palette" nearly everywhere.
        let view = try XCTUnwrap(
            NSApp.mainMenu?.items.compactMap(\.submenu).first {
                $0.title == MenuIdentifiers.viewMenu
            }
        )
        let palette = try XCTUnwrap(view.item(withTitle: L10n.string("Command Palette…")))
        XCTAssertEqual(palette.keyEquivalent, "p")
        XCTAssertEqual(palette.keyEquivalentModifierMask, [.command, .shift])
    }
}

import AppKit
import os
import XCTest
@testable import Threading

@MainActor
final class AgentCLISettingsTests: HostedStoreTestCase {
    func testDocumentedMinimumsRespectBoundariesAndDoNotTreatAliasesAsRequirements() {
        XCTAssertEqual(AgentCLIModelRequirement.unmet(by: "2.1.256").map(\.model),
                       ["Fable 5.1", "Opus 5.5", "Sonnet 5.5"])
        XCTAssertEqual(AgentCLIModelRequirement.unmet(by: "2.1.280-beta.1").map(\.model),
                       ["Opus 5.5", "Sonnet 5.5"])
        XCTAssertEqual(AgentCLIModelRequirement.unmet(by: "2.1.280").map(\.model), ["Sonnet 5.5"])
        XCTAssertTrue(AgentCLIModelRequirement.unmet(by: "2.1.284").isEmpty)
        XCTAssertTrue(AgentCLIModelRequirement.unmet(by: "unknown").isEmpty)
        XCTAssertFalse(AgentCLIModelRequirement.claude.contains { $0.model == "Opus 4.7" },
                       "A release announcement is not evidence of a hard minimum")
        XCTAssertEqual(AgentCLIModelRequirement.enabledBy(update(to: "2.1.280")).map(\.model),
                       ["Fable 5.1", "Opus 5.5"])
    }

    func testModelUpdateReceiptExplainsWhatTheUpdateEnables() {
        let request = AgentCLIUpdateToast.request(for: [update()]) { _ in }
        XCTAssertEqual(request.detail, L10n.format(
            "This Claude Code update supports %@. Restart running agents after updating.",
            "Fable 5.1, Opus 5.5, Sonnet 5.5"
        ))
    }

    func testManualCheckIsIdleUntilPressedAndFailuresAreDistinctFromMissingTools() async throws {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let checked = expectation(description: "explicit check")
        let report = mixedReport()
        let controller = AgentCLISettingsViewController(check: {
            calls.withLock { $0 += 1 }
            checked.fulfill()
            return report
        })
        _ = controller.view
        XCTAssertEqual(calls.withLock { $0 }, 0)
        let button = try XCTUnwrap(control("check", in: controller.view))
        XCTAssertTrue(button.performPrimaryAction())
        XCTAssertFalse(try XCTUnwrap(control("check", in: controller.view)).isEnabled)
        await fulfillment(of: [checked], timeout: 2)
        XCTAssertEqual(calls.withLock { $0 }, 1)

        let labels = descendants(controller.view, NSTextField.self).map(\.stringValue)
        XCTAssertTrue(labels.contains("Installed 2.1.220 · Latest 2.1.284"))
        XCTAssertTrue(labels.contains("Installed 0.148.0 · Couldn’t check for updates"))
        XCTAssertTrue(labels.contains("Installed 1.2.0 · Up to date"))
        XCTAssertEqual(labels.filter { $0 == "Not found on your login shell’s PATH" }.count, 2)
        XCTAssertNil(control("codex.update", in: controller.view))
        XCTAssertNotNil(control("claude.update", in: controller.view))
    }

    func testInstallationGuideAndUpdateActionsUseTheSelectedToolAndReportLaunchFailure() async throws {
        var opened: URL?
        let ran = expectation(description: "visible updater requested")
        let expected = update()
        let report = mixedReport()
        let controller = AgentCLISettingsViewController(check: { report }, prepare: { updates, _ in
            XCTAssertEqual(updates, [expected])
            return AgentCLIUpdateExecutionPlan(items: [.failed(update: expected, reason: .executableNotFound)])
        }, openURL: { opened = $0 })
        var runs = 0
        controller.runUpdates = { plan in
            XCTAssertEqual(plan.updates, [expected])
            runs += 1
            ran.fulfill()
            return false
        }
        controller.show(mixedReport())
        _ = controller.view
        XCTAssertEqual(runs, 0)
        XCTAssertNil(opened)
        XCTAssertTrue(try XCTUnwrap(control("cursor.guide", in: controller.view)).performPrimaryAction())
        XCTAssertEqual(opened, AgentKind.cursor.cliInstallationGuide)
        XCTAssertTrue(try XCTUnwrap(control("claude.update", in: controller.view)).performPrimaryAction())
        await fulfillment(of: [ran], timeout: 2)
        XCTAssertEqual(runs, 1)
        XCTAssertTrue(descendants(controller.view, NSTextField.self).contains {
            $0.stringValue == "Threading couldn’t open the update terminal. Use the Installation Guide to update."
        })
    }

    func testEveryClientHasAPinnedPublisherArtifactAndInstallationGuide() {
        for kind in AgentKind.allCases {
            let release = ManagedAgentCatalog.release(for: kind)
            XCTAssertEqual(release.kind, kind)
            XCTAssertEqual(release.archiveURL.scheme, "https")
            XCTAssertFalse(release.integrity.isEmpty)
        }
        XCTAssertEqual(Set(AgentKind.allCases.map(\.cliInstallationGuide)).count, AgentKind.allCases.count)
        XCTAssertTrue(AgentKind.allCases.allSatisfy { $0.cliInstallationGuide.scheme == "https" })
    }

    func testRendersAgentToolsInTheProductSettingsShell() throws {
        let runtimeRoot = FileManager.default.temporaryDirectory.appendingPathComponent("managed-render-\(UUID())")
        let suite = "ManagedAgentRender.\(UUID())"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        let runtimes = ManagedAgentRuntimeStore(root: runtimeRoot, preferences: preferences)
        let olderVersions: [AgentKind: String] = [.claude: "2.1.220"]
        for kind in [AgentKind.claude, .codex, .cursor] {
            let release = ManagedAgentCatalog.release(for: kind)
            try runtimes.activate(ManagedAgentInstallation(version: olderVersions[kind] ?? release.version,
                directory: UUID().uuidString, executable: release.executable, archiveIntegrity: release.integrity), for: kind)
        }
        runtimes.selectExternal("/Users/example/tools/opencode", for: .openCode)
        let previousStore = AgentLocalLaunch.store
        AgentLocalLaunch.configure(runtimes)
        defer {
            AgentLocalLaunch.configure(previousStore)
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: runtimeRoot)
        }
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"]
                            ?? NSTemporaryDirectory(), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previous = AppThemePalette.current
        let previousMotion = Design.Motion.reduceMotionOverrideForTesting
        Design.Motion.reduceMotionOverrideForTesting = true
        defer {
            AppThemePalette.set(previous)
            Design.Motion.reduceMotionOverrideForTesting = previousMotion
        }
        let fixtures: [(String, AppTheme, NSAppearance.Name)] = [
            ("system", .system, .aqua),
            ("cyberpunk", AppThemeStyles.cyberpunk, .darkAqua),
            ("neo-brutalism", AppThemeStyles.neoBrutalism, .aqua)
        ]
        for (name, theme, appearance) in fixtures {
            AppThemePalette.set(theme)
            let shell = makeMainWindowController()
            let window = try XCTUnwrap(shell.window)
            window.setContentSize(NSSize(width: 1320, height: 1000))
            shell.showSettingsPage(id: SettingsPages.generalID)
            let root = try XCTUnwrap(window.contentViewController)
            let general = try XCTUnwrap(controllers(root).compactMap {
                $0 as? GeneralPreferencesViewController
            }.first)
            XCTAssertNotNil(general.agentTools.runUpdates, "Shipping settings lost the visible-terminal route")
            general.agentTools.show(mixedReport())
            shell.presentAgentCLIUpdates([update(to: ManagedAgentCatalog.release(for: .claude).version)], didStart: {})
            let content = try XCTUnwrap(window.contentView)
            content.appearance = NSAppearance(named: appearance)
            AppThemeRefresh.repaint(content)
            content.layoutSubtreeIfNeeded()
            SettingsRowReveal.reveal(title: L10n.string("Model support"), in: general.view)
            content.layoutSubtreeIfNeeded()
            let controls = descendants(general.agentTools.view, ThemedButton.self)
            XCTAssertEqual(controls.filter { $0.accessibilityIdentifier().hasSuffix(".options") }.count, 5)
            for button in controls {
                let frame = button.convert(button.bounds, to: general.agentTools.view)
                XCTAssertGreaterThan(frame.minX, -1)
                XCTAssertLessThanOrEqual(frame.maxX, general.agentTools.view.bounds.maxX + 1)
            }
            let rep = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: rep)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("agent-tools-\(name).png"))
        }
    }

    func testRendersManagedInstallSheetInProductHost() throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"]
                            ?? NSTemporaryDirectory(), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previousTheme = AppThemePalette.current
        defer { AppThemePalette.set(previousTheme) }
        let runtimes = ManagedAgentRuntimeStore(
            root: URL(fileURLWithPath: "/Users/example/Library/Application Support/Threading/AgentTools"),
            preferences: PreferenceStore.shared
        )
        let fixtures: [(String, AppTheme, NSAppearance.Name, AgentCLIInstallViewController.Phase)] = [
            ("ready", .system, .aqua, .ready),
            ("running", AppThemeStyles.cyberpunk, .darkAqua, .running),
            ("failed", .system, .darkAqua, .failed(message: "The download did not match the approved checksum.")),
            ("installed", AppThemeStyles.neoBrutalism, .aqua, .installed(path: "/verified/claude"))
        ]
        for (name, theme, appearance, phase) in fixtures {
            AppThemePalette.set(theme)
            let shell = makeMainWindowController()
            let parent = try XCTUnwrap(shell.window)
            let presenter = try XCTUnwrap(parent.contentViewController)
            let sheet = AgentCLIInstallViewController(kind: .claude, runtimes: runtimes,
                                                     install: { _ in XCTFail("render must not install"); return "" })
            presenter.presentAsSheet(sheet)
            defer { presenter.dismiss(sheet) }
            sheet.setPhaseForTesting(phase)
            let panel = try XCTUnwrap(sheet.view.window)
            XCTAssertEqual(panel.sheetParent, parent)
            panel.appearance = NSAppearance(named: appearance)
            let content = try XCTUnwrap(panel.contentView)
            AppThemeRefresh.repaint(content)
            content.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(sheet.view.bounds.height, 150)
            XCTAssertEqual(ThemeBoundaryAudit.violations(in: sheet.view), [])
            let rep = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(
                to: directory.appendingPathComponent("agent-tools-install-\(name).png"))
        }
    }

    private func update(to target: String = "2.1.284") -> AgentCLIUpdate {
        let definition = AgentKind.claude.cliUpdateDefinition
        return AgentCLIUpdate(id: definition.id, displayName: definition.displayName,
                              executable: definition.executable, versionArguments: definition.versionArguments,
                              comparison: definition.comparison, installedVersion: "2.1.220",
                              latestVersion: target, updateArguments: definition.updateArguments)
    }

    private func mixedReport() -> AgentCLIUpdateReport {
        AgentCLIUpdateReport(installed: [
            .init(id: "claude", displayName: "Claude Code", version: "2.1.220", executablePath: "/fixture/bin/claude"),
            .init(id: "codex", displayName: "Codex", version: "0.148.0"),
            .init(id: AgentKind.openCode.rawValue, displayName: "OpenCode", version: "1.2.0")
        ], updates: [update()], failures: [
            .init(toolID: "codex", stage: .releaseSource, reason: .transport)
        ], checkedSourceCount: 2, missingCount: 2)
    }

    private func control(_ suffix: String, in view: NSView) -> ThemedButton? {
        descendants(view, ThemedButton.self).first {
            $0.accessibilityIdentifier() == "settings.general.agent-tools.\(suffix)"
        }
    }

    private func descendants<T: NSView>(_ view: NSView, _ type: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants($0, type) }
    }

    private func controllers(_ root: NSViewController) -> [NSViewController] {
        [root] + root.children.flatMap(controllers)
    }
}

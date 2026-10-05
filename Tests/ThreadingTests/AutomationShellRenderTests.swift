import AppKit
import XCTest
@testable import Threading

@MainActor
final class AutomationShellRenderTests: HostedStoreTestCase {
    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }
    func testRendersAutomationsInShippingWindow() async throws {
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"] ?? "/tmp/ThreadingRenders")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let oldTheme = AppThemePalette.current
        defer { AppThemePalette.set(oldTheme) }
        let shell = makeMainWindowController(initialFramePlan: .useDefaultFrame)
        let window = try XCTUnwrap(shell.window)
        window.setContentSize(NSSize(width: 1400, height: 900))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("automation-shell-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = TriggerStore(url: directory.appendingPathComponent("triggers.db"))
        addTeardownBlock { await store.close(); try? FileManager.default.removeItem(at: directory) }
        var configuration = AutomationConfiguration(projectID: ProjectID())
        configuration.name = "Morning project report"
        configuration.instructions = "Summarize changes from yesterday and report failures."
        configuration.options.schedule = .init(kind: .daily, timeZone: "Europe/Stockholm")
        let id = TriggerID()
        let fixtureDate = Date(timeIntervalSince1970: 1_790_755_200)
        let revision = try await store.configureAutomation(configuration, id: id, expectedRevision: nil, proposedBy: nil, now: fixtureDate)
        try await store.activate(triggerID: id, revisionID: revision.id, at: fixtureDate)
        shell.containerViewController.showTriggers(store: store)
        let center = try XCTUnwrap(shell.containerViewController.children.compactMap { $0 as? TriggerCenterViewController }.first)
        let themes: [(String, AppTheme)] = [("system", .system), ("pure", AppThemeStyles.pure), ("neo", AppThemeStyles.neoBrutalism)]
        for (themeName, theme) in themes {
            AppThemePalette.set(theme)
            for page in [0, 3] {
                try await center.prepareEvidencePage(index: page)
                let content = try XCTUnwrap(window.contentView)
                if page == 3, RemoteHostStore.shared.ordered.isEmpty {
                    let connect = try XCTUnwrap(descendants(content).compactMap { $0 as? ThemedButton }
                        .first { $0.accessibilityIdentifier() == "automation.remote.connect" })
                    XCTAssertFalse(connect.isEnabled, "The empty remote-host page must not offer an invalid connection")
                }
                content.appearance = NSAppearance(named: .aqua)
                AppThemeRefresh.repaint(content); content.layoutSubtreeIfNeeded(); content.displayIfNeeded()
                let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
                content.cacheDisplay(in: content.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("trigger-center-shell-\(themeName)-\(page).png"))
            }
        }
        guard ProcessInfo.processInfo.environment["THREADING_AUTOMATION_STRESS"] == "1" else { return }
        let preparationStart = ProcessInfo.processInfo.systemUptime
        for index in 1..<500 {
            configuration.name = "Recurring task \(index)"
            _ = try await store.configureAutomation(configuration, id: TriggerID(), expectedRevision: nil, proposedBy: nil)
        }
        let preparation = ProcessInfo.processInfo.systemUptime - preparationStart
        let mountStart = ProcessInfo.processInfo.systemUptime
        try await center.prepareEvidencePage(index: 0)
        window.contentView?.layoutSubtreeIfNeeded()
        let mount = ProcessInfo.processInfo.systemUptime - mountStart
        XCTAssertLessThanOrEqual(center.drawnRowCount, 29, "One project's catalogue must retain at most 25 data rows plus its section and pagination chrome")
        print("AUTOMATION_STRESS definitions=500 prepare_s=\(preparation) projection_and_layout_s=\(mount) rows=\(center.drawnRowCount)")
    }
}

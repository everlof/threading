import AppKit
import XCTest
@testable import Threading

@MainActor
final class ProjectAutoHideSettingsTests: HostedStoreTestCase {
    func testSettingsControlsCommitAndRejectInvalidDaysInTheShippingShell() throws {
        let settings = AppSettings.shared
        let wasEnabled = settings.autoHidesInactiveProjects
        let days = settings.projectAutoHideDays
        defer {
            settings.autoHidesInactiveProjects = wasEnabled
            settings.projectAutoHideDays = days
        }
        settings.autoHidesInactiveProjects = false
        let shell = makeMainWindowController()
        shell.showSettingsPage(id: SettingsPages.sidebarID)
        let root = try XCTUnwrap(shell.window?.contentView)
        let toggle = try XCTUnwrap(descendants(root).compactMap { $0 as? ThemedToggle }.first {
            $0.accessibilityIdentifier() == "settings.sidebar.auto-hide-projects"
        })
        let field = try XCTUnwrap(descendants(root).compactMap { $0 as? ThemedTextField }.first {
            $0.accessibilityIdentifier() == "settings.sidebar.auto-hide-days"
        })
        XCTAssertTrue(field.isEnabled)
        field.stringValue = "17"
        toggle.state = .on
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(toggle.action), to: toggle.target, from: toggle))
        XCTAssertTrue(settings.autoHidesInactiveProjects)
        XCTAssertEqual(settings.projectAutoHideDays, 17)
        XCTAssertTrue(field.isEnabled)
        field.stringValue = "0"
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(field.action), to: field.target, from: field))
        XCTAssertEqual(settings.projectAutoHideDays, 17)
        XCTAssertEqual(field.stringValue, "17")
        field.stringValue = "42"
        (field.delegate as? SidebarPreferencesViewController)?.controlTextDidEndEditing(
            Notification(name: NSControl.textDidEndEditingNotification, object: field)
        )
        XCTAssertEqual(settings.projectAutoHideDays, 42)
        settings.autoHidesInactiveProjects = false
        XCTAssertEqual(toggle.state, .off)
        XCTAssertTrue(field.isEnabled)
        field.stringValue = "90"
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(field.action), to: field.target, from: field))
        XCTAssertEqual(settings.projectAutoHideDays, 90)
        XCTAssertFalse(settings.autoHidesInactiveProjects)
    }

    func testRendersAutoHideSettingsInTheShippingShell() throws {
        let settings = AppSettings.shared
        let wasEnabled = settings.autoHidesInactiveProjects
        let days = settings.projectAutoHideDays
        let previousTheme = AppThemePalette.current
        let previousMotion = Design.Motion.reduceMotionOverrideForTesting
        Design.Motion.reduceMotionOverrideForTesting = true
        defer {
            settings.autoHidesInactiveProjects = wasEnabled
            settings.projectAutoHideDays = days
            AppThemePalette.set(previousTheme)
            Design.Motion.reduceMotionOverrideForTesting = previousMotion
        }
        settings.projectAutoHideDays = 30
        let output = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"] ?? NSTemporaryDirectory()
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        let fixtures: [(String, AppTheme, NSAppearance.Name)] = [
            ("system-light", .system, .aqua),
            ("system-dark", .system, .darkAqua),
            ("swiss", AppThemeStyles.swissMinimalist, .aqua),
            ("cyberpunk", AppThemeStyles.cyberpunk, .darkAqua)
        ]
        let shell = makeMainWindowController()
        let window = try XCTUnwrap(shell.window)
        window.setContentSize(NSSize(width: 1120, height: 900))
        shell.showSettingsPage(id: SettingsPages.sidebarID)
        let content = try XCTUnwrap(window.contentView)
        for (name, theme, appearance) in fixtures {
            AppThemePalette.set(theme)
            content.appearance = NSAppearance(named: appearance)
            for enabled in [false, true] {
                settings.autoHidesInactiveProjects = enabled
                AppThemeRefresh.repaint(content)
                content.layoutSubtreeIfNeeded()
                let field = try XCTUnwrap(descendants(content).compactMap { $0 as? ThemedTextField }.first {
                    $0.accessibilityIdentifier() == "settings.sidebar.auto-hide-days"
                })
                XCTAssertTrue(field.isEnabled)
                let fieldBounds = field.convert(field.bounds, to: content)
                XCTAssertTrue(content.bounds.contains(fieldBounds), "Day count was clipped in \(name)")
                XCTAssertEqual(ThemeBoundaryAudit.violations(in: content), [])
                let rep = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
                content.cacheDisplay(in: content.bounds, to: rep)
                let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: output)
                    .appendingPathComponent("sidebar-auto-hide-\(name)-\(enabled ? "on" : "off").png"))
            }
        }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}

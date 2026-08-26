import AppKit
import XCTest
@testable import Threading

/// Captures the Settings canvas inside the real application window.
///
/// Individual page renders protect their contents, but they cannot show the horizontal jump that
/// happens when navigation swaps one page-width contract for another. These two deterministic
/// destinations exercise that shipping path without loading developer accounts or transcript
/// usage. The exact General-to-Usage equality is held separately by `SettingsRowLayoutTests`.
@MainActor
final class SettingsCanvasRenderTests: HostedStoreTestCase {
    func testRendersTheSharedSettingsCanvasInTheMainWindow() throws {
        let directory: URL
        if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"],
           !override.isEmpty {
            directory = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let previousTheme = AppThemePalette.current
        defer { AppThemePalette.set(previousTheme) }
        AppThemePalette.set(.system)

        let controller = makeMainWindowController()
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 1_560, height: 900))
        let content = try XCTUnwrap(window.contentView)
        content.appearance = try XCTUnwrap(NSAppearance(named: .aqua))

        let destinations = [
            (SettingsPages.generalID, "general"),
            (SettingsPages.keyboardID, "keyboard")
        ]

        for (pageID, name) in destinations {
            controller.showSettingsPage(id: pageID)
            AppThemeRefresh.repaint(content)
            content.layoutSubtreeIfNeeded()
            content.displayIfNeeded()

            let rep = try XCTUnwrap(
                content.bitmapImageRepForCachingDisplay(in: content.bounds),
                "the main window did not allocate a bitmap for \(name) Settings"
            )
            content.cacheDisplay(in: content.bounds, to: rep)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try png.write(
                to: directory.appendingPathComponent("settings-canvas-\(name)-light.png")
            )
        }

        print("Rendered the shared Settings canvas to \(directory.path)")
    }
}

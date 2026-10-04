import AppKit
import XCTest
@testable import Threading

/// The authoring page ships in the display pane, whose width is owned by the split view.
/// Capture that container as well as the full-width page fixture.
@MainActor
final class CurrentThemeShellRenderTests: HostedStoreTestCase {
    func testRendersTuneInTheMainWindowDisplayPane() throws {
        let previous = AppThemeLibrary.current
        var theme = try AppThemeLibrary.duplicate(
            .system,
            name: "Shell Tune"
        )
        defer {
            AppThemeLibrary.apply(previous)
            _ = AppThemeLibrary.delete(theme)
        }
        var variants = theme.variants
        for kind in theme.availableVariants {
            let source = try XCTUnwrap(theme.variant(kind))
            let ground = theme.resolved(.ground, appearance: try XCTUnwrap(kind.appearance))
            var material = source.material
            material.backdrop = ThemeBackdrop(gradient: .init(stops: [
                .init(color: ground, position: 0), .init(color: ground, position: 1)
            ], drift: .init()), image: .init(asset: "fixture.png", opacity: 0.1),
                particles: .init(style: .snow))
            var terminal = source.terminalPalette
            terminal.glow = .standard
            variants[kind] = source.replacing(terminalPalette: terminal, material: material)
                .replacingTitleMorph(.init(style: .shapeMorph))
        }
        theme = AppTheme(id: theme.id, name: theme.name, mode: theme.mode,
            summary: theme.summary, variants: variants)
        try AppThemeLibrary.update(theme)
        AppThemeLibrary.apply(theme)

        let directory = URL(fileURLWithPath:
            ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"]
                ?? FileManager.default.temporaryDirectory.appendingPathComponent("ThreadingRenders").path,
            isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let controller = makeMainWindowController()
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 1_560, height: 1_080))
        let content = try XCTUnwrap(window.contentView)
        controller.displayPaneController.showSession(nil)
        controller.displayPaneController.showCurrentTheme()
        controller.setDisplayPaneVisible(true, animated: false, remembersSessionChoice: false)
        XCTAssertTrue(controller.displayPaneController.isShowingCurrentTheme)

        var capturedGroundBrightness: [CGFloat] = []
        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            content.appearance = appearance
            AppThemeRefresh.repaint(content)
            content.layoutSubtreeIfNeeded()
            let pane = controller.displayPaneController.view
            let slider = try XCTUnwrap(descendants(in: pane).first {
                $0.accessibilityIdentifier() == "current-theme.tune.density"
            })
            let scroll = try XCTUnwrap(slider.enclosingScrollView)
            let document = try XCTUnwrap(scroll.documentView)
            let tuningY = slider.convert(slider.bounds, to: document).minY - 300
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, tuningY)))
            scroll.reflectScrolledClipView(scroll.contentView)
            content.layoutSubtreeIfNeeded()
            for control in descendants(in: document).compactMap({ $0 as? ThemedScrubber }) {
                let frame = control.convert(control.bounds, to: pane)
                XCTAssertGreaterThanOrEqual(frame.minX, pane.bounds.minX)
                XCTAssertLessThanOrEqual(frame.maxX, pane.bounds.maxX)
            }
            let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            appearance.performAsCurrentDrawingAppearance {
                content.cacheDisplay(in: content.bounds, to: bitmap)
            }
            let ground = try XCTUnwrap(bitmap.colorAt(
                x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 4
            )?.usingColorSpace(.sRGB))
            capturedGroundBrightness.append((ground.redComponent + ground.greenComponent + ground.blueComponent) / 3)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(
                to: directory.appendingPathComponent("current-theme-shell-tune-\(name).png")
            )
        }
        XCTAssertGreaterThan(capturedGroundBrightness[0] - capturedGroundBrightness[1], 0.3,
            "Both captures must show their stated appearance; a light-only theme cannot exercise dark Tune")
        XCTAssertFalse(window.isVisible, "Fast evidence must not order the main window on screen")
    }

    /// A tick must reach pixels in the window it ships in, not only the palette: the radius
    /// re-cuts every card's corner and the picture opacity re-washes the pane's backdrop.
    /// Speed, density and the drift cycle change motion rather than a still frame, so their
    /// tick is asserted at the palette and repaint pass in `ThemeSystemWorkflowTests`.
    func testATuneTickRepaintsTheDisplayPaneItShipsIn() throws {
        let previous = AppThemeLibrary.current
        let custom = try AppThemeLibrary.duplicate(AppThemeStyles.cyberpunk, name: "Tick \(UUID())")
        defer {
            AppThemeLibrary.apply(previous)
            _ = AppThemeLibrary.delete(custom)
        }
        let white = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            NSColor.white.setFill(); rect.fill(); return true
        }
        let cgImage = try XCTUnwrap(white.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let asset = try XCTUnwrap(ThemeAssetStore.store(
            imageData: try XCTUnwrap(AppThemePreviewService.pngData(cgImage)),
            for: custom.id, slot: .backdrop, variant: .dark))
        let base = try XCTUnwrap(custom.variant(.dark))
        var material = base.material
        material.backdrop = ThemeBackdrop(image: .init(asset: asset, opacity: 0))
        let theme = AppTheme(id: custom.id, name: custom.name, mode: .dark, summary: nil,
            variants: [.dark: base.replacing(material: material)])
        try AppThemeLibrary.update(theme)
        AppThemeLibrary.apply(theme)

        let controller = makeMainWindowController()
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 1_560, height: 1_080))
        let content = try XCTUnwrap(window.contentView)
        content.appearance = NSAppearance(named: .darkAqua)
        controller.displayPaneController.showSession(nil)
        controller.displayPaneController.showCurrentTheme()
        controller.setDisplayPaneVisible(true, animated: false, remembersSessionChoice: false)
        let pane = controller.displayPaneController.view
        func capture() throws -> NSBitmapImageRep {
            content.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(pane.bitmapImageRepForCachingDisplay(in: pane.bounds))
            pane.effectiveAppearance.performAsCurrentDrawingAppearance {
                pane.cacheDisplay(in: pane.bounds, to: bitmap)
            }
            return bitmap
        }
        func slider(_ knob: CurrentThemeTuningControls.Knob) throws -> ThemedScrubber {
            try XCTUnwrap(descendants(in: pane).compactMap { $0 as? ThemedScrubber }.first {
                $0.accessibilityIdentifier() == "current-theme.tune.\(knob.rawValue)"
            })
        }
        for (knob, fraction) in [(CurrentThemeTuningControls.Knob.panelRadius, 1.0), (.pictureOpacity, 1.0)] {
            let before = try capture()
            let control = try slider(knob)
            control.onChange?(fraction)
            let after = try capture()
            control.onScrubEnd?(fraction)
            XCTAssertGreaterThan(changedPixels(before, after), 500, knob.rawValue)
        }
    }

    private func changedPixels(_ before: NSBitmapImageRep, _ after: NSBitmapImageRep) -> Int {
        let width = min(before.pixelsWide, after.pixelsWide), height = min(before.pixelsHigh, after.pixelsHigh)
        var changed = 0
        for y in stride(from: 0, to: height, by: 2) {
            for x in stride(from: 0, to: width, by: 2) where before.colorAt(x: x, y: y) != after.colorAt(x: x, y: y) {
                changed += 1
            }
        }
        return changed
    }

    private func descendants(in view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(in: $0) }
    }
}

import AppKit
import MetalKit
import ThreadingExtensionKit
import XCTest
@testable import Threading

@MainActor
final class AudioSpectrumPresentationTests: HostedStoreTestCase {
    private static let viewportWindow = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 240, height: 100),
        styleMask: [.borderless], backing: .buffered, defer: true
    )

    func testDemandFollowsViewportHiddenStateAndMotion() throws {
        let suite = "audio-viewport-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = AudioSpectrumService(settings: AppSettings(defaults: defaults), makeCapture: { nil })
        let previousSettings = DesignSettings.current
        let previousSeen = ThemeParticleHold.seenOverrideForTesting
        let previousMotion = Design.Motion.reduceMotionOverrideForTesting
        defer {
            service.stop()
            DesignSettings.current = previousSettings
            ThemeParticleHold.seenOverrideForTesting = previousSeen
            Design.Motion.reduceMotionOverrideForTesting = previousMotion
            Self.viewportWindow.contentView = nil
            ThemeParticleHold.shared.refreshAll()
        }
        DesignSettings.current = StubDesignSettings()
        ThemeParticleHold.seenOverrideForTesting = true
        Design.Motion.reduceMotionOverrideForTesting = false
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 100))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 500))
        let spectrum = AudioSpectrumView(service: service)
        spectrum.translatesAutoresizingMaskIntoConstraints = true
        spectrum.frame = NSRect(x: 12, y: 12, width: 86, height: 24)
        document.addSubview(spectrum)
        scroll.documentView = document
        Self.viewportWindow.contentView = scroll
        scroll.contentView.scroll(to: .zero)
        spectrum.refreshParticleMotion()
        XCTAssertEqual(service.consumerCount, 1)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 300))
        scroll.reflectScrolledClipView(scroll.contentView)
        XCTAssertEqual(service.consumerCount, 0, "scrolling releases demand without a polling timer")
        scroll.contentView.scroll(to: .zero)
        XCTAssertEqual(service.consumerCount, 1)
        spectrum.setPresented(false)
        XCTAssertEqual(service.consumerCount, 0)
        spectrum.setPresented(true)
        XCTAssertEqual(service.consumerCount, 1)
        Design.Motion.reduceMotionOverrideForTesting = true
        ThemeParticleHold.shared.refreshAll()
        XCTAssertEqual(service.consumerCount, 0)
        Design.Motion.reduceMotionOverrideForTesting = false
        DesignSettings.current = StubDesignSettings(playsThemeMotion: false)
        ThemeParticleHold.shared.refreshAll()
        XCTAssertEqual(service.consumerCount, 0)
        DesignSettings.current = StubDesignSettings()
        spectrum.refreshParticleMotion()
        XCTAssertEqual(service.consumerCount, 1)
        spectrum.removeFromSuperview()
        XCTAssertEqual(service.consumerCount, 0)
    }

    func testNativeAnalyzerRoundTripsAndTheToolCanRestoreTheDefault() throws {
        let document = SidebarStyle(brand: .init(analyzer: .audio))
        let decoded = try JSONDecoder().decode(SidebarStyle.self, from: JSONEncoder().encode(document))
        XCTAssertEqual(decoded.brand?.analyzer, .audio)
        XCTAssertFalse(decoded.isEmpty)
        let themeID = AppThemeID("custom-audio-parser-test")
        let change = try AppThemeToolParsing.sidebar(.init(analyzer: "audio"), base: nil,
                                                     themeID: themeID, kind: .dark)
        let style = try XCTUnwrap(change.applied(to: nil))
        XCTAssertEqual(style.brand?.analyzer, .audio)
        let wire = AppThemeToolParsing.document(style)
        XCTAssertEqual(wire["analyzer"] as? String, "audio")
        let cleared = try AppThemeToolParsing.sidebar(.init(analyzer: "default"), base: style,
                                                      themeID: themeID, kind: .dark)
        XCTAssertNil(cleared.applied(to: style))
        XCTAssertThrowsError(try AppThemeToolParsing.sidebar(.init(analyzer: "mystery"), base: nil,
                                                            themeID: themeID, kind: .dark))
        XCTAssertThrowsError(try AppThemeToolParsing.sidebar(.init(analyzer: "audio", remove: true), base: nil,
                                                            themeID: themeID, kind: .dark))
    }

    func testReferenceShaderUsesMeasuredBandsAndFallsBackWhenMotionStops() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let previousSettings = DesignSettings.current
        let previousMotion = Design.Motion.reduceMotionOverrideForTesting
        defer {
            DesignSettings.current = previousSettings
            Design.Motion.reduceMotionOverrideForTesting = previousMotion
        }
        DesignSettings.current = StubDesignSettings()
        Design.Motion.reduceMotionOverrideForTesting = false
        var available = true
        let surface = try ExtensionMetalSurfaceView(
            specification: .init(shaderResource: "Resources/spectrum.metal", preferredFramesPerSecond: 30,
                                 inputs: ExtensionHostSignal.audioBands.enumerated().map { index, signal in
                .init(name: "band.\(index)", value: .signal(signal, mapping: .identity))
            }), source: try shaderSource(), signalProvider: { _, _ in available ? 0.8 : nil })
        try await surface.waitForPreparation()
        XCTAssertNil(surface.hitTest(.zero))
        XCTAssertEqual(surface.preferredFramesPerSecond, 30)
        let playing = try XCTUnwrap(surface.snapshotImage(size: CGSize(width: 128, height: 64), time: 1))
        XCTAssertGreaterThan(try maximumAlpha(playing), 0.1)
        available = false
        let unavailable = try XCTUnwrap(surface.snapshotImage(size: CGSize(width: 128, height: 64), time: 1))
        XCTAssertEqual(try maximumAlpha(unavailable), 0)
        available = true
        Design.Motion.reduceMotionOverrideForTesting = true
        let reduced = try XCTUnwrap(surface.snapshotImage(size: CGSize(width: 128, height: 64), time: 1))
        XCTAssertEqual(try maximumAlpha(reduced), 0)
        Design.Motion.reduceMotionOverrideForTesting = false
        DesignSettings.current = StubDesignSettings(playsThemeMotion: false)
        let stopped = try XCTUnwrap(surface.snapshotImage(size: CGSize(width: 128, height: 64), time: 1))
        XCTAssertEqual(try maximumAlpha(stopped), 0)
    }

    func testRendersMusicSettingsAndAnalyzerInShippingWindow() throws {
        let previousTheme = AppThemePalette.current
        defer {
            AppThemePalette.set(previousTheme)
            NotificationCenter.default.post(AppThemeDidChange(themeID: previousTheme.id))
        }
        let shell = makeMainWindowController(initialFramePlan: .useDefaultFrame)
        let window = try XCTUnwrap(shell.window)
        window.setContentSize(NSSize(width: 1_400, height: 1_100))
        shell.showSettingsPage(id: SettingsPages.motionID)
        let content = try XCTUnwrap(window.contentView)
        let reading = AudioSpectrum(level: 0.7, bands: [0.85, 0.7, 0.45, 0.25, 0.6, 0.9, 0.55, 0.3])
        let themes: [(String, AppTheme, NSAppearance.Name)] = [
            ("system-light", .system, .aqua), ("system-dark", .system, .darkAqua),
            ("classic-player", AppThemeStyles.classicPlayer, .darkAqua),
            ("neo", AppThemeStyles.neoBrutalism, .aqua)
        ]
        for (name, base, appearance) in themes {
            let variants = base.availableVariants.reduce(into: [AppTheme.VariantKind: AppTheme.Variant]()) { result, kind in
                guard let variant = base.variant(kind) else { return }
                var sidebar = variant.sidebar ?? SidebarStyle()
                var brand = sidebar.brand ?? SidebarStyle.Brand()
                brand.analyzer = .audio
                sidebar.brand = brand
                result[kind] = variant.replacingSidebar(sidebar)
            }
            let theme = base.isSystem ? base : try AppThemeEditing.assemble(id: AppThemeID("custom-audio-evidence-\(name)"),
                name: "Music \(base.name)", mode: base.mode, summary: nil, variants: variants)
            AppThemePalette.set(theme)
            NotificationCenter.default.post(AppThemeDidChange(themeID: theme.id))
            content.appearance = NSAppearance(named: appearance)
            AppThemeRefresh.repaint(content)
            content.layoutSubtreeIfNeeded()
            let analyzers = descendants(content).compactMap { $0 as? AudioSpectrumView }
            XCTAssertGreaterThanOrEqual(analyzers.count, 2, "the preview and sidebar use the shipping analyzer")
            if !base.isSystem {
                XCTAssertGreaterThanOrEqual(analyzers.filter { !$0.isHiddenOrHasHiddenAncestor }.count, 2,
                    "changing the theme must restate the native brand as well as its colors")
            }
            analyzers.forEach { $0.freezePresentationForTesting(reading) }
            content.displayIfNeeded()
            try write(content, named: "theme-audio-\(name)")
            if name == "system-light" {
                analyzers.forEach { $0.freezePresentationForTesting(nil) }
                content.displayIfNeeded()
                try write(content, named: "theme-audio-unavailable")
            }
        }
    }

    private func shaderSource() throws -> String {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: repository.appendingPathComponent(
            "Packages/ThreadingExtensionKit/Examples/MusicSpectrumExtension/Resources/spectrum.metal"), encoding: .utf8)
    }

    private func maximumAlpha(_ image: NSImage) throws -> CGFloat {
        let bitmap = try XCTUnwrap(image.representations.compactMap { $0 as? NSBitmapImageRep }.first)
        var maximum: CGFloat = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide { maximum = max(maximum, bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) }
        }
        return maximum
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private func write(_ view: NSView, named name: String) throws {
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"] ?? "/tmp/ThreadingRenders")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("\(name).png"))
    }
}

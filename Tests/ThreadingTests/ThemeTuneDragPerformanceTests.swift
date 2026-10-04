import AppKit
import XCTest
@testable import Threading

/// What one Tune tick costs in a populated window, and where that cost goes.
///
/// Opt-in (`THREADING_STRESS=1`) because it prints numbers rather than asserting a wall-clock
/// budget: a timing threshold in the ordinary plan would fail on a loaded machine and say
/// nothing about the code. The workload is the real path — the Current Theme page in the main
/// window's display pane, its scrubber's `onChange` — over a sidebar of dormant sessions and
/// extra retained windows, so `repaintEverything` walks what it walks in the app.
/// Results and the decision they support are recorded in `docs/architecture/performance.md`.
@MainActor
final class ThemeTuneDragPerformanceTests: HostedStoreTestCase {

    private enum Fixture {
        static let projects = 12
        static let sessionsPerProject = 20
        static let extraWindows = 3
        static let ticks = 120
        static let windowSize = NSSize(width: 1_560, height: 1_080)
        static let legibilitySamples = 20
        static let legibilityImageSize = NSSize(width: 1_600, height: 800)
    }

    func testReportsWhatOneTuneTickCostsInAPopulatedWindow() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["THREADING_STRESS"] == "1")

        let store = ProjectStore.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tune-drag-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<Fixture.projects {
            let folder = root.appendingPathComponent("project-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let project = try XCTUnwrap(store.addProject(folderURL: folder))
            for session in 0..<Fixture.sessionsPerProject {
                store.addSession(to: project.id, kind: session.isMultiple(of: 2) ? .claude : .codex,
                                 title: "Session \(index)-\(session)")
            }
        }

        let previous = AppThemeLibrary.current
        let theme = try tunableTheme()
        defer {
            AppThemeLibrary.installResolved(previous)
            _ = AppThemeLibrary.delete(theme)
        }
        AppThemeLibrary.installResolved(theme)

        let controller = makeMainWindowController()
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(Fixture.windowSize)
        controller.displayPaneController.showSession(nil)
        controller.displayPaneController.showCurrentTheme()
        controller.setDisplayPaneVisible(true, animated: false, remembersSessionChoice: false)
        let extras: [NSWindow] = (0..<Fixture.extraWindows).map { _ in
            let page = CurrentThemeViewController()
            let extra = NSWindow(contentViewController: page)
            extra.setContentSize(NSSize(width: 720, height: 900))
            return extra
        }
        for candidate in [window] + extras { candidate.contentView?.layoutSubtreeIfNeeded() }
        let views = NSApp.windows.compactMap(\.contentView).map(viewCount).reduce(0, +)

        let pane = controller.displayPaneController.view
        for knob in [CurrentThemeTuningControls.Knob.panelRadius, .pictureOpacity, .glowRadius] {
            let slider = try XCTUnwrap(descendants(of: pane).compactMap { $0 as? ThemedScrubber }.first {
                $0.accessibilityIdentifier() == "current-theme.tune.\(knob.rawValue)"
            })
            var tick: [Double] = []
            var settle: [Double] = []
            for index in 0..<Fixture.ticks {
                let fraction = Double(index % 40) / 40
                tick.append(elapsed { slider.onChange?(fraction) })
                settle.append(elapsed {
                    for candidate in [window] + extras {
                        candidate.contentView?.layoutSubtreeIfNeeded()
                        candidate.displayIfNeeded()
                    }
                })
            }
            let release = elapsed { slider.onScrubEnd?(slider.value) }
            print("THREADING_PERF tune-drag knob=\(knob.rawValue) ticks=\(Fixture.ticks) "
                + "sessions=\(Fixture.projects * Fixture.sessionsPerProject) windows=\(NSApp.windows.count) "
                + "views=\(views) tick=\(summary(tick)) layout+display=\(summary(settle)) "
                + "release=\(format(release))")
        }

        // Attribution: the three things a tick does, measured alone on the same documents.
        let base = AppThemeLibrary.current
        let variant = try XCTUnwrap(base.variant(.dark))
        var assemble: [Double] = [], repaint: [Double] = [], post: [Double] = []
        for index in 0..<Fixture.ticks {
            var material = variant.material
            material.panelRadius = CGFloat(index % 40)
            var variants = base.variants
            variants[.dark] = variant.replacing(material: material)
            assemble.append(elapsed {
                _ = try? AppThemeEditing.assemble(id: base.id, name: base.name, mode: base.mode,
                                                 summary: base.summary, variants: variants)
            })
            repaint.append(elapsed { AppThemeRefresh.repaintEverything() })
            post.append(elapsed {
                NotificationCenter.default.post(AppThemeDidChange(themeID: base.id, isLivePreview: true))
            })
        }
        print("THREADING_PERF tune-drag-phases assemble=\(summary(assemble)) "
            + "repaintEverything=\(summary(repaint)) postPreviewEvent=\(summary(post))")
        withExtendedLifetime(extras) {}
    }

    /// The W10 sampler, before (exact `pow`) and after (table) on the same twenty pictures.
    func testReportsWhatTheLegibilitySamplerCosts() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["THREADING_STRESS"] == "1")
        let samples = try (0..<Fixture.legibilitySamples).map { index -> ThemeImageLegibility.Sample in
            let hue = CGFloat(index) / CGFloat(Fixture.legibilitySamples)
            let image = NSImage(size: Fixture.legibilityImageSize, flipped: false) { rect in
                NSGradient(starting: .white, ending: NSColor(hue: hue, saturation: 0.4, brightness: 1, alpha: 1))?
                    .draw(in: rect, angle: 30)
                return true
            }
            let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
            return ThemeImageLegibility.Sample(name: "sample-\(index)",
                data: try XCTUnwrap(AppThemePreviewService.pngData(cgImage)), url: nil, opacity: 1,
                label: .init(r: 0.95, g: 0.95, b: 0.95), labelAlpha: 1,
                grounds: (0..<8).map { stop in .init(r: Double(stop) / 40, g: 0.02, b: 0.05) })
        }
        let table = elapsed { _ = samples.compactMap(ThemeImageLegibility.finding) }
        let exact = elapsed { _ = samples.compactMap(Self.exactFinding) }
        print("THREADING_PERF theme-legibility samples=\(samples.count) grounds=8 "
            + "table=\(format(table)) exactPow=\(format(exact))")
        for sample in samples {
            XCTAssertEqual(ThemeImageLegibility.finding(sample)?.suggestedOpacity,
                Self.exactFinding(sample), sample.name)
        }
    }

    // MARK: - Fixtures

    private func tunableTheme() throws -> AppTheme {
        let custom = try AppThemeLibrary.duplicate(AppThemeStyles.cyberpunk, name: "Tune Stress \(UUID())")
        let base = try XCTUnwrap(custom.variant(.dark))
        var material = base.material
        let ground = try XCTUnwrap(NSColor(hex: "#101010"))
        let picture = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            NSColor.darkGray.setFill(); rect.fill(); return true
        }
        let cgImage = try XCTUnwrap(picture.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let asset = try XCTUnwrap(ThemeAssetStore.store(imageData: try XCTUnwrap(AppThemePreviewService.pngData(cgImage)),
            for: custom.id, slot: .backdrop, variant: .dark))
        material.backdrop = ThemeBackdrop(gradient: .init(stops: [
            .init(color: ground, position: 0), .init(color: ground, position: 1)
        ], drift: .init()), image: .init(asset: asset, opacity: 0.2), particles: .init(style: .snow))
        var terminal = base.terminalPalette
        terminal.glow = .standard
        let theme = AppTheme(id: custom.id, name: custom.name, mode: .dark, summary: nil,
            variants: [.dark: base.replacing(terminalPalette: terminal, material: material)])
        try AppThemeLibrary.update(theme)
        return theme
    }

    /// The pre-table algorithm, verbatim in its arithmetic: decode per call, `pow` per channel.
    private static func exactFinding(_ sample: ThemeImageLegibility.Sample) -> Double? {
        guard let data = sample.data,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 64,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8,
                bytesPerRow: 256, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let buffer = context.data else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 64))
        let pixels = buffer.assumingMemoryBound(to: UInt8.self)
        func luminance(_ r: Double, _ g: Double, _ b: Double) -> Double {
            0.2126 * ThemeImageLegibility.Linearization.exact(r)
                + 0.7152 * ThemeImageLegibility.Linearization.exact(g)
                + 0.0722 * ThemeImageLegibility.Linearization.exact(b)
        }
        func contrast(at opacity: Double) -> Double {
            var ratios: [Double] = []
            for index in 0..<(64 * 64) {
                let alpha = Double(pixels[index * 4 + 3]) / 255
                let divisor = max(alpha * 255, 1)
                let ink = ThemeImageLegibility.RGB(r: Double(pixels[index * 4]) / divisor,
                    g: Double(pixels[index * 4 + 1]) / divisor, b: Double(pixels[index * 4 + 2]) / divisor)
                ratios.append(sample.grounds.map { ground in
                    let background = ink.over(ground, opacity: alpha * opacity)
                    let foreground = sample.label.over(background, opacity: sample.labelAlpha)
                    let a = luminance(foreground.r, foreground.g, foreground.b)
                    let b = luminance(background.r, background.g, background.b)
                    return (max(a, b) + 0.05) / (min(a, b) + 0.05)
                }.min() ?? 1)
            }
            ratios.sort()
            return ratios[ratios.count / 10]
        }
        guard contrast(at: sample.opacity) < 3 else { return nil }
        var suggested = max(0, sample.opacity - 0.05)
        while suggested > 0, contrast(at: suggested) < 3 { suggested = max(0, suggested - 0.05) }
        return suggested
    }

    private func viewCount(_ view: NSView) -> Int {
        1 + view.subviews.map(viewCount).reduce(0, +)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func elapsed(_ work: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        work()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private func summary(_ values: [Double]) -> String {
        let sorted = values.sorted()
        let median = sorted[sorted.count / 2]
        let p90 = sorted[min(sorted.count - 1, sorted.count * 9 / 10)]
        return "median \(format(median)) p90 \(format(p90)) max \(format(sorted.last ?? 0))"
    }

    private func format(_ milliseconds: Double) -> String {
        String(format: "%.2fms", milliseconds)
    }
}

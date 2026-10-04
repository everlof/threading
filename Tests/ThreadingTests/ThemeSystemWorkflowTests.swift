import AppKit
import XCTest
import ThreadingRemoteKit
import ThreadingExtensionKit
import AVFoundation
@testable import Threading

@MainActor
final class ThemeSystemWorkflowTests: XCTestCase {
    func testPairedFontPreparationAdmitsOnlyTheDeclaredFamily() async throws {
        let root = try XCTUnwrap(Bundle.main.url(forResource: "W95FA", withExtension: "otf"))
        let worker = RemoteThemeRenditionWorker()
        let prepared = await worker.prepare([], fontURLs: [root], fontFamilies: ["W95FA"])
        let font = try XCTUnwrap(prepared.first)
        XCTAssertEqual(font.asset.kind, .font)
        XCTAssertEqual(font.asset.fontFamily, "W95FA")
        XCTAssertEqual(font.payload.read(nil, expectedCount: font.asset.byteCount)?.count, font.asset.byteCount)
        let rejected = await worker.prepare([], fontURLs: [root], fontFamilies: ["Another Family"])
        XCTAssertTrue(rejected.isEmpty)
    }

    func testPairedShaderSourceCannotEscapeItsReviewedPackage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = Data("float4 threadingSurface(float2 uv, constant ThreadingSurfaceUniforms &u) { return float4(uv, 0, 1); }".utf8)
        try source.write(to: directory.appendingPathComponent("backdrop.metal"))
        let worker = RemoteThemeRenditionWorker()
        let prepared = await worker.prepareSurface(.init(shaderResource: "backdrop.metal"), root: directory)
        let shader = try XCTUnwrap(prepared?.assets.first)
        XCTAssertEqual(shader.payload.read(nil, expectedCount: shader.asset.byteCount), source)
        XCTAssertTrue(try XCTUnwrap(prepared?.surface).isValid)
        let escaped = await worker.prepareSurface(.init(shaderResource: "../backdrop.metal"), root: directory)
        XCTAssertNil(escaped)
        let outside = directory.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try source.write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("link.metal"), withDestinationURL: outside)
        let linked = await worker.prepareSurface(.init(shaderResource: "link.metal"), root: directory)
        XCTAssertNil(linked)
    }

    func testNotificationRenditionConvertsAShortSoundAndRejectsThirtySeconds() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (seconds, accepted) in [(0.1, true), (30.0, false)] {
            let url = directory.appendingPathComponent("\(seconds).caf")
            let bytes = try await Task.detached {
                let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
                do {
                    var file: AVAudioFile? = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
                    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(seconds * 16_000))!
                    buffer.frameLength = buffer.frameCapacity
                    memset(buffer.int16ChannelData![0], 0, Int(buffer.frameLength) * 2)
                    try file?.write(from: buffer)
                    file = nil
                }
                return try Data(contentsOf: url)
            }.value
            let prepared = await RemoteThemeRenditionWorker().prepare([.init(slot: "sound.needsAttention",
                data: bytes, url: nil, bound: 0, opacity: nil, tinted: nil)])
            XCTAssertEqual(!prepared.isEmpty, accepted)
            if accepted {
                XCTAssertNotNil(prepared.first?.asset.notificationSoundName)
                let sound = try XCTUnwrap(prepared.first)
                XCTAssertLessThanOrEqual(try XCTUnwrap(sound.payload.read(nil, expectedCount: sound.asset.byteCount)).count,
                    RemoteThemeAsset.maximumBytes)
            }
        }
    }

    func testTuningPreviewsWithoutSavingAndCommitsOneRevision() throws {
        let previous = AppThemeLibrary.current
        let theme = try AppThemeLibrary.duplicate(AppThemeStyles.cyberpunk, name: "Tune \(UUID())")
        defer {
            AppThemeLibrary.installResolved(previous)
            _ = AppThemeLibrary.delete(theme)
        }
        AppThemeLibrary.installResolved(theme)
        let controls = CurrentThemeTuningControls()
        _ = controls.section()
        controls.show(theme, kind: .dark)
        var revisions = 0
        let observations = AppEventObservations()
        observations.observe(AppThemeLibraryDidChange.self) { _ in revisions += 1 }
        for fraction in [0.1, 0.4, 0.8] { controls.preview(.panelRadius, fraction: fraction) }
        XCTAssertEqual(AppThemeLibrary.current.variant(.dark)?.material.panelRadius, 32)
        XCTAssertEqual(AppThemeLibrary.custom.first { $0.id == theme.id }, theme)
        XCTAssertEqual(revisions, 0)
        controls.commit()
        XCTAssertEqual(revisions, 1)
        XCTAssertEqual(AppThemeLibrary.custom.first { $0.id == theme.id }, AppThemeLibrary.current)
        controls.commit()
        XCTAssertEqual(revisions, 1)
        withExtendedLifetime(observations) {}
    }

    func testTuningCannotMutateABuiltinOrAnExternallyReplacedTheme() throws {
        let previous = AppThemeLibrary.current
        defer { AppThemeLibrary.installResolved(previous) }
        let controls = CurrentThemeTuningControls()
        _ = controls.section()
        AppThemeLibrary.installResolved(AppThemeStyles.cyberpunk)
        controls.show(AppThemeStyles.cyberpunk, kind: .dark)
        controls.preview(.panelRadius, fraction: 1)
        controls.commit()
        XCTAssertEqual(AppThemeLibrary.current, AppThemeStyles.cyberpunk)

        // An MCP update replaces the stored document mid-drag. No reload reaches these
        // controls here, so the refusal has to come from the drag's own ownership check.
        let theme = try AppThemeLibrary.duplicate(AppThemeStyles.cyberpunk, name: "Replaced \(UUID())")
        defer { _ = AppThemeLibrary.delete(theme) }
        AppThemeLibrary.installResolved(theme)
        controls.show(theme, kind: .dark)
        controls.preview(.panelRadius, fraction: 0.1)
        XCTAssertEqual(AppThemeLibrary.current.variant(.dark)?.material.panelRadius, 4)
        let replacement = try replacingDark(of: theme) { $0.controlRadius = 3 }
        try AppThemeLibrary.update(replacement)
        controls.preview(.panelRadius, fraction: 0.9)
        controls.commit()
        XCTAssertEqual(AppThemeLibrary.current, replacement, "the external document stays in force")
        XCTAssertEqual(AppThemeLibrary.custom.first { $0.id == theme.id }, replacement)
        // The refusal lasts until the release; the next drag edits the new document.
        controls.preview(.panelRadius, fraction: 0.5)
        controls.commit()
        let stored = try XCTUnwrap(AppThemeLibrary.custom.first { $0.id == theme.id }?.variant(.dark))
        XCTAssertEqual(stored.material.panelRadius, 20)
        XCTAssertEqual(stored.material.controlRadius, 3)
    }

    /// An unrelated library or activation event mid-drag used to reset the preview, leaving it
    /// on screen and never saved. Driven through the real page and its observations.
    func testADragSurvivesUnrelatedEventsAndSavesOnRelease() throws {
        let previous = AppThemeLibrary.current
        let theme = try AppThemeLibrary.duplicate(AppThemeStyles.cyberpunk, name: "Drag \(UUID())")
        var other: AppTheme?
        defer {
            AppThemeLibrary.installResolved(previous)
            _ = AppThemeLibrary.delete(theme)
            if let other { _ = AppThemeLibrary.delete(other) }
        }
        AppThemeLibrary.installResolved(theme)
        let page = CurrentThemeViewController()
        let slider = try scrubber(.panelRadius, in: page)
        slider.onChange?(0.1)
        other = try AppThemeLibrary.duplicate(AppThemeStyles.cyberpunk, name: "Bystander \(UUID())")
        NotificationCenter.default.post(AppearanceActivationDidChange())
        NotificationCenter.default.post(AppThemeLibraryDidChange())
        XCTAssertEqual(AppThemeLibrary.current.variant(.dark)?.material.panelRadius, 4,
            "the preview stays on screen")
        slider.onChange?(0.8)
        slider.onScrubEnd?(0.8)
        let stored = try XCTUnwrap(AppThemeLibrary.custom.first { $0.id == theme.id })
        XCTAssertEqual(stored.variant(.dark)?.material.panelRadius, 32)
        XCTAssertEqual(AppThemeLibrary.current, stored)
        XCTAssertEqual(AppThemeLibrary.custom.first { $0.id == other?.id }?.variant(.dark)?.material.panelRadius,
            AppThemeStyles.cyberpunk.variant(.dark)?.material.panelRadius)
    }

    /// `set_app_theme` mid-drag rebinds the page; the rest of the drag must write nowhere.
    func testADragEndsWhenAnotherThemeIsAppliedMidway() throws {
        let previous = AppThemeLibrary.current
        let first = try AppThemeLibrary.duplicate(AppThemeStyles.cyberpunk, name: "First \(UUID())")
        let second = try AppThemeLibrary.duplicate(AppThemeStyles.cyberpunk, name: "Second \(UUID())")
        defer {
            AppThemeLibrary.installResolved(previous)
            _ = AppThemeLibrary.delete(first)
            _ = AppThemeLibrary.delete(second)
        }
        AppThemeLibrary.installResolved(first)
        let page = CurrentThemeViewController()
        let slider = try scrubber(.panelRadius, in: page)
        slider.onChange?(0.1)
        AppThemeLibrary.installResolved(second)
        slider.onChange?(0.8)
        XCTAssertEqual(AppThemeLibrary.current, second)
        slider.onScrubEnd?(0.8)
        XCTAssertEqual(AppThemeLibrary.current, second)
        XCTAssertEqual(AppThemeLibrary.custom.first { $0.id == first.id }, first)
        XCTAssertEqual(AppThemeLibrary.custom.first { $0.id == second.id }, second)
        slider.onChange?(0.5)
        slider.onScrubEnd?(0.5)
        XCTAssertEqual(AppThemeLibrary.custom.first { $0.id == second.id }?.variant(.dark)?.material.panelRadius, 20)
        XCTAssertEqual(AppThemeLibrary.custom.first { $0.id == first.id }, first)
    }

    /// Every tick reaches the palette every themed view draws from and repaints what it
    /// changed, announced as a preview; the release announces the durable value exactly once.
    /// A glow tick reaches the terminals' own profile instead of the window walk, which the
    /// settle then runs once.
    func testEveryKnobTickRepaintsAsAPreviewAndTheReleaseSettlesIt() throws {
        let previous = AppThemeLibrary.current
        let theme = try tunableTheme()
        defer {
            AppThemeLibrary.installResolved(previous)
            _ = AppThemeLibrary.delete(theme)
        }
        AppThemeLibrary.installResolved(theme)
        let controls = CurrentThemeTuningControls()
        _ = controls.section()
        controls.show(theme, kind: .dark)
        var events: [Bool] = []
        let observations = AppEventObservations()
        observations.observe(AppThemeDidChange.self) { events.append($0.isLivePreview) }
        for knob in CurrentThemeTuningControls.Knob.allCases {
            for fraction in [0.2, 0.9] {
                events = []
                let generation = AppThemeRefresh.generation
                controls.preview(knob, fraction: fraction)
                let expected = knob.range.lowerBound + fraction * (knob.range.upperBound - knob.range.lowerBound)
                let painted = try XCTUnwrap(AppThemePalette.current.variant(.dark))
                XCTAssertEqual(try XCTUnwrap(knob.value(in: painted)), expected, accuracy: 0.001, knob.rawValue)
                switch knob.previewScope {
                case .everything:
                    XCTAssertGreaterThan(AppThemeRefresh.generation, generation, "\(knob.rawValue) repainted")
                case .terminalPalette:
                    XCTAssertEqual(AppThemeRefresh.generation, generation, "\(knob.rawValue) skips the walk")
                    let glow = try XCTUnwrap(ThemeAssignments.palette(withID: .followsAppTheme).glow)
                    XCTAssertEqual(knob == .glowRadius ? Double(glow.radius) : glow.opacity, expected,
                        accuracy: 0.001, "terminals re-read \(knob.rawValue) from their profile")
                }
                XCTAssertEqual(events, [true], knob.rawValue)
                XCTAssertTrue(controls.hasPreviewInFlight)
            }
            events = []
            let generation = AppThemeRefresh.generation
            controls.commit()
            XCTAssertEqual(events, [false], "\(knob.rawValue) settles once")
            XCTAssertFalse(controls.hasPreviewInFlight)
            if knob.previewScope == .terminalPalette {
                XCTAssertGreaterThan(AppThemeRefresh.generation, generation, "the settle catches the window up")
            }
        }
        withExtendedLifetime(observations) {}
    }

    func testTitleMorphMenuLeavesScrambleAndKeepsItsAlphabetForTheWayBack() throws {
        let previous = AppThemeLibrary.current
        let theme = try tunableTheme()
        defer {
            AppThemeLibrary.installResolved(previous)
            _ = AppThemeLibrary.delete(theme)
        }
        AppThemeLibrary.installResolved(theme)
        let controls = CurrentThemeTuningControls()
        let section = controls.section()
        controls.show(theme, kind: .dark)
        let menu = try XCTUnwrap(descendant(ThemedPopUp.self, "current-theme.tune.morph", in: section))
        func choose(_ style: ChatNameMorphStyle) throws -> ThemeTitleMorph? {
            menu.selectItem(at: try XCTUnwrap(menu.indexOfItem { $0.representedValue as? ChatNameMorphStyle == style }))
            menu.sendAction(menu.action, to: menu.target)
            return AppThemeLibrary.custom.first { $0.id == theme.id }?.variant(.dark)?.titleMorph
        }
        XCTAssertEqual(try choose(.crossfade), ThemeTitleMorph(style: .crossfade))
        XCTAssertEqual(try choose(.typewriter), ThemeTitleMorph(style: .typewriter))
        XCTAssertEqual(try choose(.scramble), ThemeTitleMorph(style: .scramble, characters: Self.alphabet))
        XCTAssertEqual(AppThemeLibrary.current.variant(.dark)?.titleMorph?.characters, Self.alphabet)
    }

    func testTuneTogglesEachSaveOneValidatedChange() throws {
        let previous = AppThemeLibrary.current
        let theme = try tunableTheme()
        defer {
            AppThemeLibrary.installResolved(previous)
            _ = AppThemeLibrary.delete(theme)
        }
        AppThemeLibrary.installResolved(theme)
        let controls = CurrentThemeTuningControls()
        let section = controls.section()
        controls.show(theme, kind: .dark)
        var revisions = 0
        let observations = AppEventObservations()
        observations.observe(AppThemeLibraryDidChange.self) { _ in revisions += 1 }
        func stored() throws -> AppTheme.Variant {
            try XCTUnwrap(AppThemeLibrary.custom.first { $0.id == theme.id }?.variant(.dark))
        }
        func press(_ id: String) throws {
            let toggle = try XCTUnwrap(descendant(ThemedToggle.self, id, in: section), id)
            XCTAssertTrue(toggle.isEnabled, id)
            XCTAssertTrue(toggle.accessibilityPerformPress(), id)
        }
        try press("current-theme.tune.drift")
        XCTAssertNil(try stored().material.backdrop?.gradient?.drift)
        try press("current-theme.tune.drift")
        XCTAssertEqual(try stored().material.backdrop?.gradient?.drift, ThemeGradientDrift())
        try press("current-theme.tune.glow")
        XCTAssertNil(try stored().terminalPalette.glow)
        try press("current-theme.tune.glow")
        XCTAssertEqual(try stored().terminalPalette.glow, .standard)
        try press("current-theme.tune.tinted")
        XCTAssertEqual(try stored().material.identityMarks, .tinted)
        try press("current-theme.tune.tinted")
        XCTAssertEqual(try stored().material.identityMarks, .natural)
        XCTAssertEqual(revisions, 6)
        XCTAssertEqual(AppThemeLibrary.current, AppThemeLibrary.custom.first { $0.id == theme.id })
        withExtendedLifetime(observations) {}
    }

    /// The reading names its unit, uses the person's decimal separator, and never falls back to
    /// scientific notation; the slider speaks the long form.
    func testReadingsNameTheirUnitInThePersonsLocale() {
        typealias Reading = CurrentThemeTuningControls.Reading
        let english = Locale(identifier: "en_US"), swedish = Locale(identifier: "sv_SE")
        XCTAssertEqual(Reading.seconds.text(120, locale: english).filter(\.isNumber), "120")
        XCTAssertFalse(Reading.seconds.text(120, locale: english).contains("e+"))
        XCTAssertTrue(Reading.seconds.spoken(120, locale: english).contains("second"))
        XCTAssertTrue(Reading.points.text(1.5, locale: swedish).contains("1,5"))
        XCTAssertTrue(Reading.points.text(1.5, locale: english).contains("1.5"))
        XCTAssertTrue(Reading.multiplier.text(2.25, locale: english).contains("2.25"))
        XCTAssertTrue(Reading.percent.text(0.6, locale: english).contains("60"))
        for knob in CurrentThemeTuningControls.Knob.allCases {
            for value in [knob.range.lowerBound, knob.range.upperBound] {
                XCTAssertFalse(knob.reading.text(value).contains("e+"), knob.rawValue)
            }
        }
    }

    /// The tracks offer only what the validator accepts and the renderer draws.
    func testTracksMatchTheValidatorAndTheRenderer() throws {
        typealias Knob = CurrentThemeTuningControls.Knob
        XCTAssertEqual(Knob.opacity.range.upperBound, ThemeParticleLimits.ambientOpacityCeiling)
        XCTAssertEqual(Knob.panelRadius.range.upperBound, Double(AppThemeMaterialLimits.panelRadiusRange.upperBound))
        XCTAssertEqual(Knob.controlRadius.range.upperBound, Double(AppThemeMaterialLimits.controlRadiusRange.upperBound))

        let previous = AppThemeLibrary.current
        let custom = try AppThemeLibrary.duplicate(AppThemeStyles.cyberpunk, name: "Bevel \(UUID())")
        defer {
            AppThemeLibrary.installResolved(previous)
            _ = AppThemeLibrary.delete(custom)
        }
        let bevelled = try replacingDark(of: custom) { material in
            material.panelRadius = 0
            material.controlRadius = 0
            material.bevel = AppTheme.Bevel()
        }
        try AppThemeLibrary.update(bevelled)
        AppThemeLibrary.installResolved(bevelled)
        let controls = CurrentThemeTuningControls()
        let section = controls.section()
        controls.show(bevelled, kind: .dark)
        for knob in [Knob.panelRadius, .controlRadius] {
            let slider = try XCTUnwrap(descendant(ThemedScrubber.self, "current-theme.tune.\(knob.rawValue)", in: section))
            XCTAssertFalse(slider.isEnabled, "a hard bevel refuses every corner but zero")
        }
    }

    func testTunePictureOpacityReleaseReportsLegibility() async throws {
        let previous = AppThemeLibrary.current
        let theme = try tunableTheme(pictureOpacity: 0.1)
        defer {
            AppThemeLibrary.installResolved(previous)
            _ = AppThemeLibrary.delete(theme)
        }
        AppThemeLibrary.installResolved(theme)
        let controls = CurrentThemeTuningControls()
        _ = controls.section()
        controls.show(theme, kind: .dark)
        var advisories: [String] = []
        controls.onAdvisory = { advisories.append($0) }
        controls.preview(.pictureOpacity, fraction: 1)
        XCTAssertTrue(advisories.isEmpty, "nothing is sampled per tick")
        controls.commit()
        for _ in 0..<500 where advisories.count < 2 { try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertEqual(advisories.first, "", "a release withdraws the previous advisory first")
        let advisory = try XCTUnwrap(advisories.last)
        XCTAssertFalse(advisory.isEmpty, "a white picture at full strength under light text is reported")
        XCTAssertTrue(advisory.contains(":1"), advisory)
        withExtendedLifetime(controls) {}
    }

    func testLegibilityTableMatchesTheExactTransferFunction() {
        for step in 0...1_000 {
            let value = Double(step) / 1_000
            XCTAssertEqual(ThemeImageLegibility.Linearization.linear(value),
                ThemeImageLegibility.Linearization.exact(value), accuracy: 1e-6)
        }
    }

    // MARK: - Fixtures

    private static let alphabet = "ｱｲｳｴｵ0123"

    /// A custom dark theme stating every block Tune moves, with a real stored backdrop picture.
    private func tunableTheme(pictureOpacity: Double = 0.1) throws -> AppTheme {
        let custom = try AppThemeLibrary.duplicate(AppThemeStyles.cyberpunk, name: "Tunable \(UUID())")
        let white = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            NSColor.white.setFill(); rect.fill(); return true
        }
        let cgImage = try XCTUnwrap(white.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let asset = try XCTUnwrap(ThemeAssetStore.store(imageData: try XCTUnwrap(AppThemePreviewService.pngData(cgImage)),
            for: custom.id, slot: .backdrop, variant: .dark))
        let base = try XCTUnwrap(custom.variant(.dark))
        var material = base.material
        let ground = try XCTUnwrap(NSColor(hex: "#101010"))
        material.backdrop = ThemeBackdrop(gradient: .init(stops: [
            .init(color: ground, position: 0), .init(color: ground, position: 1)
        ], drift: .init()), image: .init(asset: asset, opacity: pictureOpacity),
            particles: .init(style: .snow))
        material.identityMarks = .natural
        var terminal = base.terminalPalette
        terminal.glow = .standard
        let theme = AppTheme(id: custom.id, name: custom.name, mode: .dark, summary: nil,
            variants: [.dark: base.replacing(terminalPalette: terminal, material: material)
                .replacingTitleMorph(.init(style: .scramble, characters: Self.alphabet))])
        try AppThemeLibrary.update(theme)
        return theme
    }

    private func replacingDark(of theme: AppTheme, _ edit: (inout AppTheme.Material) -> Void) throws -> AppTheme {
        let variant = try XCTUnwrap(theme.variant(.dark))
        var material = variant.material
        edit(&material)
        return AppTheme(id: theme.id, name: theme.name, mode: theme.mode, summary: theme.summary,
            variants: [.dark: variant.replacing(material: material)])
    }

    private func scrubber(_ knob: CurrentThemeTuningControls.Knob,
                          in page: CurrentThemeViewController) throws -> ThemedScrubber {
        try XCTUnwrap(descendant(ThemedScrubber.self, "current-theme.tune.\(knob.rawValue)", in: page.view))
    }

    private func descendant<View: NSView>(_ type: View.Type, _ identifier: String, in root: NSView) -> View? {
        if let match = root as? View, root.accessibilityIdentifier() == identifier { return match }
        for child in root.subviews {
            if let match = descendant(type, identifier, in: child) { return match }
        }
        return nil
    }

    func testEveryTuningKnobUsesAValidatedPersistentVariant() throws {
        let previous = AppThemeLibrary.current
        let custom = try AppThemeLibrary.duplicate(AppThemeStyles.cyberpunk, name: "Knobs \(UUID())")
        defer {
            AppThemeLibrary.installResolved(previous)
            _ = AppThemeLibrary.delete(custom)
        }
        let base = try XCTUnwrap(custom.variant(.dark))
        var material = base.material
        let ground = try XCTUnwrap(NSColor(hex: "#101010"))
        material.backdrop = ThemeBackdrop(gradient: .init(stops: [
            .init(color: ground, position: 0), .init(color: ground, position: 1)
        ], drift: .init()), image: .init(asset: "backdrop-dark.png", opacity: 0.1),
            particles: .init(style: .snow))
        var terminal = base.terminalPalette
        terminal.glow = .standard
        let theme = AppTheme(id: custom.id, name: custom.name, mode: .dark, summary: nil,
            variants: [.dark: base.replacing(terminalPalette: terminal, material: material)])
        try AppThemeLibrary.update(theme)
        AppThemeLibrary.installResolved(theme)
        let controls = CurrentThemeTuningControls()
        _ = controls.section()
        controls.show(theme, kind: .dark)
        for knob in CurrentThemeTuningControls.Knob.allCases {
            controls.preview(knob, fraction: 0.5)
            controls.commit()
            let value = try XCTUnwrap(AppThemeLibrary.custom.first { $0.id == custom.id }?.variant(.dark))
            XCTAssertEqual(try XCTUnwrap(knob.value(in: value)),
                (knob.range.lowerBound + knob.range.upperBound) / 2, accuracy: 0.001, knob.rawValue)
        }
    }

    func testPhoneRenditionsAreBoundedAndContentAddressed() async throws {
        func png(_ color: NSColor) throws -> Data {
            let image = NSImage(size: NSSize(width: 1600, height: 800), flipped: false) { rect in
                color.setFill(); rect.fill(); return true
            }
            let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
            return try XCTUnwrap(AppThemePreviewService.pngData(cg))
        }
        let red = try png(.red)
        let worker = RemoteThemeRenditionWorker()
        let source = RemoteThemeRenditionWorker.Source(slot: "backdrop", data: red, url: nil,
            bound: 1290, opacity: 0.2, tinted: nil)
        let prepared = await worker.prepare([source])
        let first = try XCTUnwrap(prepared.first)
        XCTAssertLessThanOrEqual(first.asset.pixelWidth, 1290)
        XCTAssertLessThanOrEqual(try XCTUnwrap(first.payload.read(nil, expectedCount: first.asset.byteCount)).count,
            RemoteThemeAsset.maximumBytes)
        let repeated = await worker.prepare([source])
        XCTAssertEqual(repeated.first?.asset.digest, first.asset.digest)
        let changed = await worker.prepare([.init(slot: "backdrop", data: try png(.blue), url: nil,
            bound: 1290, opacity: 0.2, tinted: nil)])
        XCTAssertNotEqual(changed.first?.asset.digest, first.asset.digest)
    }

    func testImageLegibilityWarnsForBrightPhotographsButAcceptsDarkArtwork() throws {
        let white = ThemeImageLegibility.RGB(r: 1, g: 1, b: 1)
        let black = ThemeImageLegibility.RGB(r: 0, g: 0, b: 0)
        func sample(_ color: NSColor) throws -> ThemeImageLegibility.Sample {
            let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
                color.setFill(); rect.fill(); return true
            }
            let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
            return .init(name: "fixture", data: try XCTUnwrap(AppThemePreviewService.pngData(cgImage)),
                url: nil, opacity: 0.8, label: white, labelAlpha: 1, grounds: [black])
        }
        XCTAssertNotNil(ThemeImageLegibility.warning(try sample(.white)))
        XCTAssertNil(ThemeImageLegibility.warning(try sample(.black)))
    }
}

@MainActor
final class AppThemePreviewCoverageTests: XCTestCase {
    func testThreePreviewFramesShowTheAuthoredDriftAndRestoreThePalette() throws {
        let source = AppThemeStyles.cyberpunk
        let base = try XCTUnwrap(source.variant(.dark))
        var material = base.material
        material.backdrop = ThemeBackdrop(gradient: .init(stops: [
            .init(color: try XCTUnwrap(NSColor(hex: "#040410")), position: 0),
            .init(color: try XCTUnwrap(NSColor(hex: "#202040")), position: 1)
        ], drift: .init(duration: 8, distance: 0.2)))
        let theme = AppTheme(id: source.id, name: source.name, mode: .dark, summary: nil,
            variants: [.dark: base.replacing(material: material)])
        let previous = AppThemePalette.current
        let one = try XCTUnwrap(AppThemePreviewService.render(theme, kinds: [.dark]))
        let three = try XCTUnwrap(AppThemePreviewService.render(theme, kinds: [.dark], frameCount: 3))
        XCTAssertEqual(three.width, one.width)
        XCTAssertEqual(three.height, one.height * 3)
        let first = try XCTUnwrap(three.cropping(to: CGRect(x: 0, y: 0, width: one.width, height: one.height)))
        let second = try XCTUnwrap(three.cropping(to: CGRect(x: 0, y: one.height, width: one.width, height: one.height)))
        XCTAssertGreaterThan(try changedPixels(first, second, region: CGRect(x: 380, y: 55, width: 730, height: 60)), 100)
        XCTAssertEqual(AppThemePalette.current.id, previous.id)
        XCTAssertNil(AppThemePreviewService.render(theme, kinds: [.dark], frameCount: 2))
        if let output = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"] {
            try XCTUnwrap(AppThemePreviewService.pngData(three)).write(to: URL(fileURLWithPath: output).appendingPathComponent("theme-preview-motion.png"))
        }
    }
    func testPreviewShowsWordsIdentityInkAndTerminalGlow() throws {
        let source = AppThemeStyles.cyberpunk
        let base = try XCTUnwrap(source.variant(.dark))
        var tinted = base.material
        tinted.identityMarks = .tinted
        var glowing = base.terminalPalette
        glowing.glow = .standard
        let variants: [(String, AppTheme.Variant, CGRect)] = [
            ("words", base.replacingCharacter(sprites: base.sprites, moments: base.moments, words: .init(working: ["Charting…"],
                composerPlaceholder: "Describe a mission", untitledSession: "Uncharted")),
                CGRect(x: 0, y: 100, width: 1140, height: 350)),
            ("identity", base.replacing(material: tinted), CGRect(x: 0, y: 150, width: 375, height: 375)),
            ("glow", base.replacing(terminalPalette: glowing), CGRect(x: 405, y: 480, width: 705, height: 190))
        ]
        let before = try render(source, name: "base", kind: .dark)
        for (name, variant, region) in variants {
            let theme = AppTheme(id: source.id, name: source.name, mode: .dark,
                summary: nil, variants: [.dark: variant])
            let after = try render(theme, name: name, kind: .dark)
            XCTAssertGreaterThan(try changedPixels(before, after, region: region), 40, name)
            if name == "identity" {
                let ink = try pixels(after, region: CGRect(x: 28, y: 202, width: 28, height: 28))
                let dark = stride(from: 0, to: ink.count, by: 4).filter {
                    ink[$0] < 60 && ink[$0 + 1] < 60 && ink[$0 + 2] < 60
                }.count
                XCTAssertGreaterThan(dark, 15, "A tinted selected mark must read against the accent selection")
            }
        }
    }

    func testPreviewDrawsTheAuthoredTitleBand() throws {
        let source = try XCTUnwrap(AppThemeStyles.all.first { theme in
            theme.availableVariants.contains { theme.variant($0)?.chrome != nil }
        })
        let kind = try XCTUnwrap(source.availableVariants.first)
        let variant = try XCTUnwrap(source.variant(kind))
        let undecorated = AppTheme(id: source.id, name: source.name, mode: source.mode,
            summary: nil, variants: [kind: variant.replacingChrome(nil)])
        let before = try render(undecorated, name: "no-chrome", kind: kind)
        let after = try render(source, name: "chrome", kind: kind)
        XCTAssertGreaterThan(try changedPixels(before, after,
            region: CGRect(x: 0, y: 0, width: 1140, height: 48)), 100)
    }

    private func render(_ theme: AppTheme, name: String, kind: AppTheme.VariantKind) throws -> CGImage {
        let image = try XCTUnwrap(AppThemePreviewService.render(theme, kinds: [kind]))
        if let output = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"] {
            let url = URL(fileURLWithPath: output).appendingPathComponent("theme-preview-\(name).png")
            try XCTUnwrap(AppThemePreviewService.pngData(image)).write(to: url)
        }
        return image
    }

    private func changedPixels(_ before: CGImage, _ after: CGImage, region: CGRect) throws -> Int {
        let a = try pixels(before, region: region), b = try pixels(after, region: region)
        return stride(from: 0, to: a.count, by: 4).filter { index in
            (0..<4).contains { a[index + $0] != b[index + $0] }
        }.count
    }

    private func pixels(_ image: CGImage, region: CGRect) throws -> [UInt8] {
        let crop = try XCTUnwrap(image.cropping(to: region))
        let context = try XCTUnwrap(CGContext(data: nil, width: crop.width, height: crop.height,
            bitsPerComponent: 8, bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        let pointer = try XCTUnwrap(context.data?.assumingMemoryBound(to: UInt8.self))
        return Array(UnsafeBufferPointer(start: pointer, count: crop.width * crop.height * 4))
    }
}

private actor PickerTestPersistence: AppearanceActivationPersisting {
    func save(_ state: AppearanceActivationState) async throws {}
}

@MainActor
final class AppThemePickerOfferTests: XCTestCase {
    private final class Availability { var reason: String? }

    private let member = "com.example.rain"
    private let digest = String(repeating: "a", count: 64)

    private func pack(_ name: String, themeID: String) -> AppearancePack {
        AppearancePack(id: UUID(), recipeRevision: UUID(), name: name, themeID: themeID,
                       extensions: [.init(identifier: member, contentDigest: digest)])
    }

    private func makeHost(_ packs: [AppearancePack], availability: Availability) -> AppearanceActivationHost {
        let member = member, digest = digest
        let inventory = {
            AppearanceActivationInventory(themeIDs: ["system", "standalone"], extensions: [
                member: .init(name: member, contentDigest: digest, unavailableReason: availability.reason,
                              requiredExtensionIDs: [], status: .running)
            ], extensionsSuppressed: false)
        }
        let state = AppearanceActivationState(standaloneThemeID: "system", manuallyEnabledExtensionIDs: [],
                                              packs: packs)
        let service = AppearanceActivationService(state: state, persistence: PickerTestPersistence(),
            inventory: inventory, reconcile: { _, _ in })
        return AppearanceActivationHost(service: service, inventory: inventory)
    }

    func testThePacksForTheSelectedThemeAppearOnceUnderTheirOwnHead() throws {
        let rain = pack("Rain", themeID: "system"), snow = pack("Snow", themeID: "standalone")
        let host = makeHost([rain, snow], availability: Availability())
        let picker = ThemedPopUp()
        AppThemePicker.populate(picker, selectedThemeID: .system, host: host)
        let entries = picker.entries
        func index(of id: UUID) -> [Int] {
            entries.indices.filter {
                if case .item(let item) = entries[$0] { return item.representedValue as? UUID == id }
                return false
            }
        }
        XCTAssertEqual(index(of: rain.id).count, 1, "an offer is not repeated in the general group")
        let row = try XCTUnwrap(index(of: rain.id).first)
        guard case .header(let head) = entries[row - 1], case .item(let offer) = entries[row] else {
            return XCTFail("the offer sits directly under a head")
        }
        XCTAssertEqual(head, L10n.format("Packs for “%@”", AppTheme.system.name))
        XCTAssertEqual(offer.title, L10n.format("Use with “%@” pack", rain.name))
        let other = try XCTUnwrap(index(of: snow.id).first)
        guard case .header(let general) = entries[other - 1] else { return XCTFail("Snow keeps its group") }
        XCTAssertEqual(general, L10n.string("Appearance packs"))
    }

    func testARefusedActivationPutsTheSelectionBack() throws {
        let rain = pack("Rain", themeID: "system")
        let availability = Availability()
        let host = makeHost([rain], availability: availability)
        var failures: [String] = []
        host.presentFailure = { failures.append($0) }
        let picker = ThemedPopUp()
        AppThemePicker.populate(picker, selectedThemeID: .system, host: host)
        picker.selectItem(at: try XCTUnwrap(picker.indexOfItem { $0.representedValue as? UUID == rain.id }))
        availability.reason = "The extension is not available."
        XCTAssertTrue(AppThemePicker.activatePackIfSelected(picker, host: host))
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(picker.selectedItem?.representedValue as? String, AppThemeID.system.rawValue,
            "the picker names the theme still in force, not a pack that is not active")
        XCTAssertNil(host.state?.activePackID)
    }
}

import XCTest
import ThinkingOrbs
@testable import Skalman

/// The tint seam added to the ThinkingOrbs fork, and the wrapper that drives it
/// from the theme accent. The claim under test is a colour claim — "the ink is
/// the accent hue, not grey" — which no assertion about the drawing math can
/// make, so it is checked against rendered pixels, the same way the
/// conversation and git-review renders are.
@MainActor
final class ThinkingOrbTintTests: XCTestCase {

    // MARK: - Helpers

    private func render(_ view: NSView, size: CGFloat = 64) -> NSBitmapImageRep {
        view.frame = NSRect(x: 0, y: 0, width: size, height: size)
        view.layoutSubtreeIfNeeded()
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// Every dot the orb actually painted (alpha above a floor), as sRGB.
    private func inkPixels(_ rep: NSBitmapImageRep) -> [NSColor] {
        var out: [NSColor] = []
        for y in stride(from: 0, to: rep.pixelsHigh, by: 1) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 1) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.15 else { continue }
                out.append(c)
            }
        }
        return out
    }

    // MARK: - The tint seam

    func testTintColoursTheInk() {
        let orb = ThinkingOrbView(state: .working, orbSize: .px64)
        orb.tint = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)

        let ink = inkPixels(render(orb))
        XCTAssertFalse(ink.isEmpty, "the orb painted nothing to sample")

        // A red tint must produce red-dominant ink: no green- or blue-dominant
        // dot can appear, and at least one clearly-red dot must.
        let reddest = ink.max { $0.redComponent < $1.redComponent }!
        XCTAssertGreaterThan(reddest.redComponent, 0.5)
        XCTAssertLessThan(reddest.greenComponent, 0.35)
        XCTAssertLessThan(reddest.blueComponent, 0.35)

        for c in ink {
            XCTAssertGreaterThanOrEqual(c.redComponent + 0.001, c.greenComponent, "green-dominant ink under a red tint")
            XCTAssertGreaterThanOrEqual(c.redComponent + 0.001, c.blueComponent, "blue-dominant ink under a red tint")
        }
    }

    /// The default (no tint) path must stay grayscale, so the mod is additive
    /// rather than a behaviour change for anyone not passing a tint.
    func testNilTintStaysGrayscale() {
        let orb = ThinkingOrbView(state: .working, orbSize: .px64, theme: .dark)
        orb.tint = nil

        let ink = inkPixels(render(orb))
        XCTAssertFalse(ink.isEmpty)

        for c in ink {
            XCTAssertEqual(c.redComponent, c.greenComponent, accuracy: 0.02, "grayscale ink drifted red/green")
            XCTAssertEqual(c.greenComponent, c.blueComponent, accuracy: 0.02, "grayscale ink drifted green/blue")
        }
    }

    // MARK: - Visual dump

    /// Writes orb PNGs for eyeballing when `SKALMAN_RENDER_OUT` points somewhere,
    /// and is a no-op otherwise — the same opt-in the conversation renders use.
    func testWriteRenderSamples() throws {
        guard let out = ProcessInfo.processInfo.environment["SKALMAN_RENDER_OUT"] else {
            throw XCTSkip("set SKALMAN_RENDER_OUT to dump orb PNGs")
        }
        let dir = URL(fileURLWithPath: out)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let tints: [(String, CGColor)] = [
            ("cyberpunk", CGColor(srgbRed: 0.36, green: 0.98, blue: 0.55, alpha: 1)),
            ("swiss-red", CGColor(srgbRed: 0.86, green: 0.13, blue: 0.15, alpha: 1)),
            ("system-blue", CGColor(srgbRed: 0.0, green: 0.48, blue: 1.0, alpha: 1))
        ]
        for (name, tint) in tints {
            for theme in [(OrbTheme.light, "light"), (OrbTheme.dark, "dark")] {
                let orb = ThinkingOrbView(state: .working, orbSize: .px64, theme: theme.0)
                orb.tint = tint
                let rep = render(orb, size: 128)
                let png = rep.representation(using: .png, properties: [:])!
                try png.write(to: dir.appendingPathComponent("orb-\(name)-\(theme.1).png"))
            }
        }
    }

    // MARK: - The wrapper

    func testWrapperPaintsAccentTintedInk() {
        let orb = WorkingOrbView()

        let ink = inkPixels(render(orb))
        XCTAssertFalse(ink.isEmpty, "the wrapper drew no orb")

        // The wrapper tints from Design.Surface.accent. Whatever the ambient
        // accent is, the drawn ink must match its hue rather than being grey —
        // proving the wrapper wired a tint through at all.
        let accent = Design.Surface.accent.usingColorSpace(.sRGB)!
        let grey = abs(accent.redComponent - accent.greenComponent) < 0.02
            && abs(accent.greenComponent - accent.blueComponent) < 0.02
        guard !grey else {
            // A genuinely grey accent (some CI appearances) makes the hue
            // assertion vacuous; the non-empty draw above is the real check.
            return
        }

        let colouredInk = ink.contains { c in
            abs(c.redComponent - c.greenComponent) > 0.03 || abs(c.greenComponent - c.blueComponent) > 0.03
        }
        XCTAssertTrue(colouredInk, "wrapper ink is grey despite a coloured accent — tint not applied")
    }

    func testWrapperCanDisplayEveryVariant() {
        XCTAssertEqual(
            OrbState.allCases.map { WorkingOrbView(state: $0).state },
            OrbState.allCases
        )
    }

    func testRandomVariantStaysStableUntilSelectedAgainAndDoesNotRepeat() {
        let orb = WorkingOrbView()

        orb.selectRandomVariant(choosingIndex: { _ in 0 })
        let first = orb.state
        XCTAssertEqual(first, .working)

        // The second candidate list excludes the current state. Choosing its
        // first entry therefore proves consecutive turns cannot repeat.
        orb.selectRandomVariant(choosingIndex: { _ in 0 })
        XCTAssertNotEqual(orb.state, first)
    }

    func testEveryFixedOrbPreferenceSelectsItsMatchingVariant() {
        let orb = WorkingOrbView()

        for style in WorkingOrbStyle.allCases where style != .random {
            orb.prepareForWorking(style: style)
            XCTAssertEqual(orb.state.rawValue, style.rawValue)
        }
    }

    func testMotionPreferencesDefaultAndPersist() throws {
        let suiteName = "ThinkingOrbTintTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.workingOrbStyle, .random)
        XCTAssertEqual(settings.chatNameMorphStyle, .shapeMorph)

        settings.workingOrbStyle = .shaping
        settings.chatNameMorphStyle = .scramble
        XCTAssertEqual(settings.workingOrbStyle, .shaping)
        XCTAssertEqual(settings.chatNameMorphStyle, .scramble)
    }

    func testAttachmentDetectionDefaultsOnAndCanBeDisabledPerAgent() throws {
        let suiteName = "AttachmentDetectionSettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(settings.detectsAttachmentReferences(for: .claude))
        XCTAssertTrue(settings.detectsAttachmentReferences(for: .codex))

        settings.setAttachmentReferenceDetection(for: .claude, enabled: false)
        XCTAssertFalse(settings.detectsAttachmentReferences(for: .claude))
        XCTAssertTrue(settings.detectsAttachmentReferences(for: .codex))

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertFalse(reloaded.detectsAttachmentReferences(for: .claude))
        XCTAssertTrue(reloaded.detectsAttachmentReferences(for: .codex))

        reloaded.setAttachmentReferenceDetection(for: .codex, enabled: false)
        reloaded.setAttachmentReferenceDetection(for: .claude, enabled: true)
        XCTAssertTrue(reloaded.detectsAttachmentReferences(for: .claude))
        XCTAssertFalse(reloaded.detectsAttachmentReferences(for: .codex))
    }

    func testTerminalAttachmentObserverStopsAndRestartsWithItsAgentSetting() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let first = root.appendingPathComponent("first.png")
        let second = root.appendingPathComponent("second.pdf")
        try Data("png".utf8).write(to: first)
        try Data("%PDF".utf8).write(to: second)

        let sessionID = SessionID()
        var isEnabled = false
        var renderedText = first.path
        let observer = TerminalAttachmentObserver(
            sessionID: sessionID,
            projectRoot: { root },
            currentDirectory: { root },
            text: { renderedText },
            isEnabled: { isEnabled }
        )

        observer.scanNow()
        XCTAssertEqual(SessionAttachmentStore.shared.attachments(for: sessionID), [])

        isEnabled = true
        observer.scanNow()
        XCTAssertEqual(
            SessionAttachmentStore.shared.attachments(for: sessionID).map(\.relativePath),
            ["first.png"]
        )

        isEnabled = false
        renderedText = second.path
        observer.scanNow()
        XCTAssertEqual(
            SessionAttachmentStore.shared.attachments(for: sessionID).map(\.relativePath),
            ["first.png"]
        )

        isEnabled = true
        observer.scanNow()
        XCTAssertEqual(
            SessionAttachmentStore.shared.attachments(for: sessionID).map(\.relativePath),
            ["second.pdf", "first.png"]
        )
    }

    func testMorphingTitleAcceptsEverySelectableStyle() {
        let label = MorphingTitleLabel()
        label.setStringValue("Before", animated: false)

        for style in ChatNameMorphStyle.allCases {
            label.morphStyleOverride = style
            label.setStringValue("After \(style.displayName)", animated: true)
            XCTAssertEqual(label.morphStyleOverride, style)
            XCTAssertEqual(label.stringValue, "After \(style.displayName)")
        }
    }

    func testMotionPreferencesPageLaysOutWithinThemeBoundary() {
        let controller = MotionPreferencesViewController()
        _ = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: 620, height: 680)
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertFalse(controller.view.hasAmbiguousLayout)
        XCTAssertEqual(ThemeBoundaryAudit.violations(in: controller.view), [])
    }
}

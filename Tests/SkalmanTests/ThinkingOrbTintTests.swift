import XCTest
import ThinkingOrbs
@testable import Skalman

/// The tint seam added to the ThinkingOrbs fork, and the wrapper that drives it
/// from the theme accent. The claim under test is a colour claim — "the ink is
/// the accent hue, not grey" — which no assertion about the drawing math can
/// make, so it is checked against rendered pixels, the same way the
/// conversation and git-review renders are.
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
}

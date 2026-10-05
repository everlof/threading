import AppKit
import XCTest
@testable import Threading

@MainActor
final class GlyphContrastTests: XCTestCase {
    func testTemplateInkClearsItsFloorIncludingTransparentInkAndMidtoneGrounds() throws {
        let green = try XCTUnwrap(NSColor(hex: "#00FF41"))
        for (ink, ground) in [
            (NSColor.white, green),
            (green, green),
            (.white.withAlphaComponent(0.1), .black),
            (.black.withAlphaComponent(0.1), .white),
            (NSColor(white: 0.5, alpha: 1), NSColor(white: 0.5, alpha: 1)),
        ] {
            let glyph = makeGlyph(tint: ink)
            glyph.contrastGround = { ground }
            let pixel = try render(glyph, over: ground)
            XCTAssertGreaterThanOrEqual(ThemeContrast.ratio(pixel, ground), 3, "\(ink) over \(ground)")
            XCTAssertEqual(glyph.tint, ink, "Measuring must not overwrite the authored tint")
        }
    }

    func testLegibleTintAndFinishedArtworkKeepTheirPixels() throws {
        let green = try XCTUnwrap(NSColor(hex: "#00FF41"))
        let glyph = makeGlyph(tint: .black)
        let original = try render(glyph, over: green)
        glyph.contrastGround = { green }
        XCTAssertEqual(try render(glyph, over: green), original)

        glyph.image?.isTemplate = false
        glyph.tint = .white
        glyph.contrastGround = nil
        let artwork = try render(glyph, over: .black)
        glyph.contrastGround = { .black }
        XCTAssertEqual(try render(glyph, over: .black), artwork)
    }

    func testRetainedGlyphRemeasuresWhenItsGroundChanges() throws {
        var ground = NSColor.black
        let glyph = makeGlyph(tint: .white)
        glyph.contrastGround = { ground }
        XCTAssertGreaterThan(ThemeContrast.ratio(try render(glyph, over: ground), ground), 20)
        ground = .white
        XCTAssertGreaterThanOrEqual(ThemeContrast.ratio(try render(glyph, over: ground), ground), 3)
        ground = .black
        XCTAssertGreaterThan(ThemeContrast.ratio(try render(glyph, over: ground), ground), 20)
    }

    func testIncreaseContrastRemeasuresTheSameColorPair() throws {
        let previous = Design.Accessibility.increaseContrastOverrideForTesting
        defer { Design.Accessibility.increaseContrastOverrideForTesting = previous }
        let ground = try XCTUnwrap(NSColor(hex: "#00FF41"))
        let glyph = makeGlyph(tint: .white)
        glyph.contrastGround = { ground }
        Design.Accessibility.increaseContrastOverrideForTesting = false
        let ordinary = try render(glyph, over: ground)
        Design.Accessibility.increaseContrastOverrideForTesting = true
        XCTAssertGreaterThanOrEqual(ThemeContrast.ratio(try render(glyph, over: ground), ground), 4.5)
        Design.Accessibility.increaseContrastOverrideForTesting = false
        XCTAssertEqual(try render(glyph, over: ground), ordinary)
    }

    private func makeGlyph(tint: NSColor) -> GlyphView {
        let glyph = GlyphView()
        glyph.frame = NSRect(x: 0, y: 0, width: 24, height: 24)
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            NSColor.black.setFill()
            rect.fill()
            return true
        }
        image.isTemplate = true
        glyph.image = image
        glyph.tint = tint
        return glyph
    }

    private func render(_ glyph: GlyphView, over ground: NSColor) throws -> NSColor {
        let host = NSView(frame: glyph.frame)
        host.wantsLayer = true
        host.layer?.backgroundColor = ground.cgColor
        host.addSubview(glyph)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds)?.retagging(with: .sRGB))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        // colorAt returns a calibrated color even for an sRGB bitmap. Read the channels in
        // the capture's stated space instead of silently applying a second profile conversion.
        var pixel = [Int](repeating: 0, count: bitmap.samplesPerPixel)
        bitmap.getPixel(&pixel, atX: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)
        return NSColor(srgbRed: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255,
                       blue: CGFloat(pixel[2]) / 255, alpha: CGFloat(pixel[3]) / 255)
    }
}

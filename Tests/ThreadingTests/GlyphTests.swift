import AppKit
import XCTest
@testable import Threading

/// The chrome's glyphs, checked the way the rules are: against what is actually put on screen.
///
/// Two invariants. A glyph is *configured* to fit its slot, never rendered and then shrunk —
/// the shrink thins the stroke below what the configuration chose and drops it off the pixel
/// grid. And a glyph's stroke weighs what the text beside it weighs: the anchor is the body
/// face's stem, measured off a raster rather than assumed, because "looks light" is a number.
@MainActor
final class GlyphTests: XCTestCase {

    // MARK: - Raster Measurement

    /// The median ink-run width across a drawing, at 8× so a quarter point is measurable.
    /// The median rather than the maximum: a `+`'s crossing or a serif would otherwise decide.
    private func inkRunWidth(_ draw: (NSRect) -> Void) throws -> CGFloat {
        let scale: CGFloat = 8
        let canvas = NSSize(width: 32, height: 32)
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(canvas.width * scale),
            pixelsHigh: Int(canvas.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        rep.size = canvas

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: canvas).fill()
        draw(NSRect(origin: NSPoint(x: 8, y: 8), size: canvas))
        NSGraphicsContext.restoreGraphicsState()

        var runs: [Int] = []
        for y in 0..<rep.pixelsHigh {
            var run = 0
            var widest = 0
            for x in 0..<rep.pixelsWide {
                let dark = (rep.colorAt(x: x, y: y)?.brightnessComponent ?? 1) < 0.5
                if dark {
                    run += 1
                    widest = max(widest, run)
                } else {
                    run = 0
                }
            }
            if widest > 0 { runs.append(widest) }
        }
        let sorted = runs.sorted()
        return sorted.isEmpty ? 0 : CGFloat(sorted[sorted.count / 2]) / scale
    }

    private func strokeOfPlus(_ configuration: NSImage.SymbolConfiguration) throws -> CGFloat {
        let image = try XCTUnwrap(
            NSImage(systemSymbolName: "plus", accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration)
        )
        return try inkRunWidth { origin in
            image.draw(in: NSRect(origin: origin.origin, size: image.size))
        }
    }

    private func stemOfBody() throws -> CGFloat {
        let font = Design.Typography.body()
        return try inkRunWidth { origin in
            ("l" as NSString).draw(
                at: origin.origin,
                withAttributes: [.font: font, .foregroundColor: NSColor.black]
            )
        }
    }

    // MARK: - Stroke Weight

    /// The window's ink weights agree by measurement: the default symbol configuration strokes
    /// within a quarter point of the body text's stem. `.regular` sat a full step under it —
    /// every icon lighter than its own label, and a single antialiased pixel on a 1× display.
    func testTheDefaultGlyphStrokeMatchesTheBodyTextStem() throws {
        let stem = try stemOfBody()
        let stroke = try strokeOfPlus(Design.Symbol.configuration(Design.Symbol.control))
        XCTAssertEqual(
            stroke, stem, accuracy: 0.3,
            "an icon's stroke (\(stroke)) drifted from the text stem (\(stem)) it sits beside"
        )
    }

    // MARK: - Slot Fitting

    /// Every symbol the chrome states, at both roles' slots: the *rendered* size fits, so no
    /// image view ever scales a finished render. `gearshape` (14×14 at the 11pt configuration)
    /// and the sidebar's arrange glyph (15×14) are the cases that used to overflow the 12pt
    /// inline slot and arrive shrunk by a fifth.
    func testAConfiguredSymbolFitsItsSlotWithoutARescale() throws {
        let chromeSymbols = [
            "plus", "gearshape", "xmark", "ellipsis", "chevron.left", "chevron.right",
            "sidebar.leading", "paintbrush.pointed", SidebarDefaults.arrangementSymbol
        ]
        let roles: [(slot: CGFloat, pointSize: CGFloat)] = [
            (Design.Size.inlineButtonGlyph, Design.Symbol.control),
            (Design.Size.tabIconSlot, Design.Symbol.toolbar)
        ]
        for symbol in chromeSymbols {
            for role in roles {
                let image = try XCTUnwrap(
                    Design.Symbol.image(symbol, slot: role.slot, pointSize: role.pointSize),
                    "\(symbol) did not resolve"
                )
                XCTAssertLessThanOrEqual(
                    max(image.size.width, image.size.height), role.slot + 0.01,
                    "\(symbol) overflows a \(role.slot)pt slot — it will be shrunk after render"
                )
            }
        }
    }

    /// Fitting only ever configures *down*: a symbol already inside the slot keeps the nominal
    /// point size, so a `plus` and a `gearshape` in the same row differ only where SF's own
    /// optical sizing says they should.
    func testFittingNeverGrowsASymbolPastItsNominalSize() throws {
        let nominal = try XCTUnwrap(
            NSImage(systemSymbolName: "plus", accessibilityDescription: nil)?
                .withSymbolConfiguration(Design.Symbol.configuration(Design.Symbol.control))
        )
        let fitted = try XCTUnwrap(
            Design.Symbol.image("plus", slot: 40, pointSize: Design.Symbol.control)
        )
        XCTAssertEqual(fitted.size, nominal.size, "a roomy slot inflated the glyph")
    }

    // MARK: - GlyphView

    /// The view is sized by its artwork — or by the slot cap when the artwork is not ours,
    /// which is what keeps an installed app's icon from exploding a 20pt button.
    func testGlyphViewIntrinsicSizeIsTheArtworksUnlessCapped() {
        let view = GlyphView()
        let image = NSImage(size: NSSize(width: 64, height: 32))
        view.image = image
        XCTAssertEqual(view.intrinsicContentSize, image.size)

        view.slot = NSSize(width: 16, height: 16)
        XCTAssertEqual(view.intrinsicContentSize, NSSize(width: 16, height: 16))
    }

    /// A template glyph draws in the tint it is handed — the whole reason the view exists is
    /// to be `contentTintColor` minus the fractional placement.
    func testGlyphViewDrawsATemplateImageInItsTint() throws {
        let view = GlyphView()
        view.frame = NSRect(x: 0, y: 0, width: 16, height: 16)
        let square = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            NSColor.black.setFill()
            rect.fill()
            return true
        }
        square.isTemplate = true
        view.image = square
        view.tint = .systemRed

        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let centre = try XCTUnwrap(
            rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB)
        )
        let tint = try XCTUnwrap(NSColor.systemRed.usingColorSpace(.sRGB))
        XCTAssertEqual(centre.redComponent, tint.redComponent, accuracy: 0.02)
        XCTAssertEqual(centre.greenComponent, tint.greenComponent, accuracy: 0.02)
        XCTAssertEqual(centre.blueComponent, tint.blueComponent, accuracy: 0.02)
    }

    /// Decorative by construction — the control around it carries the name, the same split
    /// `SeparatorView` states.
    func testGlyphViewIsNotAnAccessibilityElement() {
        XCTAssertFalse(GlyphView().isAccessibilityElement())
    }
}

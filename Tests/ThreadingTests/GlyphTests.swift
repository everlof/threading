import AppKit
import XCTest
@testable import Threading

/// The chrome's glyphs, checked the way the rules are: against what is actually put on screen.
///
/// Three invariants. A glyph is *configured* to fit its slot, never rendered and then shrunk —
/// the shrink thins the stroke below what the configuration chose and drops it off the pixel
/// grid. A glyph's stroke weighs what the text beside it weighs: the anchor is the body face's
/// stem, measured off a raster rather than assumed, because "looks light" is a number. And a
/// slot is a box a mark sits in, never a shape it is stretched into.
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

    /// The bounding box of everything a drawing inks, in points, in the drawing's own space.
    private func inkBounds(canvas: NSSize, _ draw: (NSRect) -> Void) throws -> NSRect {
        let scale: CGFloat = 8
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
        draw(NSRect(origin: .zero, size: canvas))
        NSGraphicsContext.restoreGraphicsState()

        var minX = rep.pixelsWide, maxX = -1
        var minY = rep.pixelsHigh, maxY = -1
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide
            where (rep.colorAt(x: x, y: y)?.brightnessComponent ?? 1) < 0.5 {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return .zero }

        // The rep's rows run top-down and the drawing's do not, so the box is flipped back into
        // the space of the slot it will be compared against.
        return NSRect(
            x: CGFloat(minX) / scale,
            y: CGFloat(rep.pixelsHigh - 1 - maxY) / scale,
            width: CGFloat(maxX - minX + 1) / scale,
            height: CGFloat(maxY - minY + 1) / scale
        )
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

    // MARK: - Slot Proportions

    /// A slot is a box to sit in, not a shape to become. `folder` renders 18×14, so a square slot
    /// that scales each axis independently squeezes it a ninth narrow and pulls it a seventh
    /// tall — which is what the sidebar's add-project menu was drawing.
    func testAWideMarkIsFittedIntoASquareSlotRatherThanStretchedToIt() {
        let wide = NSImage(size: NSSize(width: 18, height: 14))
        let slot = NSRect(x: 10, y: 20, width: 16, height: 16)
        let rect = TemplateImageDrawing.fitted(wide, in: slot)

        XCTAssertEqual(rect.width, slot.width, accuracy: 0.001, "the fit did not use the slot")
        XCTAssertEqual(
            rect.height, slot.width * 14 / 18, accuracy: 0.001,
            "the mark's proportions did not survive its slot"
        )
        XCTAssertEqual(rect.midX, slot.midX, accuracy: 0.001)
        XCTAssertEqual(
            rect.midY, slot.midY, accuracy: 0.001,
            "a short glyph settled off the centre of the slot it was allotted"
        )
    }

    /// Fitted, not capped: correcting the aspect ratio never also shrinks a mark below the
    /// footprint its caller measured a layout around.
    func testFittingFillsTheSlotOnTheAxisThatConstrainsIt() {
        let small = NSImage(size: NSSize(width: 4, height: 8))
        let rect = TemplateImageDrawing.fitted(
            small,
            in: NSRect(x: 0, y: 0, width: 16, height: 16)
        )
        XCTAssertEqual(rect.height, 16, accuracy: 0.001)
        XCTAssertEqual(rect.width, 8, accuracy: 0.001)
    }

    /// Measured off the pixels rather than the geometry, because the stretch happened inside
    /// `NSImage.draw(in:)` — which is where every component in the design system ends up.
    func testADrawnGlyphScalesBothItsAxesByTheSameAmount() throws {
        let canvas = NSSize(width: 40, height: 40)
        // `ellipsis` is three dots on one line, about four times wider than it is tall, so a
        // square slot deforms it further than any measurement error could account for.
        let image = try XCTUnwrap(
            NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)?
                .withSymbolConfiguration(Design.Symbol.configuration(Design.Symbol.toolbar))
        )

        let natural = try inkBounds(canvas: canvas) { _ in
            image.draw(in: NSRect(origin: .zero, size: image.size))
        }
        let fitted = try inkBounds(canvas: canvas) { slot in
            TemplateImageDrawing.draw(image, in: slot, tint: .black)
        }
        XCTAssertGreaterThan(natural.width, 0)
        XCTAssertGreaterThan(natural.height, 0)

        XCTAssertEqual(
            fitted.width / natural.width,
            fitted.height / natural.height,
            accuracy: 0.1,
            "the slot scaled the glyph's axes by different amounts — it stretched it"
        )

        // The fixture proves something only if the un-fitted draw it replaced fails it.
        let stretched = try inkBounds(canvas: canvas) { slot in image.draw(in: slot) }
        XCTAssertGreaterThan(
            abs(stretched.width / natural.width - stretched.height / natural.height), 1,
            "drawing straight into the slot no longer deforms the glyph, so this test is blind"
        )
    }

    /// A menu row's mark goes through `ThemedMenuIcon`, which resolves it at the menu's own size
    /// and weight. A raw `NSImage(systemSymbolName:)` arrives at whatever size the system hands
    /// out — larger than the slot — and is then scaled down from a finished render.
    func testAMenuRowsMarkIsResolvedAtTheMenusOwnSize() throws {
        let slot = ThemedMenuMetrics.imageSize
        for symbol in ["plus", "folder", "terminal", "globe", "paperclip", "puzzlepiece.extension"] {
            let mark = try XCTUnwrap(ThemedMenuIcon.symbol(symbol), "\(symbol) did not resolve")
            XCTAssertLessThanOrEqual(
                max(mark.size.width, mark.size.height), slot + 0.01,
                "\(symbol) overflows the menu's \(slot)pt slot — it will be rescaled after render"
            )
        }

        let raw = try XCTUnwrap(NSImage(systemSymbolName: "folder", accessibilityDescription: nil))
        XCTAssertGreaterThan(
            max(raw.size.width, raw.size.height), slot,
            "an unconfigured system symbol already fits the menu's slot — this test proves nothing"
        )
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

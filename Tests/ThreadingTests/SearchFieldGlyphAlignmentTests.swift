import AppKit
import XCTest
@testable import Threading

/// The magnifier sits on the query's own optical centre.
///
/// The field's cell centres a rect of the font's *bounding* height, which reaches further below
/// the baseline than any letter does — so the visible words sit above the field's geometric
/// middle, by more the further a themed face's metrics stray from the system's. A glyph centred
/// on `bounds.midY` therefore drew visibly below the text beside it, which is what "vertical
/// alignment with the magnifier is broken" looked like in the settings sidebar. Checked on drawn
/// pixels rather than on the constants that were meant to produce it, per the design-system rule.
@MainActor
final class SearchFieldGlyphAlignmentTests: XCTestCase {

    override func tearDown() {
        AppThemePalette.set(.system)
        super.tearDown()
    }

    func testMagnifierCentresOnThePlaceholdersInkUnderSystemAndAStyledTheme() throws {
        try assertGlyphAlignment(theme: .system, name: "system")
        try assertGlyphAlignment(theme: AppThemeStyles.cyberpunk, name: "cyberpunk")
    }

    private func assertGlyphAlignment(theme: AppTheme, name: String) throws {
        AppThemePalette.set(theme)
        let appearance = try XCTUnwrap(NSAppearance(named: .aqua))

        var glyphCentre: CGFloat?
        var textCentre: CGFloat?
        var scale: CGFloat = 1

        appearance.performAsCurrentDrawingAppearance {
            let field = ThemedSearchField(frame: NSRect(x: 0, y: 0, width: 320, height: 0))
            // No descenders on purpose: the ink's vertical centre is then the cap centre the
            // glyph is aligned to, so the two centroids may be compared directly.
            field.placeholderString = "HHHHHHHH"
            field.frame.size.height = field.intrinsicContentSize.height
            field.layoutSubtreeIfNeeded()

            guard let rep = field.bitmapImageRepForCachingDisplay(in: field.bounds) else { return }
            field.cacheDisplay(in: field.bounds, to: rep)

            scale = CGFloat(rep.pixelsHigh) / field.bounds.height
            // The magnifier's slot starts a small step in and is a control-mark wide; the text
            // begins after the glyph inset. Generous, non-overlapping zones cover both without
            // reading the field's private layout. The border rows are skipped on every side.
            glyphCentre = Self.inkCentroidY(
                in: rep,
                columns: Int(2 * scale)...Int(17 * scale),
                edgeInset: Int(3 * scale)
            )
            textCentre = Self.inkCentroidY(
                in: rep,
                columns: Int(24 * scale)...(rep.pixelsWide - Int(8 * scale)),
                edgeInset: Int(3 * scale)
            )
        }

        let glyph = try XCTUnwrap(glyphCentre, "no magnifier ink found under \(name)")
        let text = try XCTUnwrap(textCentre, "no placeholder ink found under \(name)")
        XCTAssertLessThanOrEqual(
            abs(glyph - text) / scale,
            2.0,
            "the magnifier's ink centre should sit on the text's under \(name)"
        )
    }

    /// The ink-weighted vertical centre of everything in the given columns that is not the
    /// field's own background, in the rep's pixel space.
    private static func inkCentroidY(
        in rep: NSBitmapImageRep,
        columns: ClosedRange<Int>,
        edgeInset: Int
    ) -> CGFloat? {
        // The well's own fill, sampled mid-height just inside the trailing edge — clear of the
        // border rows, the glyph, and a placeholder that begins at the leading inset.
        guard let sampled = rep.colorAt(x: rep.pixelsWide - edgeInset * 2, y: rep.pixelsHigh / 2),
              let background = sampled.usingColorSpace(.deviceRGB) else { return nil }

        var weighted: CGFloat = 0
        var count: CGFloat = 0
        for x in columns where x >= 0 && x < rep.pixelsWide {
            for y in edgeInset..<(rep.pixelsHigh - edgeInset) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                let distance = abs(color.redComponent - background.redComponent)
                    + abs(color.greenComponent - background.greenComponent)
                    + abs(color.blueComponent - background.blueComponent)
                guard distance > 0.25 else { continue }
                weighted += CGFloat(y)
                count += 1
            }
        }
        guard count > 0 else { return nil }
        return weighted / count
    }
}

import AppKit

/// Draws app-owned image content without letting template tint leak into the surface beneath it.
///
/// Filling a template image with `.sourceAtop` directly in a view's backing context also sees
/// the panel or control already drawn under the image. The fill then paints the image's entire
/// bounding box as a solid square. An isolated transparency layer limits the destination alpha
/// to the glyph itself, so every design-system component gets the same clean symbol silhouette.
enum TemplateImageDrawing {

    static func draw(_ image: NSImage, in rect: NSRect, tint: NSColor) {
        guard image.isTemplate, let context = NSGraphicsContext.current?.cgContext else {
            image.draw(in: rect)
            return
        }

        context.saveGState()
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        image.draw(in: rect)
        tint.set()
        // `.sourceIn`, not `.sourceAtop`: the template's own artwork is **black**, and atop keeps
        // whatever the tint's alpha does not cover — so a tint below full opacity was blended
        // into that black instead of over the ground, and could never reach the colour it asked
        // for. Every ink tier below `label` is an alpha (`Design.Ink` is "the base at an
        // opacity"), so this was every secondary glyph in the window quietly drawn dark: white at
        // 70% came out an opaque 70% grey whatever it stood on. `.sourceIn` keeps the silhouette
        // and replaces its colour, alpha included, leaving the transparency layer to composite it
        // over the ground the way the ink was measured against. An opaque tint is unaffected.
        rect.fill(using: .sourceIn)
        context.endTransparencyLayer()
        context.restoreGState()
    }
}

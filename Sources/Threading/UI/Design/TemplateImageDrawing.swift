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
        rect.fill(using: .sourceAtop)
        context.endTransparencyLayer()
        context.restoreGState()
    }
}

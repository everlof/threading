import AppKit

/// Draws app-owned image content without letting template tint leak into the surface beneath it.
///
/// Filling a template image with `.sourceAtop` directly in a view's backing context also sees
/// the panel or control already drawn under the image. The fill then paints the image's entire
/// bounding box as a solid square. An isolated transparency layer limits the destination alpha
/// to the glyph itself, so every design-system component gets the same clean symbol silhouette.
enum TemplateImageDrawing {

    /// The rect an image actually draws into when it is handed `slot`: the largest rect with the
    /// image's own proportions that fits, centred.
    ///
    /// **A slot is a box to sit in, not a shape to become.** `NSImage.draw(in:)` scales to the
    /// rect it is given on each axis independently, and an SF Symbol is square only by
    /// coincidence — `folder` renders 18×14 and `ellipsis` about four times wider than it is
    /// tall. Every caller here hands over a square slot, so each one was quietly deforming its
    /// glyph: the sidebar's add-project menu drew a folder squeezed a ninth narrow and stretched
    /// a seventh tall, which is what "these icons look broken and dragged out" was. Fitting costs
    /// nothing for the square symbols and is the only thing that is right for the rest.
    ///
    /// Fitted rather than capped: the slot stays the size the caller measured its layout around,
    /// so correcting the aspect ratio never also shrinks a mark. Only the axis that was being
    /// over-stretched moves.
    static func fitted(_ image: NSImage, in slot: NSRect) -> NSRect {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return slot }

        let scale = min(slot.width / size.width, slot.height / size.height)
        let fitted = NSSize(width: size.width * scale, height: size.height * scale)
        // Centred in the slot it was allotted, so a wide-and-short glyph sits where a square one
        // would rather than hugging the slot's leading edge.
        return NSRect(
            x: slot.midX - fitted.width / 2,
            y: slot.midY - fitted.height / 2,
            width: fitted.width,
            height: fitted.height
        )
    }

    static func draw(_ image: NSImage, in slot: NSRect, tint: NSColor) {
        let rect = fitted(image, in: slot)
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
        // The whole slot rather than the fitted rect: `.sourceIn` multiplies by the layer's own
        // alpha, so filling wider paints nothing extra — but a glyph antialiases a fraction of a
        // point past the rect it was drawn in, and those edge pixels would otherwise keep the
        // template's black.
        slot.fill(using: .sourceIn)
        context.endTransparencyLayer()
        context.restoreGState()
    }
}

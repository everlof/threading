import AppKit

/// A tinted glyph drawn on the device pixel grid, replacing `NSImageView` inside app-owned
/// controls.
///
/// An image view centres its image wherever the arithmetic lands, and a symbol's natural size
/// is fractional by design — so every glyph in the chrome sat at a half-point offset, which a
/// 2× display renders as slight softness and a 1× display as a smeared stroke. This view
/// centres the same rect and then aligns it to the *backing store* before drawing
/// (`backingAlignedRect`), trading up to a device pixel of size — invisible in a vector
/// re-render — for edges that land on pixels.
///
/// Drawing goes through `TemplateImageDrawing`, so a template image takes `tint` exactly the
/// way `contentTintColor` would, minus the placement it got wrong; non-template artwork (an
/// application's own icon) keeps its colours.
///
/// Decorative by construction: the control or row around it carries the accessible name, the
/// same split `SeparatorView` states.
final class GlyphView: NSView {

    /// The artwork. Natural size is the view's intrinsic size unless `slot` caps it.
    var image: NSImage? {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    /// What a template image is filled with. Non-template images ignore it.
    ///
    /// No default colour on purpose — the host's ink is the only right answer, and a stated
    /// fallback here would be a second, wrong one (the boundary lint agrees). Until the host's
    /// first `applyInk`, a template draws as itself, which is never on screen.
    var tint: NSColor? {
        didSet { needsDisplay = true }
    }

    /// A cap for artwork whose natural size is not ours to choose — an installed app's icon
    /// arrives at whatever LaunchServices holds. A symbol should not need one: it is sized by
    /// its configuration (`Design.Symbol.image(_:slot:pointSize:)`), not squeezed after.
    var slot: NSSize? {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        guard let image else { return .zero }
        guard let slot else { return image.size }
        return NSSize(
            width: min(image.size.width, slot.width),
            height: min(image.size.height, slot.height)
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let image, image.size.width > 0, image.size.height > 0 else { return }

        var size = image.size
        if let slot {
            // Aspect-fit, only ever downward — the slot is a cap, not a target.
            let fit = min(1, min(slot.width / size.width, slot.height / size.height))
            size = NSSize(width: size.width * fit, height: size.height * fit)
        }
        let centred = NSRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        // Inward, not nearest: nearest can push an edge past `bounds` by a fraction of a
        // pixel, and a view clips its own drawing — the snap that fixed one soft edge would
        // shave another. Inward stays inside the centred rect by construction.
        let aligned = backingAlignedRect(centred, options: .alignAllEdgesInward)
        if let tint {
            TemplateImageDrawing.draw(image, in: aligned, tint: tint)
        } else {
            image.draw(in: aligned)
        }
    }
}

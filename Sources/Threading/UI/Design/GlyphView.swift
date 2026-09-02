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
public final class GlyphView: NSView {

    /// The artwork. Natural size is the view's intrinsic size unless `slot` caps it.
    public var image: NSImage? {
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
    public var tint: NSColor? {
        didSet { needsDisplay = true }
    }

    /// A cap for artwork whose natural size is not ours to choose — an installed app's icon
    /// arrives at whatever LaunchServices holds. A symbol should not need one: it is sized by
    /// its configuration (`Design.Symbol.image(_:slot:pointSize:)`), not squeezed after.
    public var slot: NSSize? {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    /// The symbol this view is showing, held as the **request** rather than the render.
    ///
    /// A rendered `NSImage` freezes its configuration the way an `NSFont` freezes on a label,
    /// and a mark's optical size follows the chrome's type scale (`Design.Symbol.Role`), so a
    /// view that only ever stored the finished picture kept the size the theme was showing when
    /// it was built. Every glyph in the chrome comes through here, which is why the answer lives
    /// here rather than at fifteen call sites: `rederiveThemedContent` re-renders it, and the
    /// app-theme sweep already calls that beside the fonts and colours it re-resolves.
    private struct SymbolRequest {
        let name: String
        /// The layout cap, when layout states one. Nil where the mark's own optical size is the
        /// whole answer — a grip in a rail is as big as it is — so the cap moves with it rather
        /// than clamping it back to the size the previous theme drew.
        let slot: CGFloat?
        let role: Design.Symbol.Role
        let weight: NSFont.Weight
    }

    private var symbolRequest: SymbolRequest?

    public init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(false)
    }

    /// Shows `name` at a mark's size, re-rendered whenever the theme moves the type it is
    /// weighed against. The route for every SF Symbol in an app-owned control; assigning
    /// `image` directly stays right for artwork that is not ours (an app's own icon).
    public func setSymbol(
        _ name: String,
        slot: CGFloat? = nil,
        role: Design.Symbol.Role = .control,
        weight: NSFont.Weight = .medium
    ) {
        symbolRequest = SymbolRequest(name: name, slot: slot, role: role, weight: weight)
        renderSymbol()
    }

    /// Empties the slot, and forgets the request with it — a view handed real artwork or
    /// nothing at all must not have a stale symbol re-rendered under it by the next sweep.
    public func clearSymbol() {
        symbolRequest = nil
    }

    private func renderSymbol() {
        guard let request = symbolRequest else { return }
        let pointSize = request.role.pointSize
        image = Design.Symbol.image(
            request.name,
            slot: request.slot ?? pointSize,
            pointSize: pointSize,
            weight: request.weight
        )
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override var intrinsicContentSize: NSSize {
        guard let image else { return .zero }
        guard let slot else { return image.size }
        return NSSize(
            width: min(image.size.width, slot.width),
            height: min(image.size.height, slot.height)
        )
    }

    public override func draw(_ dirtyRect: NSRect) {
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

// MARK: - Theme

extension GlyphView: ThemeDerivedContent {

    /// Renders the held symbol again at the size its role resolves to now.
    ///
    /// A glyph is the one piece of themed content that is neither a colour nor a font and
    /// freezes like both: `Design.Symbol.image` *configures* a symbol at a point size, and the
    /// point size follows the chrome's type scale. Without this a theme switch redrew a 0.80×
    /// label beside the mark the previous theme had rendered.
    public func rederiveThemedContent() {
        renderSymbol()
    }
}

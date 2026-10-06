import CoreGraphics
import ThreadingExtensionKit

/// Regions of a host surface a backdrop should design around, in the plane's own coordinates.
///
/// The composer's prompt and hero are where the person reads and types; a backdrop that knows
/// where they are can frame them — part the rain around the box, light the greeting — instead of
/// guessing from the pane's size. Empty (`.zero` rects) means the placement exposes none.
///
/// A Metal surface reads them as `ThreadingSurfaceUniforms.focus`: `primary` is `focus[0]` and
/// `secondary` is `focus[1]` (`ExtensionMetalSource.FocusRegion`), each `(x, y, width, height)`
/// in the fragment's `uv` space.
struct ExtensionSurfaceFocus: Equatable {
    /// The primary region: the composer's hero (its mark over the greeting).
    var primary: CGRect = .zero
    /// The secondary region: the composer's prompt box.
    var secondary: CGRect = .zero

    /// The rect in each `focus` slot, in slot order.
    var regions: [CGRect] {
        ExtensionMetalSource.FocusRegion.allCases.map { region in
            switch region {
            case .primary: primary
            case .secondary: secondary
            }
        }
    }

    /// Whether a rect states a region: finite and non-empty. Anything else reaches the shader as
    /// zeros, which is how a shader is told the region does not exist.
    static func isRegion(_ rect: CGRect) -> Bool {
        !rect.isEmpty && !rect.isInfinite
            && [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite)
    }

    /// The same regions restated through `transform`, every empty one kept empty: converting
    /// `.zero` between views would otherwise invent an origin for a region that does not exist.
    func mapped(_ transform: (CGRect) -> CGRect) -> ExtensionSurfaceFocus {
        ExtensionSurfaceFocus(
            primary: Self.isRegion(primary) ? transform(primary) : .zero,
            secondary: Self.isRegion(secondary) ? transform(secondary) : .zero
        )
    }

    /// The regions as the shader's `focus` floats: per slot `(x, y, width, height)` normalized
    /// against `bounds` into the surface's `uv` space — origin at the top-left corner, y
    /// downward, `0…1` across — whichever way the view's own coordinates run. A region reaching
    /// past the surface keeps its true extent (values outside `0…1`), so a shader framing it
    /// draws the edge where the region is rather than where the surface ends. An empty region,
    /// or empty `bounds`, is all zeros.
    func uniformValues(in bounds: CGRect, isFlipped: Bool) -> [Float] {
        let floatsPerRegion = ExtensionMetalSource.UniformLayout.floatsPerFocusRegion
        return regions.flatMap { rect -> [Float] in
            guard Self.isRegion(rect), Self.isRegion(bounds) else {
                return Array(repeating: 0, count: floatsPerRegion)
            }
            let top = isFlipped ? rect.minY - bounds.minY : bounds.maxY - rect.maxY
            return [
                Float((rect.minX - bounds.minX) / bounds.width),
                Float(top / bounds.height),
                Float(rect.width / bounds.width),
                Float(rect.height / bounds.height)
            ]
        }
    }
}

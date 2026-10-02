import AppKit

/// Geometry and flat paint for a surface whose appearance has already been resolved.
///
/// `ThemedSurface` owns theme and material selection. This leaf takes concrete colours, radius
/// and border width so another drawing backend can use the same silhouette and paint order.
@MainActor
public enum SurfaceDrawing {

    /// The silhouette a surface was drawn as: a rect and the corner it was given.
    ///
    /// Returned instead of the `NSBezierPath` itself because the ring that follows a surface has
    /// to be *inset* from it, and a path cannot be inset — only rebuilt, which is the caller
    /// re-deriving the same three tokens and drifting by half a point.
    public struct Shape {
        public let rect: NSRect
        /// Never larger than half the shorter side — see `init(rect:radius:)`.
        public let radius: CGFloat

        /// A corner is **fitted to the rect it turns**, because the two ways this app draws one
        /// rounded surface disagree about what an oversized radius means.
        ///
        /// `CALayer.cornerRadius` clamps to half the *shorter* side, so an `applySurface` under a
        /// broad theme degrades to a capsule. `NSBezierPath(roundedRect:xRadius:yRadius:)` clamps
        /// each axis on its own, so the same token on the same rect produces a corner as wide as
        /// the radius and only as tall as the rect allows: two quarter-ellipses meeting in a
        /// taper. On Botanical, whose control corner is 24, a 26pt-tall menu row came out as a
        /// pointed lens beside layer-backed surfaces of the same radius drawn as capsules.
        ///
        /// Fitted here rather than at the call sites: a radius token is a theme's to state and a
        /// rect is the caller's, and neither of them is in a position to notice that this
        /// particular pairing has no round corner left to draw.
        public init(rect: NSRect, radius: CGFloat) {
            self.rect = rect
            let shorterSide = max(0, min(rect.width, rect.height))
            self.radius = min(max(0, radius), shorterSide / 2)
        }

        public var path: NSBezierPath {
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        }

        /// The same silhouette pulled inwards, corners kept concentric: a disc stays a disc and
        /// a squared theme's rect stays square, where holding the radius would leave a ring
        /// bulging out of the shape it belongs to.
        public func inset(by amount: CGFloat) -> Shape {
            Shape(
                rect: rect.insetBy(dx: amount, dy: amount),
                radius: max(0, radius - amount)
            )
        }

        /// The mirror of `inset`, for a ring drawn *around* a silhouette rather than inside it.
        ///
        /// A squared theme's rect stays square for the same reason it does on the way in: the
        /// true offset curve of a sharp corner is a round one, but a hard-cornered theme wants a
        /// hard-cornered ring, and the ring exists to restate the shape it surrounds.
        public func outset(by amount: CGFloat) -> Shape {
            Shape(
                rect: rect.insetBy(dx: -amount, dy: -amount),
                radius: radius > 0 ? radius + amount : 0
            )
        }

        /// The part of this silhouette that lies inside `rect` — **one half of a shared plate**.
        ///
        /// A welded half is not a rounded rect and drawing it as one is a visible bug: the outer
        /// corners belong to the plate, and the cut edge is the straight seam the other half
        /// meets. So a corner is turned only where it is the plate's own corner, and every edge
        /// the cut produced stays square. That is the same sentence `SplitIconButtonView` writes
        /// as a clip when it fills a raised half, said as a path so a *ring* can follow it too.
        ///
        /// A rect that contains the whole silhouette gets the whole silhouette back, so a caller
        /// that turns out not to be welded into anything draws exactly what `path` would.
        public func portion(in region: NSRect) -> NSBezierPath {
            let clipped = region.intersection(rect)
            guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else {
                return NSBezierPath()
            }

            let limit = min(clipped.width, clipped.height) / 2
            // A corner survives the cut only if both of its edges are still the silhouette's.
            func turn(atX x: CGFloat, y: CGFloat) -> CGFloat {
                let onSide = abs(x - rect.minX) < Corner.tolerance
                    || abs(x - rect.maxX) < Corner.tolerance
                let onCap = abs(y - rect.minY) < Corner.tolerance
                    || abs(y - rect.maxY) < Corner.tolerance
                return onSide && onCap ? min(radius, limit) : 0
            }

            let corners = [
                NSPoint(x: clipped.maxX, y: clipped.minY),
                NSPoint(x: clipped.maxX, y: clipped.maxY),
                NSPoint(x: clipped.minX, y: clipped.maxY),
                NSPoint(x: clipped.minX, y: clipped.minY)
            ]
            let path = NSBezierPath()
            // Started mid-edge rather than at a corner, because a tangent arc needs a current
            // point to turn away from: beginning *on* a corner would round it against itself.
            path.move(to: NSPoint(x: clipped.midX, y: clipped.minY))
            for (index, corner) in corners.enumerated() {
                let turn = turn(atX: corner.x, y: corner.y)
                if turn > 0 {
                    let next = corners[(index + 1) % corners.count]
                    path.appendArc(from: corner, to: next, radius: turn)
                } else {
                    path.line(to: corner)
                }
            }
            path.close()
            return path
        }

        private enum Corner {
            /// Points, not ulps: these coordinates have been through a view-to-view conversion
            /// and an inset, so exact equality is not a question worth asking of them.
            static let tolerance: CGFloat = 0.01
        }
    }

    /// Draws the fill and optional border, returning the exact silhouette they follow.
    /// The caller resolves any default radius against the rect after the border inset.
    @discardableResult
    public static func draw(
        _ bounds: NSRect,
        fill: NSColor,
        border: NSColor? = nil,
        radius: CGFloat,
        borderWidth: CGFloat
    ) -> Shape {
        // Half a point in, so a one-point border falls inside the control rather than straddling
        // its edge and drawing at half intensity.
        let rect = border == nil ? bounds : bounds.insetBy(dx: borderWidth / 2, dy: borderWidth / 2)
        let shape = Shape(rect: rect, radius: radius)
        let path = shape.path

        fill.setFill()
        path.fill()

        if let border {
            border.setStroke()
            path.lineWidth = borderWidth
            path.stroke()
        }
        return shape
    }
}

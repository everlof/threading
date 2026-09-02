import AppKit

// MARK: - Optical Centring

/// Centres a drawn shape by the ink it actually puts on screen, rather than by the geometry it
/// was built from.
///
/// This is the drawing half of the design system's **aligned by ink** rule. The other half is
/// `OpticalInsetProviding`, which is about *containers*: a control declares the invisible padding
/// inside its frame and the container subtracts it. That rule cannot help a component whose frame
/// is honest and whose *path* is not — the shape is centred on its own construction points, the
/// ink lands somewhere else, and every container above it is placing the frame correctly.
///
/// Two independent things move a shape off the line, and both are corrected here:
///
/// **Construction points are not the drawn edge.** A rounded corner is a tangent arc, so it eats
/// the vertex it replaces. On an upward triangle only the *apex* is lost that way — the base
/// corners are cut sideways — so a triangle centred on its three points draws with its ink a
/// point low. Measured on `ThemedWarningMark` in a 28pt sidebar row: the attention dots landed
/// 0.25pt under the title's optical centre and the triangle landed 1.25pt under, which is a
/// mark visibly not on the row's line. The same applies to any stroked path (half the line width
/// falls outside the geometry), to a glyph inside a slot, and to artwork whose transparent margin
/// is not symmetric.
///
/// **Ink is not always evenly distributed inside its own box.** A disc's mass sits on its centre
/// line, so centring its box centres it. A triangle's area centroid is a third of the way up from
/// its base, which leaves most of its ink below the box's middle and makes a perfectly
/// box-centred triangle read as hanging low.
///
/// **That second correction is measured, not declared.** `centreOfMass(of:)` weighs the shape —
/// flattened, shoelace, exact for the polygon actually drawn — so a component says nothing about
/// how its ink sits and cannot say it wrongly: a disc measures no correction and gets none, a
/// triangle measures one and gets it, and a shape nobody has thought about is handled by the same
/// call. The declared `InkMass` remains only for ink this cannot reach — a template image, a
/// glyph run, a layer's contents — and its numbers are a triangle's own, written down.
///
/// The single judgement left is `balance`: *how far* towards the centre of mass to move. Half,
/// picked from a zoomed render beside the dots the mark shares a column with.
public enum OpticalCentring {

    // MARK: - Types

    /// How a shape's ink is distributed through its bounding box, for callers that cannot be
    /// measured — a template image, a glyph run, a layer's contents.
    ///
    /// A **path does not use this**: `centreOfMass(of:)` measures the same fact off the shape
    /// itself, which is always better than an author's claim about it. Named for the *shape*
    /// rather than for a number, so the one case that must be declared still says what it is
    /// drawing instead of carrying a literal.
    public enum InkMass {
        /// Spread evenly enough that the bounding box is the answer — a disc, a ring, a bar, a
        /// letterform, most SF Symbols.
        case even

        /// Gathered at the bottom: an upward triangle, a pyramid.
        case baseHeavy

        /// Gathered at the top: a downward triangle, a hanging drop.
        case topHeavy

        /// The correction as a fraction of the ink's height — `balance` applied to a triangle's
        /// own geometry, which is where these numbers come from: its centroid sits `height / 6`
        /// off the box's middle, halved is `height / 12`.
        public var rise: CGFloat {
            switch self {
            case .even: return 0
            case .baseHeavy: return balance / 6
            case .topHeavy: return -balance / 6
            }
        }
    }

    // MARK: - Properties

    /// How far towards the ink's centre of mass a shape is moved: 0 leaves it centred on its
    /// bounding box, 1 puts the centre of mass itself on the line.
    ///
    /// The one number here that is taste rather than measurement, and it is stated once. Neither
    /// end is right: a box-centred triangle reads as hanging low, because nearly all of its ink
    /// is under the middle; a centroid-centred one throws the apex half again as far above the
    /// line as the base falls below it. Half was picked from a zoomed render of the sidebar's
    /// marks beside the dots they share a column with.
    public static let balance: CGFloat = 0.5

    // MARK: - Public Methods

    /// How far ink has to move to sit centred in `bounds`, given only its box.
    ///
    /// For a component drawing something that is not an `NSBezierPath` — a template image, a
    /// glyph run, a layer's contents. It cannot measure the distribution, so the caller states
    /// it; prefer the path overload, which does not have to be told.
    public static func offset(
        centring ink: NSRect,
        in bounds: NSRect,
        mass: InkMass = .even
    ) -> NSSize {
        guard !ink.isEmpty else { return .zero }

        return NSSize(
            width: bounds.midX - ink.midX,
            height: bounds.midY - ink.midY + ink.height * mass.rise
        )
    }

    /// How far a shape has to move to sit centred in `bounds`, **measured**.
    ///
    /// The correction is a property of the shape, so it is read off the shape rather than
    /// claimed: the offset carries the path from its bounding box's middle a `balance` of the
    /// way towards its own centre of mass. A disc measures a centre of mass on its middle and
    /// therefore moves not at all, while a triangle measures `height / 6` below it and rises by
    /// half of that — the same numbers `InkMass` states for the callers that cannot be measured,
    /// arrived at rather than asserted.
    public static func offset(
        centring path: NSBezierPath,
        in bounds: NSRect,
        balance: CGFloat = balance
    ) -> NSSize {
        guard path.elementCount > 0 else { return .zero }

        // No `isEmpty` guard on the ink, unlike the rect overload: a rule is a horizontal line
        // whose box has no height, and centring it vertically is exactly what a caller wants.
        // There the empty rect means "nothing measured"; here the path is the evidence.
        let ink = path.bounds

        // No measurable area — a single line, a path that is only ever stroked — leaves the box
        // as the answer. That is the honest fallback rather than a defect: a stroke's ink is its
        // outline, which this path does not describe, so there is nothing here to weigh.
        guard let mass = centreOfMass(of: path) else {
            return NSSize(width: bounds.midX - ink.midX, height: bounds.midY - ink.midY)
        }

        return NSSize(
            width: bounds.midX - ink.midX + (ink.midX - mass.x) * balance,
            height: bounds.midY - ink.midY + (ink.midY - mass.y) * balance
        )
    }

    /// The centroid of the area a path encloses, or nil when it encloses none.
    ///
    /// Flattened and summed with the shoelace formula rather than rasterised: it is exact for
    /// the polygon actually drawn, costs one pass over a handful of segments, and can therefore
    /// run inside `draw(_:)` — a raster's alpha-weighted centroid would be the more general
    /// answer, and is what a *glyph* would need, but it would have to be cached per size and
    /// per theme to be affordable.
    ///
    /// Subpaths are summed with signed areas, so a hole subtracts itself and a shape drawn as
    /// several pieces answers for all of them.
    public static func centreOfMass(of path: NSBezierPath) -> NSPoint? {
        let flattened = path.flattened
        guard flattened.elementCount > 1 else { return nil }

        var points = [NSPoint](repeating: .zero, count: 3)
        var subpathStart: NSPoint?
        var previous: NSPoint?
        var twiceArea: CGFloat = 0
        var weightedX: CGFloat = 0
        var weightedY: CGFloat = 0

        /// One edge's contribution to the shoelace sums.
        func accumulate(from first: NSPoint, to second: NSPoint) {
            let cross = first.x * second.y - second.x * first.y
            twiceArea += cross
            weightedX += (first.x + second.x) * cross
            weightedY += (first.y + second.y) * cross
        }

        for index in 0..<flattened.elementCount {
            switch flattened.element(at: index, associatedPoints: &points) {
            case .moveTo:
                // An unclosed subpath still encloses the area its last edge implies, the same
                // way filling it does.
                if let subpathStart, let previous { accumulate(from: previous, to: subpathStart) }
                subpathStart = points[0]
                previous = points[0]

            case .lineTo:
                if let previous { accumulate(from: previous, to: points[0]) }
                previous = points[0]

            case .closePath:
                if let subpathStart, let previous { accumulate(from: previous, to: subpathStart) }
                previous = subpathStart

            case .curveTo, .cubicCurveTo, .quadraticCurveTo:
                // Flattening has removed these; a future macOS that keeps one would otherwise
                // silently drop its area, so it is followed as a straight edge instead.
                if let previous { accumulate(from: previous, to: points.last ?? points[0]) }
                previous = points.last ?? points[0]

            @unknown default:
                continue
            }
        }
        if let subpathStart, let previous { accumulate(from: previous, to: subpathStart) }

        let area = twiceArea / 2
        guard abs(area) > .ulpOfOne else { return nil }

        return NSPoint(x: weightedX / (6 * area), y: weightedY / (6 * area))
    }
}

// MARK: - Bezier Path

extension NSBezierPath {

    /// Slides the path so what it *draws* is optically centred in `bounds`, and returns it.
    ///
    /// Nothing has to be declared: the shape is measured. Returned rather than only mutated so a
    /// `draw(_:)` reads as one expression, which is what keeps the rule from being the line
    /// somebody forgets to add after building a shape.
    @discardableResult
    public func centringInk(in bounds: NSRect, balance: CGFloat = OpticalCentring.balance) -> NSBezierPath {
        // `bounds` raises `NSGenericException: No current point` on a path with nothing in it —
        // an ObjC exception, so it cannot be caught in Swift and takes the app with it. A
        // component that draws nothing under some state (a zero-size slot, a shape whose radius
        // ate it) must be allowed to call this like any other.
        guard elementCount > 0 else { return self }

        let offset = OpticalCentring.offset(centring: self, in: bounds, balance: balance)
        guard offset != .zero else { return self }

        transform(using: AffineTransform(translationByX: offset.width, byY: offset.height))
        return self
    }
}

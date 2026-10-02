import AppKit

// MARK: - Coupon Outline

/// The ticket silhouette a theme's pop-ups wear under `PopoverStyle.Edge.coupon`: a rounded
/// body whose two side edges are bitten by a row of half-circle scallops, the way a coupon is
/// torn from its book.
///
/// One geometry, several owners. The anchored popover fills and strokes it through its single
/// outline; menus and alerts mask their layer-backed surfaces with it and stroke it in their own
/// drawing. Keeping the path here is what makes a coupon read the same wherever it appears, and
/// what lets one test pin it.
///
/// The bites sit only on the two vertical sides. A pop-up's height varies with its content while
/// its sides are where a ticket is torn, and keeping the top and bottom straight leaves the
/// edge a title or a button row rests against undisturbed.
enum CouponOutline {

    /// Radius of one bite.
    static let biteRadius: CGFloat = 3

    /// The least distance between neighbouring bite centres. The row is spread to divide each
    /// side's straight run evenly, so the first and last bites stay clear of the corner arcs at
    /// any height.
    static let minimumPitch: CGFloat = 10

    /// How far the bites reach into the body. Content keeps at least this clear of the sides.
    static var depth: CGFloat { biteRadius }

    /// The centres of the bites along one side, given the straight run between its corner arcs.
    static func biteCentres(along run: ClosedRange<CGFloat>) -> [CGFloat] {
        let length = run.upperBound - run.lowerBound
        let count = Int((length / minimumPitch).rounded(.down))
        guard count > 0 else { return [] }
        let step = length / CGFloat(count)
        return (0..<count).map { run.lowerBound + step * (CGFloat($0) + 0.5) }
    }

    /// The closed outline of a coupon filling `rect`, walked once around so a fill, a stroke and
    /// a shadow path all agree.
    static func path(in rect: NSRect, cornerRadius: CGFloat) -> NSBezierPath {
        let radius = max(0, min(cornerRadius, min(rect.width, rect.height) / 2))
        let bites = biteCentres(along: (rect.minY + radius)...(rect.maxY - radius))
        let path = NSBezierPath()

        path.move(to: NSPoint(x: rect.minX + radius, y: rect.minY))
        path.line(to: NSPoint(x: rect.maxX - radius, y: rect.minY))
        path.appendArc(
            withCenter: NSPoint(x: rect.maxX - radius, y: rect.minY + radius),
            radius: radius, startAngle: 270, endAngle: 360
        )

        // Right side, walking up: each bite turns back through the body's side, so the arc runs
        // clockwise from below its centre to above it.
        for centre in bites {
            path.line(to: NSPoint(x: rect.maxX, y: centre - biteRadius))
            path.appendArc(
                withCenter: NSPoint(x: rect.maxX, y: centre),
                radius: biteRadius, startAngle: 270, endAngle: 90, clockwise: true
            )
        }
        path.line(to: NSPoint(x: rect.maxX, y: rect.maxY - radius))
        path.appendArc(
            withCenter: NSPoint(x: rect.maxX - radius, y: rect.maxY - radius),
            radius: radius, startAngle: 0, endAngle: 90
        )

        path.line(to: NSPoint(x: rect.minX + radius, y: rect.maxY))
        path.appendArc(
            withCenter: NSPoint(x: rect.minX + radius, y: rect.maxY - radius),
            radius: radius, startAngle: 90, endAngle: 180
        )

        // Left side, walking down — the mirror of the right.
        for centre in bites.reversed() {
            path.line(to: NSPoint(x: rect.minX, y: centre + biteRadius))
            path.appendArc(
                withCenter: NSPoint(x: rect.minX, y: centre),
                radius: biteRadius, startAngle: 90, endAngle: 270, clockwise: true
            )
        }
        path.line(to: NSPoint(x: rect.minX, y: rect.minY + radius))
        path.appendArc(
            withCenter: NSPoint(x: rect.minX + radius, y: rect.minY + radius),
            radius: radius, startAngle: 180, endAngle: 270
        )
        path.close()
        return path
    }

    /// Whether `material` dresses its app-owned pop-ups as coupons.
    static func isWorn(by material: AppTheme.Material) -> Bool {
        material.popoverStyle.edge == .coupon
    }
}

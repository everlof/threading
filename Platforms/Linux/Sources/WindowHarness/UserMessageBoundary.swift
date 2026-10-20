import AppKit

// The checked default Threading appearance has fixed radii across light/dark modes. The app
// theme sweep's ObjC-associated constraint registry is unnecessary in this limited host; fit
// the same shared corner geometry once. Broader theme configuration remains unimplemented.
extension NSView {
    func holdAtContentInset(_ constraints: [NSLayoutConstraint],
                            inside radius: SurfaceRadius = .panel,
                            from base: CGFloat = Design.Spacing.inset,
                            less reduction: CGFloat = 0) {
        let inset = max(0, SurfaceDrawing.contentInset(inside: radius.current, from: base) - reduction)
        for constraint in constraints {
            constraint.constant = constraint.constant < 0 ? -inset : inset
        }
    }
}

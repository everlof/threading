import AppKit

// The checked default Threading appearance has fixed radii across light/dark modes. The app
// theme sweep's ObjC-associated constraint registry is unnecessary in this limited host; fit
// the same shared corner geometry once. Broader theme configuration remains unimplemented.
extension NSView {
    func holdAtContentInset(_ constraints: [NSLayoutConstraint], from base: CGFloat) {
        let inset = SurfaceDrawing.contentInset(inside: SurfaceRadius.panel.current, from: base)
        for constraint in constraints {
            constraint.constant = constraint.constant < 0 ? -inset : inset
        }
    }
}

// Core/Views/ConversationDefaults also references app-only transcript/controller policy.
// This is its exact long-message label limit, consumed by the unchanged production bubble.
enum ConversationDefaults { static let longMessageLineCap = 8 }

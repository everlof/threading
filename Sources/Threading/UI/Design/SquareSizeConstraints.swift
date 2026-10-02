import AppKit

/// Keeps the two equal-size anchors for a fixed square inside the design adapter.
@MainActor
extension NSView {
    func squareSizeConstraints(side: CGFloat) -> [NSLayoutConstraint] {
        [
            widthAnchor.constraint(equalToConstant: side),
            heightAnchor.constraint(equalToConstant: side)
        ]
    }
}

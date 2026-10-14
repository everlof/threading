import AppKit

/// Fixes a sample's or fixed widget's size inside the design adapter, so the view that shows it
/// states a size without constructing layout of its own.
@MainActor
extension NSView {
    func fixSize(width: CGFloat? = nil, height: CGFloat? = nil) {
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate(
            [width.map { widthAnchor.constraint(equalToConstant: $0) },
             height.map { heightAnchor.constraint(equalToConstant: $0) }].compactMap { $0 }
        )
    }
}

import AppKit

extension Design.UsageBar {
    /// A clock tick crosses both the empty trough and arbitrary severity/accent fills.
    /// Opposite opaque inks keep its silhouette visible even at the fill boundary or over
    /// segmented progress materials, where no single background colour describes the pixels.
    static let timeMarkOutlineWidth: CGFloat = 1
    static var timeMarkInk: NSColor { .white }
    static var timeMarkOutline: NSColor { .black }
    static var outlinedTimeMarkWidth: CGFloat { timeMarkWidth + 2 * timeMarkOutlineWidth }
}

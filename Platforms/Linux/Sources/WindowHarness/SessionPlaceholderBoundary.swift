import AppKit

// The installed preview uses a checked production palette. These are the
// geometry leaves needed by the unchanged production idle placeholder. Fonts use the shared
// host FontRole boundary.
extension Design.Spacing {
    static let pane: CGFloat = 32
}

extension Design {
    enum Placeholder {
        static let afterIcon = Spacing.inset
        static let line = Spacing.small
        static let section = Spacing.pane
    }
}

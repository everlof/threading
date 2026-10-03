import AppKit

// The installed host already carries these two roles in MenuThemeBoundary. The focused fixture
// links a smaller palette boundary so it states only the leaves PageTitleView reads.
extension Design.Spacing {
    static let medium: CGFloat = 10
}

extension Design {
    enum Text {
        static let secondary = NSColor(white: 0.7, alpha: 1)
    }
}

enum L10n {
    static func string(_ value: String) -> String { value }
}

import AppKit

// The installed preview uses a checked production palette. These two font roles are the
// narrow host leaves needed by the unchanged production idle placeholder.
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

enum SessionPlaceholderFontRole {
    case placeholderTitle, subheading
}

extension NSTextField {
    func applyFont(_ role: SessionPlaceholderFontRole) {
        switch role {
        case .placeholderTitle: font = NSFont.systemFont(ofSize: 15, weight: .medium)
        case .subheading: font = NSFont.systemFont(ofSize: 12, weight: .regular)
        }
    }
}

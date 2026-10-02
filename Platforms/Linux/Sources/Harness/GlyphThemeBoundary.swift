import AppKit

/// The diagnostic hosts use exact production GlyphView for decoded artwork. They have no
/// theme-selected SF Symbol catalogue; a symbol request must fail visibly until that service
/// exists instead of leaving a blank icon in a live window.
@MainActor
public protocol ThemeDerivedContent {
    func rederiveThemedContent()
}

@MainActor
public enum Design {
    public enum Symbol {
        public enum Role {
            case control

            public var pointSize: CGFloat { 12 }
        }

        public static func image(
            _ name: String,
            slot: CGFloat,
            pointSize: CGFloat,
            weight: NSFont.Weight
        ) -> NSImage? {
            preconditionFailure("Linux diagnostic host has no SF Symbol provider for \(name)")
        }
    }
}

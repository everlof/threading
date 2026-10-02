import AppKit

// Typecheck-only stand-ins for macOS theme policy. The probe compiles the exact product drawing
// files; these declarations do not implement an image, theme, or missing AppKit member.
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
            nil
        }
    }
}

import AppKit

// Environment facts for the production grammar. These values deliberately do not implement
// the conversation view or silently accept its missing text selection and paging contracts.
@MainActor enum Design {
    enum Text {
        static let label = NSColor(white: 0.08, alpha: 1)
        static let secondary = NSColor(white: 0.32, alpha: 1)
        static let tertiary = NSColor(white: 0.45, alpha: 1)
    }
    enum Surface {
        static let panel = NSColor(white: 0.92, alpha: 1)
        static let accent = NSColor(red: 0.08, green: 0.30, blue: 0.75, alpha: 1)
    }
    enum Spacing { static let inset: CGFloat = 12 }
    enum Chat {
        static let blockSpacing: CGFloat = 12
        static let readingLineHeight: CGFloat = 1.625
        static let codeLineHeight: CGFloat = 1.45
        static func lineSpacing(for font: NSFont, multiple: CGFloat) -> CGFloat {
            let natural = (font.ascender - font.descender + font.leading).rounded(.up)
            return max(0, (font.pointSize * multiple).rounded() - natural)
        }
    }
    enum Typography {
        enum FontSurface { case chrome, conversation }
        static func reading() -> NSFont { body(surface: .conversation) }
        static func readingCode() -> NSFont { inlineCode() }
        static func body(surface: FontSurface) -> NSFont { .systemFont(ofSize: 17) }
        static func inlineCode() -> NSFont { .monospacedSystemFont(ofSize: 16, weight: .regular) }
        static func markdownHeading(from font: NSFont, surface: FontSurface) -> NSFont {
            let resized = NSFont(descriptor: font.fontDescriptor, size: font.pointSize + 3) ?? font
            return NSFontManager.shared.convert(resized, toHaveTrait: .boldFontMask)
        }
    }
}

import AppKit

// Only the production view's environment. The glyph implementation itself is an exact symlink.
@MainActor protocol ThemedComponent {}
struct AppThemeDidChange {}
@MainActor final class AppEventObservations {
    func observe<Event>(_ event: Event.Type, _ handler: @escaping (Event) -> Void) {}
}

@MainActor enum Design {
    enum Text {
        static let secondary = NSColor(red: 0.12, green: 0.23, blue: 0.52, alpha: 1)
    }
    enum Symbol {
        static let control: CGFloat = 14
        static func image(_ name: String, slot: CGFloat, pointSize: CGFloat) -> NSImage? {
            guard name == "fixture.symbol" else { return nil }
            let pixels = [UInt8](repeating: 0, count: 8 * 8 * 4).enumerated().map {
                $0.offset % 4 == 3 ? UInt8(255) : $0.element
            }
            let image = NSImage(rgba: pixels, width: 8, height: 8,
                                size: NSSize(width: 8, height: 8))
            image?.isTemplate = true
            return image
        }
    }
}

@MainActor struct AppThemePalette {
    enum GlyphStyle { case classic, system }
    struct PopoverStyle { let glyphStyle: GlyphStyle }
    struct Material { let popoverStyle: PopoverStyle }
    static var glyphStyle: GlyphStyle = .classic
    static let current = AppThemePalette()
    func material(for appearance: NSAppearance) -> Material {
        Material(popoverStyle: PopoverStyle(glyphStyle: Self.glyphStyle))
    }
}

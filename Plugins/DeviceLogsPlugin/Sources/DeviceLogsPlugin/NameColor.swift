import AppKit
import ThreadingDesignKit

/// A colour for a name: the hue comes from the name, the weight from the theme.
///
/// An enum case — a command, a message kind — reads fastest when it is the same colour in every
/// row and every capture, so its hue is a stable hash of the text rather than an order of
/// appearance. Lightness and chroma are the theme's own syntax keyword's, measured in OKLCH, so a
/// name sits at the weight the theme already gives code; and the result is lifted to legibility on
/// the theme's ground. Resolved at draw time, so a theme or appearance change follows live.
enum NameColor {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: NSColor] = [:]
    private static let cacheLimit = 1_024
    /// Reds read as errors in a log, so hues start past them.
    private static let hueRange: ClosedRange<CGFloat> = 45...345
    private static let chromaRange: ClosedRange<CGFloat> = 0.08...0.2

    static func color(for name: String) -> NSColor {
        NSColor(name: nil) { appearance in resolved(name, appearance: appearance) }
    }

    /// Exposed for tests: the concrete colour in one appearance of the current theme.
    static func resolved(_ name: String, appearance: NSAppearance) -> NSColor {
        let theme = AppThemePalette.current
        let key = "\(theme.id)|\(appearance.name.rawValue)|\(name)"
        lock.lock()
        if let hit = cache[key] { lock.unlock(); return hit }
        lock.unlock()

        let base = theme.resolved(.syntaxKeyword, appearance: appearance).oklch
        let ground = theme.resolved(.ground, appearance: appearance)
        let hue = hueRange.lowerBound + CGFloat(hash(name) % 3_000) / 3_000 * (hueRange.upperBound - hueRange.lowerBound)
        let color = NSColor.oklch(OKLCH(
            lightness: min(max(base.lightness, 0), 1),
            chroma: min(max(base.chroma, chromaRange.lowerBound), chromaRange.upperBound),
            hueDegrees: hue
        )).legible(on: ground)

        lock.lock()
        if cache.count >= cacheLimit { cache.removeAll(keepingCapacity: true) }
        cache[key] = color
        lock.unlock()
        return color
    }

    /// FNV-1a over UTF-8: stable across launches, unlike `hashValue`.
    static func hash(_ name: String) -> UInt32 {
        var value: UInt32 = 2_166_136_261
        for byte in name.utf8 { value = (value ^ UInt32(byte)) &* 16_777_619 }
        return value
    }
}

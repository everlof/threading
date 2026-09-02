import AppKit

extension NSColor {

    /// Initialize NSColor from RGB or RGBA hex (e.g. `#FF0000` or `#FF000080`).
    ///
    /// Terminal palettes are opaque, but app themes deliberately use translucent semantic
    /// roles. Accepting and preserving the alpha byte keeps a custom app theme identical after
    /// it has crossed its JSON persistence boundary.
    public convenience init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        guard hexSanitized.count == 6 || hexSanitized.count == 8 else { return nil }

        var rgbValue: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgbValue) else { return nil }

        let hasAlpha = hexSanitized.count == 8
        let redShift: UInt64 = hasAlpha ? 24 : 16
        let greenShift: UInt64 = hasAlpha ? 16 : 8
        let blueShift: UInt64 = hasAlpha ? 8 : 0
        let red = CGFloat((rgbValue >> redShift) & 0xFF) / 255.0
        let green = CGFloat((rgbValue >> greenShift) & 0xFF) / 255.0
        let blue = CGFloat((rgbValue >> blueShift) & 0xFF) / 255.0
        let alpha = hasAlpha ? CGFloat(rgbValue & 0xFF) / 255.0 : 1.0

        self.init(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    /// Returns `#RRGGBB` for opaque colours and `#RRGGBBAA` when alpha carries meaning.
    ///
    /// **Rounded, not truncated.** Quantising to 8 bits by truncation is exact only for a colour
    /// that was written as hex in the first place. A palette authored in OKLCH arrives here
    /// through the OKLab matrices, so pure white lands a few millionths under 1.0 and truncation
    /// reports it as `#FEFEFE` — the stock Threading palette named its body ink one step darker
    /// than it is and its bold ink not-quite-white, in the theme documents the MCP tools hand
    /// out and in every export. Rounding is the nearest representable channel, which is what a
    /// hex string is claiming to be.
    public var hexString: String {
        guard let color = usingColorSpace(.sRGB) else {
            return "#000000"
        }

        let red = Int((color.redComponent * 255).rounded())
        let green = Int((color.greenComponent * 255).rounded())
        let blue = Int((color.blueComponent * 255).rounded())
        let alpha = Int((color.alphaComponent * 255).rounded())

        if alpha < 255 {
            return String(format: "#%02X%02X%02X%02X", red, green, blue, alpha)
        }
        return String(format: "#%02X%02X%02X", red, green, blue)
    }

    /// This colour laid over an opaque one, as a single opaque colour.
    ///
    /// The arithmetic AppKit would have done at draw time, done once instead — which is the
    /// difference between a fill that *looks* like a translucent role over its ground and one
    /// that lets whatever is behind it show through. `blended(withFraction:of:)` is not this: it
    /// mixes two colours and keeps the receiver's alpha, so a 14% surface stays 14% see-through.
    ///
    /// Both sides are resolved in sRGB, and a dynamic colour resolves against whatever drawing
    /// appearance is current — so call this where that appearance is in force.
    public func composited(over ground: NSColor) -> NSColor {
        guard let over = usingColorSpace(.sRGB),
              let under = ground.usingColorSpace(.sRGB) else { return self }

        let alpha = over.alphaComponent
        guard alpha < 1 else { return over }

        func mix(_ top: CGFloat, _ bottom: CGFloat) -> CGFloat {
            top * alpha + bottom * (1 - alpha)
        }

        return NSColor(
            srgbRed: mix(over.redComponent, under.redComponent),
            green: mix(over.greenComponent, under.greenComponent),
            blue: mix(over.blueComponent, under.blueComponent),
            // The ground is what makes the result opaque; a translucent one cannot, and a card
            // over a see-through ground has nothing to be flattened against anyway.
            alpha: under.alphaComponent
        )
    }
}

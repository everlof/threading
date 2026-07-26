import AppKit

extension NSColor {

    /// Initialize NSColor from RGB or RGBA hex (e.g. `#FF0000` or `#FF000080`).
    ///
    /// Terminal palettes are opaque, but app themes deliberately use translucent semantic
    /// roles. Accepting and preserving the alpha byte keeps a custom app theme identical after
    /// it has crossed its JSON persistence boundary.
    convenience init?(hex: String) {
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
    var hexString: String {
        guard let color = usingColorSpace(.sRGB) else {
            return "#000000"
        }

        let red = Int(color.redComponent * 255)
        let green = Int(color.greenComponent * 255)
        let blue = Int(color.blueComponent * 255)
        let alpha = Int(color.alphaComponent * 255)

        if alpha < 255 {
            return String(format: "#%02X%02X%02X%02X", red, green, blue, alpha)
        }
        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}

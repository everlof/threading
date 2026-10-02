import Foundation

/// sRGB with straight alpha. Named colours retain their appearance provider until rasterization.
/// A fixed colour instead compares by its components, as the existing shim callers expect.
public final class NSColor: @unchecked Sendable, Equatable, Hashable {
    public struct Name: RawRepresentable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(_ rawValue: String) { self.rawValue = rawValue }
    }

    private struct RGBA {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        let alpha: CGFloat
    }

    private enum Storage {
        case fixed(RGBA)
        case dynamic(Name, (NSAppearance) -> NSColor)
        case alpha(NSColor, CGFloat)
    }

    private let storage: Storage

    private init(storage: Storage) { self.storage = storage }

    public convenience init(name: Name, dynamicProvider: @escaping (NSAppearance) -> NSColor) {
        self.init(storage: .dynamic(name, dynamicProvider))
    }

    public convenience init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        self.init(storage: .fixed(RGBA(red: red, green: green, blue: blue, alpha: alpha)))
    }

    public convenience init(calibratedRed red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        self.init(red: red, green: green, blue: blue, alpha: alpha)
    }

    public convenience init(srgbRed red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        self.init(red: red, green: green, blue: blue, alpha: alpha)
    }

    public convenience init(deviceRed red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        self.init(red: red, green: green, blue: blue, alpha: alpha)
    }

    public convenience init(white: CGFloat, alpha: CGFloat) {
        self.init(red: white, green: white, blue: white, alpha: alpha)
    }

    /// AppKit's normalized HSB constructor. Generated project tiles use their stable name hash
    /// as hue; resolving to fixed sRGB here keeps the same image in light and dark windows.
    public convenience init(hue: CGFloat, saturation: CGFloat, brightness: CGFloat, alpha: CGFloat) {
        precondition([hue, saturation, brightness, alpha].allSatisfy(\.isFinite),
                     "nonfinite HSB color")
        let h = hue - floor(hue)
        let s = max(0, min(1, saturation))
        let v = max(0, min(1, brightness))
        let chroma = v * s
        let sector = h * 6
        let second = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let base = v - chroma
        let channels: (CGFloat, CGFloat, CGFloat)
        switch Int(sector) {
        case 0: channels = (chroma, second, 0)
        case 1: channels = (second, chroma, 0)
        case 2: channels = (0, chroma, second)
        case 3: channels = (0, second, chroma)
        case 4: channels = (second, 0, chroma)
        default: channels = (chroma, 0, second)
        }
        self.init(red: channels.0 + base, green: channels.1 + base,
                  blue: channels.2 + base, alpha: alpha)
    }

    public convenience init(calibratedWhite white: CGFloat, alpha: CGFloat) {
        self.init(white: white, alpha: alpha)
    }

    private func resolved(in appearance: NSAppearance, depth: Int = 0) -> RGBA {
        precondition(depth < 32, "recursive dynamic NSColor provider")
        switch storage {
        case .fixed(let rgba):
            return rgba
        case .dynamic(_, let provider):
            return provider(appearance).resolved(in: appearance, depth: depth + 1)
        case .alpha(let base, let alpha):
            let rgba = base.resolved(in: appearance, depth: depth + 1)
            return RGBA(red: rgba.red, green: rgba.green, blue: rgba.blue, alpha: alpha)
        }
    }

    private var currentRGBA: RGBA { resolved(in: NSAppearance.currentDrawing()) }
    public var redComponent: CGFloat { currentRGBA.red }
    public var greenComponent: CGFloat { currentRGBA.green }
    public var blueComponent: CGFloat { currentRGBA.blue }
    public var alphaComponent: CGFloat { currentRGBA.alpha }

    /// CoreGraphics colors are snapshots, even when the AppKit color is appearance-dynamic.
    /// Resolve at the point a drawing command captures it so a later appearance switch cannot
    /// silently recolor an already queued path.
    public var cgColor: NSColor {
        let rgba = currentRGBA
        return NSColor(red: rgba.red, green: rgba.green, blue: rgba.blue, alpha: rgba.alpha)
    }

    // MARK: - Derivation

    public func withAlphaComponent(_ alpha: CGFloat) -> NSColor {
        switch storage {
        case .fixed(let rgba):
            return NSColor(red: rgba.red, green: rgba.green, blue: rgba.blue, alpha: alpha)
        default:
            return NSColor(storage: .alpha(self, alpha))
        }
    }

    public func blended(withFraction fraction: CGFloat, of color: NSColor) -> NSColor? {
        let first = currentRGBA, second = color.currentRGBA
        let t = max(0, min(1, fraction))
        return NSColor(
            red: first.red + (second.red - first.red) * t,
            green: first.green + (second.green - first.green) * t,
            blue: first.blue + (second.blue - first.blue) * t,
            alpha: first.alpha + (second.alpha - first.alpha) * t
        )
    }

    /// Colour-space conversion is a fixed snapshot in the current drawing appearance.
    public func usingColorSpace(_ space: NSColorSpace) -> NSColor? {
        let rgba = currentRGBA
        return NSColor(red: rgba.red, green: rgba.green, blue: rgba.blue, alpha: rgba.alpha)
    }

    public var brightnessComponent: CGFloat {
        max(redComponent, max(greenComponent, blueComponent))
    }

    // MARK: - Current colours

    // Drawing follows the calling thread's graphics context, as it does in AppKit.
    public func setFill() { NSGraphicsContext.current?.fillColor = self }
    public func setStroke() { NSGraphicsContext.current?.strokeColor = self }
    public func set() { setFill(); setStroke() }

    // MARK: - Catalogue

    public static let clear = NSColor(red: 0, green: 0, blue: 0, alpha: 0)
    public static let black = NSColor(white: 0, alpha: 1)
    public static let white = NSColor(white: 1, alpha: 1)
    // Values measured from AppKit's sRGB resolution with the default macOS accent.
    public static let labelColor = NSColor(name: Name("labelColor")) { appearance in
        NSColor(white: appearance.name == .darkAqua ? 1 : 0, alpha: 216.0 / 255)
    }
    public static let secondaryLabelColor = NSColor(name: Name("secondaryLabelColor")) { appearance in
        NSColor(white: appearance.name == .darkAqua ? 1 : 0,
                alpha: (appearance.name == .darkAqua ? 140.0 : 127.0) / 255)
    }
    public static let tertiaryLabelColor = NSColor(name: Name("tertiaryLabelColor")) { appearance in
        NSColor(white: appearance.name == .darkAqua ? 1 : 0,
                alpha: (appearance.name == .darkAqua ? 63.0 : 66.0) / 255)
    }
    public static let controlAccentColor = NSColor(name: Name("controlAccentColor")) { _ in
        NSColor(red: 0, green: 122.0 / 255, blue: 1, alpha: 1)
    }
    public static let separatorColor = NSColor(name: Name("separatorColor")) { appearance in
        NSColor(white: appearance.name == .darkAqua ? 1 : 0, alpha: 25.0 / 255)
    }
    public static let windowBackgroundColor = NSColor(name: Name("windowBackgroundColor")) { appearance in
        NSColor(white: appearance.name == .darkAqua ? 30.0 / 255 : 1, alpha: 1)
    }

    public static func == (lhs: NSColor, rhs: NSColor) -> Bool {
        if lhs === rhs { return true }
        if case .fixed(let first) = lhs.storage, case .fixed(let second) = rhs.storage {
            return first.red == second.red && first.green == second.green &&
                first.blue == second.blue && first.alpha == second.alpha
        }
        return false
    }

    public func hash(into hasher: inout Hasher) {
        switch storage {
        case .fixed(let rgba):
            hasher.combine(0)
            hasher.combine(rgba.red); hasher.combine(rgba.green)
            hasher.combine(rgba.blue); hasher.combine(rgba.alpha)
        default:
            hasher.combine(1)
            hasher.combine(ObjectIdentifier(self))
        }
    }

    public var components: (CGFloat, CGFloat, CGFloat, CGFloat) {
        let rgba = currentRGBA
        return (rgba.red, rgba.green, rgba.blue, rgba.alpha)
    }
}

public final class NSColorSpace: @unchecked Sendable {
    public static let sRGB = NSColorSpace()
    public static let deviceRGB = NSColorSpace()
    public static let genericRGB = NSColorSpace()
}

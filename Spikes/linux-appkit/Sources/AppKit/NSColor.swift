import Foundation

/// sRGB with straight alpha. The real `NSColor` is a late-binding recipe — a catalogue name, a
/// dynamic appearance provider, a colour space — and `UI/Design` leans on exactly that when it
/// says a live theme switch re-resolves during `draw(_:)`. The spike keeps the *shape* of that
/// (a colour is asked for its components at draw time, never cached as a device value) and
/// resolves it eagerly, which is the part a Linux backend would have to replace.
public final class NSColor: @unchecked Sendable, Equatable, Hashable {

    public let redComponent: CGFloat
    public let greenComponent: CGFloat
    public let blueComponent: CGFloat
    public let alphaComponent: CGFloat

    public init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        redComponent = red; greenComponent = green; blueComponent = blue; alphaComponent = alpha
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

    public convenience init(calibratedWhite white: CGFloat, alpha: CGFloat) {
        self.init(white: white, alpha: alpha)
    }

    // MARK: - Derivation

    public func withAlphaComponent(_ alpha: CGFloat) -> NSColor {
        NSColor(red: redComponent, green: greenComponent, blue: blueComponent, alpha: alpha)
    }

    public func blended(withFraction fraction: CGFloat, of color: NSColor) -> NSColor? {
        let t = max(0, min(1, fraction))
        return NSColor(
            red: redComponent + (color.redComponent - redComponent) * t,
            green: greenComponent + (color.greenComponent - greenComponent) * t,
            blue: blueComponent + (color.blueComponent - blueComponent) * t,
            alpha: alphaComponent + (color.alphaComponent - alphaComponent) * t
        )
    }

    public func usingColorSpace(_ space: NSColorSpace) -> NSColor? { self }

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
    public static let labelColor = NSColor(white: 0.1, alpha: 1)
    public static let secondaryLabelColor = NSColor(white: 0.1, alpha: 0.55)
    public static let tertiaryLabelColor = NSColor(white: 0.1, alpha: 0.3)
    public static let controlAccentColor = NSColor(red: 0, green: 0.48, blue: 1, alpha: 1)
    public static let separatorColor = NSColor(white: 0, alpha: 0.12)
    public static let windowBackgroundColor = NSColor(white: 0.93, alpha: 1)

    public static func == (lhs: NSColor, rhs: NSColor) -> Bool {
        lhs.redComponent == rhs.redComponent && lhs.greenComponent == rhs.greenComponent
            && lhs.blueComponent == rhs.blueComponent && lhs.alphaComponent == rhs.alphaComponent
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(redComponent); hasher.combine(greenComponent)
        hasher.combine(blueComponent); hasher.combine(alphaComponent)
    }

    public var components: (CGFloat, CGFloat, CGFloat, CGFloat) {
        (redComponent, greenComponent, blueComponent, alphaComponent)
    }
}

public final class NSColorSpace: @unchecked Sendable {
    public static let sRGB = NSColorSpace()
    public static let deviceRGB = NSColorSpace()
    public static let genericRGB = NSColorSpace()
}

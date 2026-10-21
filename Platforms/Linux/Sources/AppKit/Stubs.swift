import Foundation
#if os(Linux)
import AppKitTextBridge
#endif

// The leaves the spike does not implement, kept compiling so a real file's call sites can be
// measured rather than deleted. Each one is a Linux platform-service question in the draft's
// third bucket, not something a rasterizer answers.

@MainActor
public final class NSAnimationContext {

    public var duration: TimeInterval = 0.25
    public var allowsImplicitAnimation = false
    public var timingFunction: CAMediaTimingFunction?

    public static func runAnimationGroup(
        _ changes: (NSAnimationContext) -> Void,
        completionHandler: (() -> Void)? = nil
    ) {
        // Runs the change immediately and calls back: a one-frame renderer has no timeline, so
        // an animated property lands at its target value. Enough to prove the call site compiles
        // and that the final state is what the component intended.
        changes(NSAnimationContext())
        completionHandler?()
    }

    public static func beginGrouping() {}
    public static func endGrouping() {}
    public static var current = NSAnimationContext()
}

public enum NSUserInterfaceLayoutDirection: Sendable {
    case leftToRight, rightToLeft
}

public struct NSUnderlineStyle: RawRepresentable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let single = NSUnderlineStyle(rawValue: 1)
}

/// No system screen is owned by this raster tree. Views use their attached window's scale;
/// callers of the optional screen fallback choose their own default when detached.
public final class NSScreen {
    public static var main: NSScreen? { nil }
    public let backingScaleFactor: CGFloat
    public init(backingScaleFactor: CGFloat) { self.backingScaleFactor = backingScaleFactor }
}

extension NSLayoutManager {
    /// Pango's measured ascent gives the same baseline convention as the shim's text renderer.
    public func defaultBaselineOffset(for font: NSFont) -> CGFloat {
        font.ascender
    }
}

/// Field-editor identity for focus scoping. Editing, selection and IME are separate services.
@MainActor
open class NSText: NSView {
    public static let didChangeNotification = Notification.Name("NSTextDidChangeNotification")
    public weak var delegate: AnyObject?
}

/// Font selection for the bounded Pango-backed plain and attributed label paths. Editing,
/// selection, and IME still need separate platform services.
/// The descriptor preserves the selected family and weight when a design role changes its
/// point size. The current bounded Pango leaf distinguishes proportional and mono families;
/// arbitrary installed-family selection remains outside this diagnostic palette.
public final class NSFontDescriptor {
    public struct SymbolicTraits: OptionSet, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
        public static let italic = SymbolicTraits(rawValue: 1)
        public static let bold = SymbolicTraits(rawValue: 2)
        public static let monoSpace = SymbolicTraits(rawValue: 1 << 10)
    }

    public let familyName: String
    public let weight: NSFont.Weight
    public let symbolicTraits: SymbolicTraits

    fileprivate init(familyName: String, weight: NSFont.Weight, italic: Bool) {
        self.familyName = familyName
        self.weight = weight
        var traits: SymbolicTraits = []
        if italic { traits.insert(.italic) }
        if weight.rawValue >= NSFont.Weight.semibold.rawValue { traits.insert(.bold) }
        if familyName.contains("Mono") { traits.insert(.monoSpace) }
        symbolicTraits = traits
    }
}

public final class NSFont: Equatable, Hashable {
    public struct Weight: RawRepresentable, Hashable, Sendable {
        public let rawValue: CGFloat
        public init(rawValue: CGFloat) { self.rawValue = rawValue }
        public static let regular = Weight(rawValue: 0)
        public static let medium = Weight(rawValue: 0.23)
        public static let semibold = Weight(rawValue: 0.3)
        public static let bold = Weight(rawValue: 0.4)
    }

    public let pointSize: CGFloat
    private let storedFamilyName: String
    public var familyName: String? { storedFamilyName }
    public let weight: Weight
    public let isItalic: Bool
    public var fontName: String { storedFamilyName + (isItalic ? "-Italic" : "") }
    public var fontDescriptor: NSFontDescriptor {
        NSFontDescriptor(familyName: storedFamilyName, weight: weight, italic: isItalic)
    }
    private let fontBoundsLock = NSLock()
    private var fontBoundsCache: NSRect?
    init(familyName: String, pointSize: CGFloat, weight: Weight = .regular,
         italic: Bool = false) {
#if os(Linux)
        _ = BundledFonts.registered
#endif
        storedFamilyName = familyName
        self.pointSize = pointSize
        self.weight = weight
        isItalic = italic
    }
    public convenience init?(descriptor: NSFontDescriptor, size: CGFloat) {
        guard size.isFinite, size > 0, size <= 128 else { return nil }
        self.init(familyName: descriptor.familyName, pointSize: size,
                  weight: descriptor.weight, italic: descriptor.symbolicTraits.contains(.italic))
    }
    public static func systemFont(ofSize size: CGFloat) -> NSFont { NSFont(familyName: "System", pointSize: size) }
    public static func systemFont(ofSize size: CGFloat, weight: Weight) -> NSFont {
        let suffix = weight.rawValue >= Weight.bold.rawValue ? "-Bold" :
            weight.rawValue >= Weight.semibold.rawValue ? "-Semibold" :
            weight.rawValue >= Weight.medium.rawValue ? "-Medium" : ""
        return NSFont(familyName: "System" + suffix, pointSize: size, weight: weight)
    }
    public static func boldSystemFont(ofSize size: CGFloat) -> NSFont {
        NSFont(familyName: "System-Bold", pointSize: size, weight: .bold)
    }
    public static func monospacedSystemFont(ofSize size: CGFloat, weight: Weight = .regular) -> NSFont {
        let suffix = weight.rawValue >= Weight.bold.rawValue ? "-Bold" :
            weight.rawValue >= Weight.semibold.rawValue ? "-Semibold" :
            weight.rawValue >= Weight.medium.rawValue ? "-Medium" : ""
        return NSFont(familyName: "System-Mono" + suffix, pointSize: size, weight: weight)
    }
    public static func monospacedDigitSystemFont(ofSize size: CGFloat, weight: Weight) -> NSFont {
        monospacedSystemFont(ofSize: size, weight: weight)
    }

    public var boundingRectForFont: NSRect {
        fontBoundsLock.withLock {
            if let fontBoundsCache { return fontBoundsCache }
            var metrics = TATFontMetrics(ascent: 0, descent: 0, approximate_width: 0)
            let size = pointSize.isFinite ? max(1, min(128, pointSize)) : 13
            let role: Int32 = weight.rawValue >= Weight.bold.rawValue ? 3 :
                weight.rawValue >= Weight.semibold.rawValue ? 2 :
                weight.rawValue >= Weight.medium.rawValue ? 1 : 0
            let accepted = tat_font_metrics(storedFamilyName.contains("Mono") ? 1 : 0,
                                            role, isItalic ? 1 : 0, Double(size), &metrics)
            let rect = accepted == 1
                ? NSRect(x: 0, y: -metrics.descent, width: metrics.approximate_width,
                         height: metrics.ascent + metrics.descent)
                : NSRect(x: 0, y: 0, width: size, height: size)
            fontBoundsCache = rect
            return rect
        }
    }
    public var ascender: CGFloat { boundingRectForFont.maxY }
    public var descender: CGFloat { boundingRectForFont.minY }
    /// The current Pango font-metrics leaf's line box is ascent plus descent.
    public var leading: CGFloat { 0 }

    public static func == (first: NSFont, second: NSFont) -> Bool {
        if first === second { return true }
        return first.storedFamilyName == second.storedFamilyName && first.pointSize == second.pointSize
            && first.weight == second.weight && first.isItalic == second.isItalic
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(storedFamilyName)
        hasher.combine(pointSize)
        hasher.combine(weight)
        hasher.combine(isItalic)
    }
}

/// The measured trait subset used by the unchanged Markdown parser. Conversion preserves the
/// family, point size, and any existing opposite trait rather than substituting a system font.
public struct NSFontTraitMask: OptionSet, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let italicFontMask = NSFontTraitMask(rawValue: 1)
    public static let boldFontMask = NSFontTraitMask(rawValue: 2)
    public static let unboldFontMask = NSFontTraitMask(rawValue: 4)
    public static let fixedPitchFontMask = NSFontTraitMask(rawValue: 1 << 10)
    public static let unitalicFontMask = NSFontTraitMask(rawValue: 1 << 24)
}

public final class NSFontManager: Sendable {
    public static let shared = NSFontManager()

    public func convert(_ font: NSFont, toSize size: CGFloat) -> NSFont {
        NSFont(familyName: font.fontDescriptor.familyName, pointSize: size,
               weight: font.weight, italic: font.isItalic)
    }

    public func traits(of font: NSFont) -> NSFontTraitMask {
        var traits: NSFontTraitMask = []
        if font.isItalic { traits.insert(.italicFontMask) }
        if font.weight.rawValue >= NSFont.Weight.semibold.rawValue { traits.insert(.boldFontMask) }
        if font.fontDescriptor.symbolicTraits.contains(.monoSpace) { traits.insert(.fixedPitchFontMask) }
        return traits
    }

    public func convert(_ font: NSFont, toHaveTrait traits: NSFontTraitMask) -> NSFont {
        let supported: NSFontTraitMask = [.boldFontMask, .italicFontMask,
                                         .unboldFontMask, .unitalicFontMask]
        precondition(traits.subtracting(supported).isEmpty,
                     "Linux NSFontManager supports bold and italic trait conversion")
        guard !traits.isEmpty else { return font }

        let weight: NSFont.Weight = traits.contains(.unboldFontMask) ? .regular
            : traits.contains(.boldFontMask) ? .bold : font.weight
        let italic = !traits.contains(.unitalicFontMask)
            && (traits.contains(.italicFontMask) || font.isItalic)
        return NSFont(familyName: font.fontDescriptor.familyName, pointSize: font.pointSize,
                      weight: weight, italic: italic)
    }
}

public final class NSAppearance: @unchecked Sendable {
    public let name: Name
    public struct Name: RawRepresentable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let aqua = Name(rawValue: "NSAppearanceNameAqua")
        public static let darkAqua = Name(rawValue: "NSAppearanceNameDarkAqua")
    }
    public init(named name: Name) { self.name = name }
    static let applicationDefault = NSAppearance(named: .aqua)
    private static let drawingKey = "ThreadingShim.NSAppearance.currentDrawing"

    public static func currentDrawing() -> NSAppearance {
        Thread.current.threadDictionary[drawingKey] as? NSAppearance ?? applicationDefault
    }

    public func performAsCurrentDrawingAppearance(_ block: () -> Void) {
        let dictionary = Thread.current.threadDictionary
        let previous = dictionary[Self.drawingKey]
        dictionary[Self.drawingKey] = self
        defer { dictionary[Self.drawingKey] = previous }
        block()
    }
}

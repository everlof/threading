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

/// Field-editor identity for focus scoping. Editing, selection and IME are separate services.
@MainActor
open class NSText: NSView {
    public weak var delegate: AnyObject?
}

/// Font selection for the bounded Pango-backed plain and attributed label paths. Editing,
/// selection, and IME still need separate platform services.
/// The descriptor preserves the selected family and weight when a design role changes its
/// point size. The current bounded Pango leaf distinguishes proportional and mono families;
/// arbitrary installed-family selection remains outside this diagnostic palette.
public final class NSFontDescriptor {
    public let familyName: String
    public let weight: NSFont.Weight

    fileprivate init(familyName: String, weight: NSFont.Weight) {
        self.familyName = familyName
        self.weight = weight
    }
}

public final class NSFont {
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
    public var fontName: String { storedFamilyName }
    public var fontDescriptor: NSFontDescriptor {
        NSFontDescriptor(familyName: storedFamilyName, weight: weight)
    }
    private let fontBoundsLock = NSLock()
    private var fontBoundsCache: NSRect?
    init(familyName: String, pointSize: CGFloat, weight: Weight = .regular) {
        storedFamilyName = familyName
        self.pointSize = pointSize
        self.weight = weight
    }
    public convenience init?(descriptor: NSFontDescriptor, size: CGFloat) {
        guard size.isFinite, size > 0, size <= 128 else { return nil }
        self.init(familyName: descriptor.familyName, pointSize: size,
                  weight: descriptor.weight)
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

    public var boundingRectForFont: NSRect {
        fontBoundsLock.withLock {
            if let fontBoundsCache { return fontBoundsCache }
            var metrics = TATFontMetrics(ascent: 0, descent: 0, approximate_width: 0)
            let size = pointSize.isFinite ? max(1, min(128, pointSize)) : 13
            let role: Int32 = weight.rawValue >= Weight.bold.rawValue ? 3 :
                weight.rawValue >= Weight.semibold.rawValue ? 2 :
                weight.rawValue >= Weight.medium.rawValue ? 1 : 0
            let accepted = tat_font_metrics(storedFamilyName.contains("Mono") ? 1 : 0,
                                            role, Double(size), &metrics)
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

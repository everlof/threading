import Foundation

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

@MainActor
open class NSEvent {
    public init() {}
    open var locationInWindow: NSPoint { .zero }
    open var modifierFlags: ModifierFlags { [] }

    public struct ModifierFlags: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let shift = ModifierFlags(rawValue: 1 << 17)
        public static let control = ModifierFlags(rawValue: 1 << 18)
        public static let option = ModifierFlags(rawValue: 1 << 19)
        public static let command = ModifierFlags(rawValue: 1 << 20)
    }
}

/// Text is the spike's stated non-goal. `NSFont` exists so a component that *names* a font
/// compiles; nothing shapes a glyph. On Linux this is HarfBuzz plus FreeType plus fontconfig,
/// and an IME on top — the largest single item in the draft's platform-leaf list.
@MainActor
public final class NSFont {
    public let pointSize: CGFloat
    public let familyName: String
    init(familyName: String, pointSize: CGFloat) {
        self.familyName = familyName
        self.pointSize = pointSize
    }
    public static func systemFont(ofSize size: CGFloat) -> NSFont { NSFont(familyName: "System", pointSize: size) }
    public static func boldSystemFont(ofSize size: CGFloat) -> NSFont { NSFont(familyName: "System-Bold", pointSize: size) }
    public static func monospacedSystemFont(ofSize size: CGFloat, weight: CGFloat = 0) -> NSFont {
        NSFont(familyName: "System-Mono", pointSize: size)
    }
}

@MainActor
public final class NSAppearance {
    public let name: Name
    public struct Name: RawRepresentable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let aqua = Name(rawValue: "NSAppearanceNameAqua")
        public static let darkAqua = Name(rawValue: "NSAppearanceNameDarkAqua")
    }
    public init(named name: Name) { self.name = name }
    public static var currentDrawing: NSAppearance = NSAppearance(named: .aqua)
}

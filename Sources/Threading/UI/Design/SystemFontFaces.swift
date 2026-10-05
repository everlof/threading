import AppKit
import ObjectiveC
import os

/// The system's design-variant faces — SF Mono, SF Rounded, New York — held for the life of the
/// process, because AppKit does not reliably hold them itself.
///
/// # The defect, measured on macOS 26.5 (25F71)
///
/// `NSFont.monospacedSystemFont(ofSize:weight:)` is imported as non-optional and **returns nil**.
/// UIFoundation keeps one `__NSFontTypefaceInfo` per face in a cache that outlives the face's
/// fonts, but the info refers to its normalized descriptor only *weakly*
/// (`-[__NSFontTypefaceInfo normalizedFontDescriptor]` is an `objc_loadWeak`). Once a string
/// has been laid out in a design-variant face and every font of that face has been released, the
/// descriptor is gone while the info stays cached; the next request for *any size* of the face
/// reads the dead reference in `newPlatformFontWithKey:` and builds nothing. A standalone loop —
/// make an 11 pt SF Mono, measure "abc", drain the pool — gets nil 54 to 225 times in 2,000. Plain
/// `systemFont`, `monospacedDigitSystemFont` and named families never do; a descriptor run
/// through `withDesign(.rounded)` fails the same way, through an initialiser that at least admits
/// it.
///
/// Swift trusts the annotation, so the nil travels as an `NSFont`. In an attribute dictionary it
/// bridges to a nil value, `NSAttributeDictionary` stores it, CoreText finds no font, copies the
/// attributes to add one, and the copy aborts the process:
/// `-[__NSPlaceholderDictionary initWithObjects:forKeys:count:]: attempt to insert nil object`.
/// That is the crash `CommandPaletteRenderTests` hit in two to four of ten processes, inside
/// `ShortcutRecorderView.drawLabel()` — the one label on that screen set in 11 pt SF Mono — and
/// it is the same path in the app whenever nothing else on screen is holding the face. It was
/// twice attributed to the label's dynamic colour, which the crashing dictionary showed was a
/// valid static colour beside `NSFont = (null)`. Font registration plays no part: the test
/// process registers and unregisters no fonts.
///
/// # The rule
///
/// A face this type has vended is **pinned** — one font of it held strongly — so AppKit's weak
/// reference is never the last one. One live font keeps every size of its face buildable, and
/// there is one per face (SF Mono has six), so the table is bounded by what is installed rather
/// than by what is asked for. It is the font and not its descriptor that is held: holding the
/// descriptor is enough for SF Mono but not for a `withDesign` face, which still came back nil
/// 199 times in 2,000 with its descriptor pinned and never with a font pinned.
///
/// A request that arrives before the pin, after someone else's fonts of that face died, is
/// *detected* — through a call whose type admits nil, because a check on the non-optional import
/// may be compiled away (it was, in a Debug test) — and asked again, which rebuilds the face (286
/// of 290 retries in the measurement). Should that also fail, the answer is the user's
/// fixed-pitch font and then the system face: a degraded glyph, never a nil.
///
/// Not main-actor isolated, because `TerminalProfile` resolves its fallback font wherever its
/// profile is read; the table has its own lock.
enum SystemFontFaces {

    // MARK: - Public Methods

    /// SF Mono at `size` and `weight`. Never nil.
    static func monospaced(ofSize size: CGFloat, weight: NSFont.Weight) -> NSFont {
        for _ in 0..<Defaults.attempts {
            if let font = vendMonospaced(ofSize: size, weight: weight) {
                pin(font)
                return font
            }
        }
        return NSFont.userFixedPitchFont(ofSize: size) ?? .systemFont(ofSize: size, weight: weight)
    }

    /// `font` in one of the system's designs, or nil when that design has no face for it.
    static func designed(_ font: NSFont, design: NSFontDescriptor.SystemDesign) -> NSFont? {
        guard let descriptor = font.fontDescriptor.withDesign(design) else { return nil }
        for _ in 0..<Defaults.attempts {
            if let designed = NSFont(descriptor: descriptor, size: font.pointSize) {
                pin(designed)
                return designed
            }
        }
        return nil
    }

    /// Whether the face `font` belongs to is pinned. For tests.
    static func isPinned(_ font: NSFont) -> Bool {
        let name = font.fontName
        return pinned.withLockUnchecked { $0[name] != nil }
    }

    // MARK: - Private

    private enum Defaults {
        /// The first ask and one retry. The retry rebuilds a lost face almost every time; a loop
        /// would only spin on a face the system cannot build at all.
        static let attempts = 2
    }

    /// Face name → the first font vended in it. Never removed from: the point is that the face
    /// outlives every other font made from it.
    private static let pinned = OSAllocatedUnfairLock<[String: NSFont]>(uncheckedState: [:])

    private static func pin(_ font: NSFont) {
        let name = font.fontName
        pinned.withLockUnchecked { faces in
            if faces[name] == nil { faces[name] = font }
        }
    }

    /// `+[NSFont monospacedSystemFontOfSize:weight:]` called through a signature that says what
    /// it can actually return. `NSFontWeight` is a `CGFloat` typedef, so the C signature is exact.
    private typealias MonospacedFactory = @convention(c) (
        AnyClass, Selector, CGFloat, CGFloat
    ) -> Unmanaged<NSFont>?

    private static func vendMonospaced(ofSize size: CGFloat, weight: NSFont.Weight) -> NSFont? {
        let selector = #selector(NSFont.monospacedSystemFont(ofSize:weight:))
        guard let implementation = class_getMethodImplementation(object_getClass(NSFont.self), selector)
        else { return nil }
        let factory = unsafeBitCast(implementation, to: MonospacedFactory.self)
        return factory(NSFont.self, selector, size, weight.rawValue)?.takeUnretainedValue()
    }
}

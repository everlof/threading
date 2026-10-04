import Foundation
import CoreFoundation

/// `Design.swift` imports CoreText for exactly one call — font family *enumeration*, so the font
/// picker can offer what is installed. Not shaping, not metrics, not layout. On Linux that call
/// is fontconfig's `FcFontList`, which is a real but small adapter; the spike returns a fixed
/// list so the rest of the 3,765-line file can be measured.
///
/// One liberty, recorded: the real call returns `CFArray`, and Linux Foundation does not
/// toll-free-bridge a Swift array to one. `NSArray` casts to `[String]` at the call site exactly
/// as `CFArray` does, so `Design.swift` is unmodified — but a real port owes the true signature.
public func CTFontManagerCopyAvailableFontFamilyNames() -> NSArray {
    ["SF Mono", "Menlo", "Monaco", "Helvetica Neue", "DejaVu Sans Mono"] as NSArray
}

public struct CTLine {
    public let attributedString: NSAttributedString
}

public struct CTLineBoundsOptions: OptionSet, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let useGlyphPathBounds = CTLineBoundsOptions(rawValue: 1)
}

public func CTLineCreateWithAttributedString(_ string: NSAttributedString) -> CTLine {
    CTLine(attributedString: string)
}

/// CoreText's per-glyph path bounds are not exposed by this package's fontconfig inventory
/// adapter. A null ink band makes the shared button use its measured baseline fallback.
public func CTLineGetBoundsWithOptions(_ line: CTLine,
                                       _ options: CTLineBoundsOptions) -> CGRect {
    .null
}

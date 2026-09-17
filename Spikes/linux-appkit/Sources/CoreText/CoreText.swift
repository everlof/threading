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

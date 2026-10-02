#if os(macOS)
import CoreGraphics

// Linux Foundation supplies these concrete aliases. In the standalone macOS compiler fixture,
// use the same CoreGraphics geometry that Apple's AppKit would re-export, without loading AppKit.
public typealias NSRect = CGRect
public typealias NSPoint = CGPoint
public typealias NSSize = CGSize

// The raster-only macOS compiler probe does not link the Linux Pango bridge. Keep the shim's
// NSFont source exact; a request for font metrics here is outside this fixture's contract.
public struct TATFontMetrics {
    public var ascent: Double
    public var descent: Double
    public var approximate_width: Double
    public init(ascent: Double, descent: Double, approximate_width: Double) {
        self.ascent = ascent
        self.descent = descent
        self.approximate_width = approximate_width
    }
}

public func tat_font_metrics(_ mono: Int32, _ weight: Int32, _ size: Double,
                             _ result: inout TATFontMetrics) -> Int32 {
    preconditionFailure("raster fixture must not request Pango font metrics")
}

public enum NSLineBreakMode { case byTruncatingTail }

@MainActor
public final class NSTextField: NSView {
    public var lineBreakMode: NSLineBreakMode = .byTruncatingTail
    public convenience init(labelWithString value: String) { self.init(frame: .zero) }
}
#endif

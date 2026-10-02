import Foundation

#if os(macOS)
import CoreGraphics
public typealias NSRect = CGRect
public typealias NSPoint = CGPoint
public typealias NSSize = CGSize
#endif

// Only fixed image colors are exercised; keep the standalone fixture independent of the view
// module while still compiling the current production color shim unchanged.
public final class NSAppearance: @unchecked Sendable {
    public enum Name { case aqua, darkAqua }
    public let name: Name
    public init(name: Name = .aqua) { self.name = name }
    public static func currentDrawing() -> NSAppearance { NSAppearance() }
}

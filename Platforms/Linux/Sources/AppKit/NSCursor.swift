import Foundation

/// Semantic pointer shapes requested by production controls. The SDL host can map `kind` to a
/// platform cursor; retaining this value also lets cursor-rect arbitration be tested headlessly.
@MainActor
public final class NSCursor: Equatable {
    public enum Kind: Equatable, Sendable {
        case arrow, pointingHand, crosshair, resizeLeftRight, resizeUpDown
    }
    public nonisolated let kind: Kind
    private init(_ kind: Kind) { self.kind = kind }

    public static let arrow = NSCursor(.arrow)
    public static let pointingHand = NSCursor(.pointingHand)
    public static let crosshair = NSCursor(.crosshair)
    public static let resizeLeftRight = NSCursor(.resizeLeftRight)
    public static let resizeUpDown = NSCursor(.resizeUpDown)
    public private(set) static var current = arrow

    public func set() { Self.current = self }
    public nonisolated static func == (lhs: NSCursor, rhs: NSCursor) -> Bool {
        lhs.kind == rhs.kind
    }
}

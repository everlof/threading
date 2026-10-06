import Foundation

/// Semantic pointer shapes requested by production controls. The SDL host can map `kind` to a
/// platform cursor; retaining this value also lets cursor-rect arbitration be tested headlessly.
@MainActor
public final class NSCursor: Equatable {
    public enum Kind: Equatable, Sendable {
        case arrow, pointingHand, crosshair, resizeLeftRight, resizeUpDown, iBeam
    }
    public nonisolated let kind: Kind
    private init(_ kind: Kind) { self.kind = kind }

    public static let arrow = NSCursor(.arrow)
    public static let pointingHand = NSCursor(.pointingHand)
    public static let crosshair = NSCursor(.crosshair)
    public static let resizeLeftRight = NSCursor(.resizeLeftRight)
    public static let resizeUpDown = NSCursor(.resizeUpDown)
    public static let iBeam = NSCursor(.iBeam)
    public private(set) static var current = arrow

    /// The native host supplies this while its window is alive. Headless layout fixtures
    /// retain semantic cursor arbitration without initializing a desktop backend.
    public static var platformUpdate: ((Kind) -> Void)?

    public func set() {
        Self.current = self
        Self.platformUpdate?(kind)
    }
    public nonisolated static func == (lhs: NSCursor, rhs: NSCursor) -> Bool {
        lhs.kind == rhs.kind
    }
}

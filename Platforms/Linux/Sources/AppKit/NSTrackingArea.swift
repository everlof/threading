import Foundation

/// Enter/exit tracking for retained AppKit views. Window dispatch updates each installed area
/// against the hit-tested visible tree, so a covered control does not light up underneath it.
@MainActor
public final class NSTrackingArea {
    public struct Options: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let mouseEnteredAndExited = Options(rawValue: 1 << 0)
        public static let activeInKeyWindow = Options(rawValue: 1 << 1)
        public static let activeAlways = Options(rawValue: 1 << 2)
        public static let inVisibleRect = Options(rawValue: 1 << 3)
    }

    public let rect: NSRect
    public let options: Options
    public weak var owner: NSView?
    var isEntered = false

    public init(rect: NSRect, options: Options, owner: NSView, userInfo: [AnyHashable: Any]? = nil) {
        self.rect = rect
        self.options = options
        self.owner = owner
    }
}

import Foundation

/// The event information that can cross the diagnostic SDL/AppKit boundary. Local monitors are
/// invoked in registration order before a window delivers the event to its view tree.
@MainActor
open class NSEvent {
    public enum EventType: Int, Sendable {
        case leftMouseDown, leftMouseUp, leftMouseDragged, mouseMoved, rightMouseDown, keyDown
        case mouseEntered, mouseExited

        var mask: EventTypeMask { EventTypeMask(rawValue: 1 << rawValue) }
        var carriesPointer: Bool {
            switch self {
            case .leftMouseDown, .leftMouseUp, .leftMouseDragged, .mouseMoved,
                 .rightMouseDown, .mouseEntered, .mouseExited: true
            case .keyDown: false
            }
        }
    }

    public struct EventTypeMask: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let leftMouseDown = EventTypeMask(rawValue: 1 << EventType.leftMouseDown.rawValue)
        public static let leftMouseUp = EventTypeMask(rawValue: 1 << EventType.leftMouseUp.rawValue)
        public static let leftMouseDragged = EventTypeMask(rawValue: 1 << EventType.leftMouseDragged.rawValue)
        public static let mouseMoved = EventTypeMask(rawValue: 1 << EventType.mouseMoved.rawValue)
        public static let rightMouseDown = EventTypeMask(rawValue: 1 << EventType.rightMouseDown.rawValue)
        public static let keyDown = EventTypeMask(rawValue: 1 << EventType.keyDown.rawValue)
    }

    public struct ModifierFlags: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let shift = ModifierFlags(rawValue: 1 << 17)
        public static let control = ModifierFlags(rawValue: 1 << 18)
        public static let option = ModifierFlags(rawValue: 1 << 19)
        public static let command = ModifierFlags(rawValue: 1 << 20)
        /// The platform's high-word modifier fields. `KeyboardShortcut` persists only these
        /// bits, then matches the four chord modifiers explicitly at event time.
        public static let deviceIndependentFlagsMask = ModifierFlags(rawValue: 0xffff_0000)
    }

    private final class MonitorToken {
        let id: Int
        init(_ id: Int) { self.id = id }
    }
    private struct Monitor {
        let token: MonitorToken
        let mask: EventTypeMask
        let handler: (NSEvent) -> NSEvent?
    }
    private static var monitors: [Monitor] = []
    private static var nextMonitorID = 0

    private nonisolated let storedType: EventType
    private weak var storedWindow: NSWindow?
    private var storedLocation: NSPoint
    private nonisolated let storedModifiers: ModifierFlags
    private nonisolated let storedKeyCode: UInt16
    private nonisolated let storedCharacters: String?
    public private(set) weak var trackingArea: NSTrackingArea?

    public init(
        type: EventType = .leftMouseDown,
        window: NSWindow? = nil,
        locationInWindow: NSPoint = .zero,
        modifierFlags: ModifierFlags = [],
        keyCode: UInt16 = 0,
        charactersIgnoringModifiers: String? = nil,
        trackingArea: NSTrackingArea? = nil
    ) {
        storedType = type
        storedWindow = window
        storedLocation = locationInWindow
        storedModifiers = modifierFlags
        storedKeyCode = keyCode
        storedCharacters = charactersIgnoringModifiers
        self.trackingArea = trackingArea
    }

    open nonisolated var type: EventType { storedType }
    open var window: NSWindow? { storedWindow }
    open var locationInWindow: NSPoint { storedLocation }
    open nonisolated var modifierFlags: ModifierFlags { storedModifiers }
    open nonisolated var keyCode: UInt16 { storedKeyCode }
    open nonisolated var charactersIgnoringModifiers: String? { storedCharacters }

    /// The host may provide an event without a window; the receiving content window supplies
    /// the owner before local monitors inspect its screen-space location.
    func attach(to window: NSWindow) { storedWindow = window }

    /// AppKit sends an enter/exit event naming the area that crossed. Reusing the pointer
    /// event would make overlapping row and accessory areas indistinguishable to their owner.
    func trackingCrossing(_ type: EventType, area: NSTrackingArea) -> NSEvent {
        NSEvent(type: type, window: window, locationInWindow: locationInWindow,
                modifierFlags: modifierFlags, keyCode: keyCode,
                charactersIgnoringModifiers: charactersIgnoringModifiers, trackingArea: area)
    }

    public static func addLocalMonitorForEvents(
        matching mask: EventTypeMask,
        handler: @escaping (NSEvent) -> NSEvent?
    ) -> Any? {
        guard !mask.isEmpty else { return nil }
        nextMonitorID &+= 1
        let token = MonitorToken(nextMonitorID)
        monitors.append(Monitor(token: token, mask: mask, handler: handler))
        return token
    }

    public static func removeMonitor(_ token: Any) {
        guard let token = token as? MonitorToken else { return }
        monitors.removeAll { $0.token === token }
    }

    /// A handler may remove itself or a later monitor. The snapshot preserves order; membership
    /// is checked before each call so removed monitors are not invoked later in the same event.
    public static func dispatchLocalMonitors(_ event: NSEvent) -> NSEvent? {
        var current: NSEvent? = event
        let snapshot = monitors
        for monitor in snapshot {
            guard let offered = current else { break }
            guard monitors.contains(where: { $0.token === monitor.token }),
                  monitor.mask.contains(offered.type.mask) else { continue }
            current = monitor.handler(offered)
        }
        return current
    }
}

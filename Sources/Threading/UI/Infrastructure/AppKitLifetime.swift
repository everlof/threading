import AppKit
import Foundation

/// The exact event AppKit is dispatching right now, rather than `NSApplication.currentEvent`'s
/// last-dequeued event.
///
/// AppKit leaves `currentEvent` populated after `sendEvent` returns. Components that make a
/// hit-testing decision from that value can therefore answer a later layout, pointer, or
/// accessibility query as if the old event were still in flight. `ThreadingApplication` brackets
/// only the call into AppKit with this context, and the stack preserves the outer event if AppKit
/// enters a nested dispatch.
@MainActor
enum ApplicationEventDispatchContext {
    struct Event {
        let type: NSEvent.EventType
        weak var window: NSWindow?
    }

    private static var events: [Event] = []

    static var current: Event? { events.last }

    static func begin(_ event: NSEvent) {
        events.append(Event(type: event.type, window: event.window))
    }

    static func end() {
        precondition(!events.isEmpty, "Unbalanced application event dispatch context")
        events.removeLast()
    }

    /// Testable form of the application seam. Production always enters through `begin(_:)`,
    /// where the window comes from the real event rather than from a synthetic fixture.
    static func withEvent<T>(
        type: NSEvent.EventType,
        window: NSWindow?,
        perform body: () throws -> T
    ) rethrows -> T {
        events.append(Event(type: type, window: window))
        defer { events.removeLast() }
        return try body()
    }
}

/// Owns one application-local event monitor and removes it exactly once.
///
/// AppKit exposes monitor tokens as `Any`, which is not Sendable. Storing that value directly on
/// a main-actor view made every deinitializer reach for `nonisolated(unsafe)`. The owner below is
/// main-actor confined during use; its private Sendable storage is uniquely owned at teardown and
/// hands an opaque token back to the main queue if destruction ever arrives elsewhere.
@MainActor
public final class LocalEventMonitor {
    private let storage = LocalEventMonitorStorage()

    public var isInstalled: Bool { storage.token != nil }

    public func install(
        matching mask: NSEvent.EventTypeMask,
        handler: @escaping (NSEvent) -> NSEvent?
    ) {
        remove()
        guard let token = NSEvent.addLocalMonitorForEvents(matching: mask, handler: handler) else {
            return
        }
        storage.token = LocalEventMonitorToken(token)
    }

    public func remove() {
        guard let token = storage.token else { return }
        storage.token = nil
        NSEvent.removeMonitor(token.value)
    }
}

private final class LocalEventMonitorStorage: @unchecked Sendable {
    var token: LocalEventMonitorToken?

    deinit {
        guard let token else { return }
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                NSEvent.removeMonitor(token.value)
            }
        } else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    NSEvent.removeMonitor(token.value)
                }
            }
        }
    }
}

/// The opaque AppKit token crosses only the exceptional deinit-to-main handoff above.
private final class LocalEventMonitorToken: @unchecked Sendable {
    let value: Any
    init(_ value: Any) { self.value = value }
}

/// Owns one main-run-loop timer without making every AppKit owner expose actor-isolated state
/// to `deinit` through `nonisolated(unsafe)`.
///
/// Callers still choose the timer's cadence and run-loop mode. This type owns only the lifecycle:
/// installing a replacement invalidates the old generation, explicit shutdown is idempotent, and
/// an owner dropped without shutdown hands its last timer back to the main queue for invalidation.
@MainActor
public final class MainRunLoopTimer {
    private let storage = MainRunLoopTimerStorage()

    public var isInstalled: Bool { storage.timer != nil }

    public func install(_ timer: Timer) {
        invalidate()
        storage.timer = MainRunLoopTimerToken(timer)
    }

    public func invalidate() {
        guard let timer = storage.timer else { return }
        storage.timer = nil
        timer.value.invalidate()
    }
}

private final class MainRunLoopTimerStorage: @unchecked Sendable {
    var timer: MainRunLoopTimerToken?

    deinit {
        guard let timer else { return }
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                timer.value.invalidate()
            }
        } else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    timer.value.invalidate()
                }
            }
        }
    }
}

/// `Timer` is run-loop-bound rather than Sendable; this token crosses only the exceptional
/// deinit-to-main handoff above.
private final class MainRunLoopTimerToken: @unchecked Sendable {
    let value: Timer
    init(_ value: Timer) { self.value = value }
}

import AppKit

/// Supplies the notification layer with one small, process-local answer: whether the owner is
/// actively using Threading on this Mac.
///
/// The event callback can run at key-repeat or trackpad cadence (expected <= 120 Hz, stress 240
/// Hz). It performs one scalar timestamp assignment and returns the same event: O(1), with no
/// model scan, I/O, allocation proportional to application state, or UI mutation.
@MainActor
final class MacNotificationActivityMonitor {
    static let interactionEvents: NSEvent.EventTypeMask = [
        .keyDown,
        .leftMouseDown,
        .rightMouseDown,
        .otherMouseDown,
        .scrollWheel,
    ]

    private let eventMonitor = LocalEventMonitor()
    private let applicationEvents = AppEventObservations()
    private let workspaceEvents = AppEventObservations(
        center: NSWorkspace.shared.notificationCenter
    )
    private let distributedEvents = AppEventObservations(
        center: DistributedNotificationCenter.default()
    )
    private let visibleSessionID: @MainActor @Sendable () -> SessionID?
    private var isStarted = false

    /// `visibleSessionID` is injected so the activation rule can be tested without a window:
    /// coming to the front acknowledges the chat on screen and no other.
    init(
        visibleSessionID: @escaping @MainActor @Sendable () -> SessionID? = {
            AgentRuntime.shared.visibleSessionID
        }
    ) {
        self.visibleSessionID = visibleSessionID
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true

        let notifications = RemoteNotificationService.shared
        let visibleSessionID = visibleSessionID
        // Presence is whether the Mac is in use, not whether Threading is in front. The probe
        // answers for the whole login session and asks for no Accessibility or Input Monitoring
        // grant. The local event monitor below still counts deliberate input *in* Threading as
        // the owner having seen what is on screen; input elsewhere only defers.
        notifications.configureMacInputAge { Self.secondsSinceLastInput() }
        if NSApp.isActive {
            // Installation happens after the main window exists, so an already-active app is a
            // real foreground use even if AppKit posted didBecomeActive before this observer.
            notifications.macApplicationBecameActive(viewing: visibleSessionID())
        } else {
            notifications.setMacApplicationActive(false)
        }

        applicationEvents.observe(NSApplication.didBecomeActiveNotification) {
            notifications.macApplicationBecameActive(viewing: visibleSessionID())
        }
        applicationEvents.observe(NSApplication.didResignActiveNotification) {
            notifications.setMacApplicationActive(false)
        }
        // Leaving the app no longer counts as leaving the Mac; these do. Each is the moment the
        // owner stops being able to see the Mac at all, and a pending completion goes to the
        // phone at once rather than waiting for the last keystroke to age out of the window.
        workspaceEvents.observe(NSWorkspace.sessionDidResignActiveNotification) {
            notifications.setMacAvailable(false)
        }
        workspaceEvents.observe(NSWorkspace.sessionDidBecomeActiveNotification) {
            notifications.setMacAvailable(true)
        }
        workspaceEvents.observe(NSWorkspace.screensDidSleepNotification) {
            notifications.setMacAvailable(false)
        }
        workspaceEvents.observe(NSWorkspace.screensDidWakeNotification) {
            notifications.setMacAvailable(true)
        }
        distributedEvents.observe(MacNotificationActivityDefaults.screenLockedNotification) {
            notifications.setMacAvailable(false)
        }
        distributedEvents.observe(MacNotificationActivityDefaults.screenUnlockedNotification) {
            notifications.setMacAvailable(true)
        }

        eventMonitor.install(matching: Self.interactionEvents) { event in
            notifications.recordMacInteraction(at: event.timestamp)
            return event
        }
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        eventMonitor.remove()
        applicationEvents.removeAll()
        workspaceEvents.removeAll()
        distributedEvents.removeAll()
        RemoteNotificationService.shared.setMacApplicationActive(false)
    }

    /// Seconds since the last input anywhere on this Mac, or `nil` where the platform did not
    /// answer. `CGEventSource` reads the login session's combined event state and needs no TCC
    /// grant; a negative or non-finite answer is treated as no answer.
    nonisolated static func secondsSinceLastInput() -> TimeInterval? {
        guard let anyInput = CGEventType(rawValue: MacNotificationActivityDefaults.anyInputEventType)
        else { return nil }
        let age = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: anyInput
        )
        return age.isFinite && age >= 0 ? age : nil
    }
}

enum MacNotificationActivityDefaults {
    /// `kCGAnyInputEventType`, which the CoreGraphics header defines as every bit set.
    static let anyInputEventType: UInt32 = .max
    /// Posted by loginwindow on the distributed center; no public constant names them.
    static let screenLockedNotification = Notification.Name("com.apple.screenIsLocked")
    static let screenUnlockedNotification = Notification.Name("com.apple.screenIsUnlocked")
}

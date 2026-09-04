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
    private var isStarted = false

    func start() {
        guard !isStarted else { return }
        isStarted = true

        let notifications = RemoteNotificationService.shared
        if NSApp.isActive {
            // Installation happens after the main window exists, so an already-active app is a
            // real foreground use even if AppKit posted didBecomeActive before this observer.
            notifications.recordMacInteraction()
        } else {
            notifications.setMacApplicationActive(false)
        }

        applicationEvents.observe(NSApplication.didBecomeActiveNotification) {
            notifications.recordMacInteraction()
        }
        applicationEvents.observe(NSApplication.didResignActiveNotification) {
            notifications.setMacApplicationActive(false)
        }
        workspaceEvents.observe(NSWorkspace.sessionDidResignActiveNotification) {
            notifications.setMacApplicationActive(false)
        }
        workspaceEvents.observe(NSWorkspace.screensDidSleepNotification) {
            notifications.setMacApplicationActive(false)
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
        RemoteNotificationService.shared.setMacApplicationActive(false)
    }
}

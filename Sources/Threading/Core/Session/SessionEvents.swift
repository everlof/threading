import Foundation
import ThreadingRemoteKit

struct TerminalSessionDidEnd: AppEvent {
    static let name = Notification.Name("terminalSessionDidEnd")
    let sessionID: SessionID
}

struct SessionActivityDidChange: AppEvent {
    static let name = Notification.Name("sessionActivityDidChange")
    let sessionID: SessionID
}

/// Operational lifecycle moved. Unlike `SessionActivityDidChange`, this carries the exact facts
/// and edge so consumers never reconstruct turn completion from a reader-specific UI state.
struct SessionRuntimeDidChange: AppEvent {
    static let name = Notification.Name("sessionRuntimeDidChange")
    let sessionID: SessionID
    let transition: SessionRuntimeTransition
    let cause: SessionActivityCause?
}

/// One chat's live audience moved: somebody joined, left, resized, or started composing.
///
/// Separate from `SessionSharingDidChange` on purpose — who is *watching* changes many times a
/// minute while who *may* watch changes when the owner acts, and the corner card only wants to
/// redraw for the first.
struct SessionFollowersDidChange: AppEvent {
    static let name = Notification.Name("sessionFollowersDidChange")
    let sessionID: SessionID
}

/// A link was created or withdrawn, or somebody's access was revoked.
struct SessionSharingDidChange: AppEvent {
    static let name = Notification.Name("sessionSharingDidChange")
}

/// The live writer mode or controller changed for one shared session.
struct SessionInputControlDidChange: AppEvent {
    static let name = Notification.Name("sessionInputControlDidChange")
    let sessionID: SessionID
}

/// A collaborator asked the current controller to hand them the input stream.
struct SessionInputControlRequested: AppEvent {
    static let name = Notification.Name("sessionInputControlRequested")
    let sessionID: SessionID
    let requesterName: String
}

/// The focused controller is remote and the owner attempted a local terminal gesture.
struct SessionLocalInputBlocked: AppEvent {
    static let name = Notification.Name("sessionLocalInputBlocked")
    let sessionID: SessionID
}

/// An archive an agent asked for has come due: its turn has ended and it can be filed away.
///
/// Announced rather than performed, because the archive is a sidebar action with a receipt on
/// it and `SessionArchiveScheduler` is in Core. See `SessionCoordinator.archiveAtAgentRequest`.
struct SessionArchiveRequestDidBecomeDue: AppEvent {
    static let name = Notification.Name("sessionArchiveRequestDidBecomeDue")
    let sessionID: SessionID
    let reason: String?
    let requestedByManagerID: SessionID?
}

/// A local archive flag changed through provider synchronization.
///
/// `ProjectsDidChange` rebuilds lists, but it deliberately says nothing about the pane currently
/// showing a row that just disappeared. The window observes this narrower lifecycle event to put
/// an externally archived conversation away as completely as one archived from its own menu.
struct SessionArchivedStateDidChange: AppEvent {
    static let name = Notification.Name("sessionArchivedStateDidChange")
    let sessionID: SessionID
    let isArchived: Bool
}

/// A macOS notification about this session was clicked; the window should show it.
struct SessionNotificationOpened: AppEvent {
    static let name = Notification.Name("sessionNotificationOpened")
    let sessionID: SessionID
    let destination: RemoteNotificationDestinationDTO

    init(
        sessionID: SessionID,
        destination: RemoteNotificationDestinationDTO = .session
    ) {
        self.sessionID = sessionID
        self.destination = destination
    }
}

/// Something was scheduled, unscheduled, rescheduled, delivered or given up on.
///
/// Carries no identity: every surface that draws scheduled sends draws a *list* of them, and a
/// per-item event would have each one rebuilding the same list anyway.
struct ScheduledMessagesDidChange: AppEvent {
    static let name = Notification.Name("scheduledMessagesDidChange")
}

/// A scheduled send's moment has arrived.
///
/// Announced rather than performed, for `SessionArchiveRequestDidBecomeDue`'s reason:
/// `ScheduledMessageScheduler` lives in Core and knows nothing about sidebars, surfaces or
/// launching. `SessionCoordinator` performs it — and **claims the record first**, because a send
/// is not idempotent the way an archive is.
struct ScheduledMessageDidBecomeDue: AppEvent {
    static let name = Notification.Name("scheduledMessageDidBecomeDue")
    let id: ScheduledMessageID
}

/// Sends whose moment passed while the app was closed or asleep, gathered for one review.
struct ScheduledMessagesWereMissed: AppEvent {
    static let name = Notification.Name("scheduledMessagesWereMissed")
    let ids: [ScheduledMessageID]
}

/// One session's curfew moved: the rule it follows, or the state that rule has reached.
///
/// Carries the identity, unlike `ScheduledMessagesDidChange`, because everything that listens is
/// about one session — the escape strip, the row's conduct mark, the chat's chip — and the two
/// consumers that *act* on it, the scheduler standing aside and the outbox drain, ask about one
/// target at a time. A list-shaped event would have every row re-resolving a chain that moved
/// for one of them.
struct CurfewDidChange: AppEvent {
    static let name = Notification.Name("curfewDidChange")
    let sessionID: SessionID
}

/// A curfew's grace has run out on a natively rendered turn that is still going.
///
/// Announced rather than performed, for `ScheduledMessageDidBecomeDue`'s reason: the engine that
/// decides this lives in Core and knows nothing about conversation surfaces, while stopping a
/// turn is a gesture on one. `SessionCoordinator` performs it and reports back what became of it,
/// which is what the curfew counts its interrupts from.
struct CurfewInterruptRequested: AppEvent {
    static let name = Notification.Name("curfewInterruptRequested")
    let sessionID: SessionID
}

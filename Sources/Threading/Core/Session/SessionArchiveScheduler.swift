import Foundation

// MARK: - Defaults

enum SessionArchiveDefaults {

    /// How long after the turn ends the archive lands.
    ///
    /// Long enough that the answer the user was waiting for is on screen before the row that
    /// wrote it leaves — a session vanishing on the same frame as its final message reads as a
    /// crash rather than as filing. Short enough that it is plainly part of the same action.
    static let settleDelay: TimeInterval = 1.2

    /// How long a request may wait for a turn that never ends before it is dropped.
    ///
    /// The guard is against a request outliving the conversation it was made in: an armed
    /// archive that never became due would otherwise be spent on the end of some unrelated turn
    /// hours later, which is the one way this could archive a session nobody asked it to.
    static let requestExpiry: TimeInterval = 30 * 60

    /// How much of the agent's reason reaches the receipt. The band is a couple of short lines
    /// in a sidebar column, and this is a fragment naming what was finished, not a summary.
    static let maximumReasonLength = 120
}

// MARK: - Request

/// An archive an agent asked for, waiting for the turn it was asked in to end.
struct PendingSessionArchive: Sendable, Equatable {
    let sessionID: SessionID

    /// The agent's own short account of what it finished, shown on the receipt. Nil when it
    /// gave none.
    let reason: String?

    /// Present only when a user-appointed manager targeted another session.
    let requestedByManagerID: SessionID?

    let requestedAt: Date
}

enum SessionArchiveRequestOutcome: Equatable {
    /// Armed, and will archive when this turn ends.
    case scheduled

    /// A request was already armed for this session; its reason has been replaced by the new one.
    case alreadyPending

    /// Nothing to archive, in prose the agent can pass on.
    case refused(String)
}

enum SessionArchiveCancellation: Equatable {
    case cancelled
    case nothingPending
}

// MARK: - Scheduler

/// Holds an agent's request to archive a session until it is safe to end.
///
/// **The delay is the feature, not a nicety.** Archiving stops the agent, and an agent stopped
/// inside its own tool call never receives the result of that call: the process dies mid-turn,
/// the user loses the answer, and the last thing on screen is a half-written reply. So the tool
/// arms this and returns immediately, the agent finishes speaking, and the archive lands after —
/// which is also the only order in which "commit this and then close the session" reads the way
/// it was said.
///
/// **The turn's end is the app's existing answer to "is it finished".** A self-archive waits
/// for the turn carrying the tool call to end. A manager-targeted archive is admitted only after
/// the control plane has already found the child settled, so it begins the same settle grace from
/// that current state instead of waiting for an activity edge that may never come. This watches
/// `SessionActivityDidChange` and fires on the edge out of `hasTurnInFlight` — the same edge the
/// attention notifications already treat as a finished turn. For a session whose agent reports
/// its own turn boundaries that edge is the agent saying so; for one still on the output
/// heuristic it is a good guess, and this is no better or worse than everything else built on
/// it. The receipt's Undo is what covers the guess being wrong.
///
/// Nothing here knows what an archive looks like. It says when one is due
/// (`SessionArchiveRequestDidBecomeDue`) and `SessionCoordinator`, which owns every other
/// lifecycle decision and the sidebar the receipt appears in, is what performs it.
@MainActor
final class SessionArchiveScheduler {

    // MARK: - Properties

    static let shared = SessionArchiveScheduler()

    /// Settable so a test can watch a request become due without waiting out the settle.
    var settleDelay: TimeInterval = SessionArchiveDefaults.settleDelay

    /// Settable for the same reason: a test cannot wait half an hour to prove a stale request
    /// is dropped rather than spent.
    var requestExpiry: TimeInterval = SessionArchiveDefaults.requestExpiry

    private var pending: [SessionID: PendingSessionArchive] = [:]

    /// The settle timers, one per session, armed when a turn ends and disarmed if the session
    /// starts working again before they fire.
    private var settling: [SessionID: Timer] = [:]

    private let observations: AppEventObservations
    private let activity: @MainActor (SessionID) -> SessionActivity
    private let session: @MainActor (SessionID) -> AgentSession?
    private let center: NotificationCenter

    // MARK: - Initialization

    /// The centre and the two lookups are injected so this can be exercised without a live
    /// agent, a store, or the running app's own event traffic.
    init(
        center: NotificationCenter = .default,
        activity: @escaping @MainActor (SessionID) -> SessionActivity = {
            AgentRuntime.shared.activity(sessionID: $0)
        },
        session: @escaping @MainActor (SessionID) -> AgentSession? = {
            ProjectStore.shared.session(withID: $0)
        }
    ) {
        self.center = center
        self.activity = activity
        self.session = session
        self.observations = AppEventObservations(center: center)

        observations.observe(SessionActivityDidChange.self) { [weak self] event in
            self?.reconcileActivity(for: event.sessionID)
        }
    }

    // MARK: - Public Methods

    /// Records an agent's request to archive its own session when this turn ends.
    ///
    /// Refuses rather than pretends for the two cases where there would be nothing to do, since
    /// an agent told "it is scheduled" will go on to tell the user the same thing.
    @discardableResult
    func request(
        sessionID: SessionID,
        reason: String?,
        requestedByManagerID: SessionID? = nil
    ) -> SessionArchiveRequestOutcome {
        guard let session = session(sessionID) else {
            return .refused("This session is not in Threading's sidebar.")
        }
        guard !session.isArchived else {
            return .refused("This session is already archived.")
        }

        let wasPending = pending[sessionID] != nil
        pending[sessionID] = PendingSessionArchive(
            sessionID: sessionID,
            reason: Self.trimmed(reason),
            requestedByManagerID: requestedByManagerID,
            requestedAt: Date()
        )

        // The caller's own archive request is made inside the turn that must finish before it
        // lands, so only a later activity report may arm it. A manager request is the opposite:
        // `WorkspaceControlPlane` refuses it while the child has a turn in flight. Reconcile that
        // already-settled state now, or an idle child with no future activity event stays pending
        // forever. If the child starts during the grace, the ordinary activity observer disarms
        // the timer and spends the request on the later, real end instead.
        if requestedByManagerID != nil {
            reconcileActivity(for: sessionID)
        }
        return wasPending ? .alreadyPending : .scheduled
    }

    /// Takes a request back. The archive itself is undone from the receipt, not from here.
    @discardableResult
    func cancel(sessionID: SessionID) -> SessionArchiveCancellation {
        disarm(sessionID)
        return pending.removeValue(forKey: sessionID) == nil ? .nothingPending : .cancelled
    }

    func isPending(sessionID: SessionID) -> Bool {
        pending[sessionID] != nil
    }

    func pendingRequest(for sessionID: SessionID) -> PendingSessionArchive? {
        pending[sessionID]
    }

    // MARK: - Private Methods

    /// A request survives the turn going quiet and coming back. A session still on the output
    /// heuristic falls silent in the middle of a turn — the agent is waiting on the model, not
    /// finished — so a session that starts writing again only *disarms* the settle, and the
    /// request is spent on the turn's real end instead of on the pause in the middle of it.
    private func reconcileActivity(for sessionID: SessionID) {
        guard let request = pending[sessionID] else { return }

        guard !activity(sessionID).hasTurnInFlight else {
            disarm(sessionID)
            return
        }

        guard Date().timeIntervalSince(request.requestedAt) < requestExpiry else {
            cancel(sessionID: sessionID)
            return
        }

        guard settling[sessionID] == nil else { return }
        settling[sessionID] = Timer.scheduledTimer(
            withTimeInterval: settleDelay,
            repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.fire(sessionID) }
        }
    }

    /// Announces that the archive is due, having re-checked that there is still one to do: the
    /// user may have archived or deleted the session themselves while the settle ran, and
    /// re-archiving what is already filed would put a second receipt on screen for nothing.
    private func fire(_ sessionID: SessionID) {
        disarm(sessionID)
        guard let request = pending.removeValue(forKey: sessionID) else { return }
        guard let session = session(sessionID), !session.isArchived else { return }

        center.post(
            SessionArchiveRequestDidBecomeDue(
                sessionID: sessionID,
                reason: request.reason,
                requestedByManagerID: request.requestedByManagerID
            )
        )
    }

    private func disarm(_ sessionID: SessionID) {
        settling.removeValue(forKey: sessionID)?.invalidate()
    }

    /// The reason is agent-authored text on its way to a band in the sidebar, so it arrives
    /// bounded and on one line rather than however it was written.
    private static func trimmed(_ reason: String?) -> String? {
        guard let reason else { return nil }
        let flattened = reason
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !flattened.isEmpty else { return nil }
        return String(flattened.prefix(SessionArchiveDefaults.maximumReasonLength))
    }
}

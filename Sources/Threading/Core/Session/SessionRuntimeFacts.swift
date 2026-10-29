import Foundation
import OSLog

enum SessionProcessState: Equatable, Sendable {
    case dormant
    case starting
    case ready
}

enum SessionTurnAuthority: Equatable, Sendable {
    case inferred
    case reported
}

enum SessionTurnState: Equatable, Sendable {
    case none
    case inFlight(SessionTurnAuthority)

    var isInFlight: Bool {
        if case .inFlight = self { return true }
        return false
    }
}

enum SessionContinuationState: String, Equatable, Sendable {
    case none
    case delegated
    case standing

    var isActive: Bool { self != .none }
}

enum SessionRuntimeBlocker: Equatable, Sendable {
    case none
    case awaitingUser
    case usageLimit
}

/// Host-owned work that will wake this conversation independently of provider background tasks.
/// An observation of a future sibling turn is not a dependency on an unfinished result.
enum SessionDependencyState: Equatable, Sendable {
    case none
    case awaitingSessionResult

    var isPending: Bool { self != .none }
}

/// Operational truth kept apart from the reader-specific activity projected into UI.
struct SessionRuntimeSnapshot: Equatable, Sendable {
    let process: SessionProcessState
    let turn: SessionTurnState
    let continuation: SessionContinuationState
    let blocker: SessionRuntimeBlocker
    let activity: SessionActivity
    let reportsOwnTurns: Bool
    let dependency: SessionDependencyState

    init(
        process: SessionProcessState,
        turn: SessionTurnState,
        continuation: SessionContinuationState,
        blocker: SessionRuntimeBlocker,
        activity: SessionActivity,
        reportsOwnTurns: Bool,
        dependency: SessionDependencyState = .none
    ) {
        self.process = process
        self.turn = turn
        self.continuation = continuation
        self.blocker = blocker
        self.activity = activity
        self.reportsOwnTurns = reportsOwnTurns
        self.dependency = dependency
    }

    static let dormant = SessionRuntimeSnapshot(
        process: .dormant,
        turn: .none,
        continuation: .none,
        blocker: .none,
        activity: .dormant,
        reportsOwnTurns: false
    )

    var hasOpenTurn: Bool { turn.isInFlight }
    var hasPendingOutcome: Bool { hasOpenTurn || continuation.isActive || dependency.isPending }

    /// Whether something the *user* is still waiting to read is owed by this conversation.
    ///
    /// An open turn counts, as does a host-owned sibling result or delegated work: a subagent
    /// or a workflow reports back
    /// into this conversation, so the agent will speak again and a caller may wait for it.
    /// Standing work deliberately does not. A shell or a monitor the turn left running may never
    /// end — nothing in the payload separates `npm test` from `npm run dev` — so a caller that
    /// waited on it would be waiting on a condition that is allowed never to arrive.
    ///
    /// This is narrower than `hasPendingOutcome`, which asks whether anything at all is still in
    /// flight. Use that one for "is this session busy"; use this one before spending something
    /// that cannot simply be deferred for ever.
    var awaitsConversationOutcome: Bool { hasOpenTurn || continuation == .delegated || dependency.isPending }
    var isPromptReady: Bool {
        process == .ready && !hasOpenTurn && blocker == .none
    }
    /// Compose host dependencies with provider facts. Keep questions, limits and process state
    /// intact; only an otherwise finished prompt becomes ready with outstanding work.
    func awaiting(_ dependency: SessionDependencyState) -> Self {
        // Exit and a flagged usage limit still settle watches with their distinct refusal
        // reasons. The host retains the notice for a later resume; nothing runs here now.
        let effective: SessionDependencyState = process == .dormant || blocker == .usageLimit
            ? .none : dependency
        let projected: SessionActivity = effective.isPending && isPromptReady
            ? .readyWithBackgroundWork : activity
        return Self(
            process: process, turn: turn, continuation: continuation, blocker: blocker,
            activity: projected, reportsOwnTurns: reportsOwnTurns, dependency: effective
        )
    }

    var canInterrupt: Bool { process == .ready && hasOpenTurn }
    var hasWorkAtRisk: Bool { hasPendingOutcome }
}

struct SessionRuntimeTransition: Equatable, Sendable {
    let previous: SessionRuntimeSnapshot
    let current: SessionRuntimeSnapshot

    var beganTurn: Bool { !previous.hasOpenTurn && current.hasOpenTurn }
    var endedTurn: Bool { previous.hasOpenTurn && !current.hasOpenTurn }
    var beganPendingOutcome: Bool {
        !previous.hasPendingOutcome && current.hasPendingOutcome
    }
    var completedPendingOutcome: Bool {
        previous.hasPendingOutcome && !current.hasPendingOutcome
    }
    var becamePromptReady: Bool { !previous.isPromptReady && current.isPromptReady }
    var becamePromptUnavailable: Bool { previous.isPromptReady && !current.isPromptReady }
}

/// O(1) transition memory for adapters that receive snapshots rather than lifecycle reports.
struct SessionRuntimeTransitionLedger {
    private var lastSnapshot: [SessionID: SessionRuntimeSnapshot] = [:]

    mutating func observe(
        _ snapshot: SessionRuntimeSnapshot,
        for sessionID: SessionID
    ) -> SessionRuntimeTransition {
        let previous = lastSnapshot.updateValue(snapshot, forKey: sessionID) ?? .dormant
        return SessionRuntimeTransition(previous: previous, current: snapshot)
    }

    mutating func remove(_ sessionID: SessionID) {
        lastSnapshot.removeValue(forKey: sessionID)
    }
}

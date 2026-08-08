import Foundation

// MARK: - Control Contract

/// The typed vocabulary of Threading's session control plane.
///
/// Three independent axes, deliberately separate so none can be inferred from another:
/// **who** is asking (`ControlActor`), **what they may see and touch** (`ControlScope`), and
/// **what came of the ask** (the typed outcomes below). The plane that resolves them is
/// `WorkspaceControlPlane`; adapters — the MCP tools first, a CLI or remote client later — own
/// only wording, never rules. See `docs/architecture/control-plane.md`.

/// Who is asking the control plane to act.
///
/// Never something the caller typed: for an agent session the id is the one its MCP URL token
/// resolved to, so a caller cannot claim to be a session it is not.
enum ControlActor: Equatable, Sendable {
    /// An agent session, calling through Threading's own MCP server.
    case agentSession(SessionID)
}

/// What one actor may see and touch.
///
/// Slice one grants every actor exactly its own project. The cases this enum is missing —
/// a session subtree, an explicit project set, the whole workspace — are the point of it being
/// an enum: a broader grant is a new case with its own membership rule, not a loosened check.
enum ControlScope: Equatable, Sendable {
    /// Every unarchived session in one project.
    case project(ProjectID)
}

/// One session, as the control plane describes it to a caller inside its scope.
struct ControlSessionOverview: Equatable, Sendable {
    /// Which input surface is live for the session right now.
    enum Surface: Equatable, Sendable {
        /// A native conversation is up; a message becomes its next turn, or queues visibly
        /// behind the one in flight.
        case chat
        /// An agent TUI owns a PTY; a message can only be typed into it, and only while the
        /// agent is not mid-turn.
        case terminal
        /// No live process. The record resumes by id, but nothing can receive a message.
        case dormant
    }

    let id: SessionID
    let title: String
    let kind: AgentKind
    let activity: SessionActivity
    let surface: Surface
    let isCaller: Bool
    let forkedFrom: SessionID?
}

/// Why the control plane refused, as a value the adapter turns into words.
enum ControlRefusal: Error, Equatable, Sendable {
    /// The caller's own session record is gone — there is no scope to resolve.
    case callerUnknown
    /// No session with that id exists anywhere the caller may know about. Deliberately the
    /// same answer for "does not exist" and "exists outside your scope": telling those apart
    /// would let a caller probe the workspace it was not granted.
    case targetUnknown
    case targetArchived
    /// Messaging yourself is a reply, not a control operation.
    case targetIsCaller
    /// No live surface to deliver to. Resuming a dormant session is the user's decision.
    case targetNotRunning
    /// A terminal surface mid-turn or still booting: typed input would land inside whatever
    /// its TUI has on screen — a permission prompt, a half-written composer line, or the
    /// login shell of a CLI that has not finished starting — so it is refused rather than
    /// delivered somewhere unintended.
    case targetBusy
    case messageEmpty
    case messageTooLong(limit: Int)
    /// The surface was there and still did not take it (mid-launch, a remote participant
    /// holds input authority, the transport just exited).
    case deliveryFailed
    /// A steer needs a live native chat: steering is a stream operation, and a terminal or
    /// dormant session has no wire to steer over.
    case steerNeedsLiveChat
    /// The transport answered for itself: no steering primitive, no active turn to join, or
    /// a turn kind that refuses additions. Passed through, never downgraded to a queue.
    case steerUnavailable(SteerRefusal)
    /// This caller already holds as many watches as one session may. Bounded work: each watch
    /// spends a turn of the watcher's own usage when it fires, so an agent cannot arm a
    /// notice for every session it can see and then be woken by all of them.
    case watcherAtCapacity(limit: Int)
    /// A caller-supplied watch timeout must describe a future deadline. Omitting it is the
    /// distinct, valid request to keep the watch for the rest of this Threading run.
    case invalidWatchTimeout
}

/// How a message should meet the target's current turn.
enum ControlSendDisposition: String, Equatable, Sendable {
    /// Its own turn: now if the target is free, behind the running turn otherwise.
    case queue
    /// Joining the turn already running — additive guidance sharing that turn's context and
    /// budget, refused out loud where the transport cannot or the turn's kind will not.
    case steer
}

/// What became of a message handed to the control plane.
enum ControlSendOutcome: Equatable, Sendable {
    /// On its way as the target's next turn: a chat handed it straight through its visible
    /// queue (a last-moment transport refusal reclaims it there), a terminal was typed into
    /// and submitted.
    case sent(to: ControlSessionOverview)
    /// Parked behind the target's running turn, in the queue rail the user can see and edit.
    /// The queue lives with the running session and is not durable.
    case queued(behind: ControlSessionOverview)
    /// Typed into the target's terminal, and the session never confirmed a turn began. The
    /// message may sit unsent on its screen or have been discarded by a repaint the tracker
    /// cannot see — a compaction, a menu. Neither sent nor refused, and reported as exactly
    /// that: the caller decides whether to look, wait, or resend.
    case typedUnconfirmed(to: ControlSessionOverview)
    /// Joined the target's running turn — no new turn, no queue row; it shares that turn's
    /// context and settles under its terminal event.
    case steered(into: ControlSessionOverview)
    case refused(ControlRefusal)
}

/// What became of an ask to be told when another session settles.
enum ControlWatchOutcome: Equatable, Sendable {
    /// Armed. One notice arrives when the target next settles, exits, or stops at its limit.
    /// `expiresAfter == nil` means there is no wall-clock expiry; the watch still dies with
    /// this run of Threading and remains bounded by `maximumPerWatcher`.
    case armed(on: ControlSessionOverview, expiresAfter: TimeInterval?)
    /// This caller already watches that session; the ask changed nothing and the one notice
    /// still arrives. Coalesced rather than doubled, so a repeated ask cannot buy two notices.
    case alreadyWatching(on: ControlSessionOverview)
    /// The target has no turn in flight now, so there is nothing to be told about: the caller
    /// should read its state instead of waiting for an edge that has already gone by. Not a
    /// refusal — nothing was wrong with the ask, the answer is simply already available.
    case targetAlreadySettled(ControlSessionOverview)
    case refused(ControlRefusal)
}

/// Named budgets for watches, per the bounded-work rule.
enum ControlWatchDefaults {
    /// How many watches one session may hold at once. Each one spends a turn of the watcher's
    /// own usage when it fires, so this is a bound on being woken as much as on memory.
    static let maximumPerWatcher = 8

    /// Fired notices a watcher could not take yet — mid-turn at its own terminal — held for
    /// its next settle edge. Bounded like every input-controlled collection; past the cap new
    /// facts are dropped with a ledger record rather than growing the queue.
    static let maximumHeldNotices = 8

    /// A supplied timeout becomes one timer, and its magnitude does not change the bounded
    /// amount of work held. It must still be finite and in the future so Foundation is never
    /// asked to schedule a nonsensical deadline. Omission, rather than a magic large number,
    /// is how a caller requests no wall-clock expiry.
    static func isValid(timeout: TimeInterval) -> Bool {
        timeout.isFinite && timeout > 0
    }
}

/// Named budgets, per the bounded-work rule.
enum ControlDefaults {
    /// One cross-session message. Generous for a conclusion or a brief; far below anything
    /// that could stand in for a transcript, which `conversation_history` exists for.
    static let maximumMessageLength = 16_384
}

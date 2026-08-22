import Darwin
import Foundation

// MARK: - Single Instance Triage

/// What a launch that lost the lock is allowed to do about it.
///
/// Losing the lock used to have exactly one answer — an alert with one button, then quit — and
/// that answer is wrong twice over. When the owner is a live, healthy Threading the user almost
/// certainly meant to *switch to it*, and being told off for double-clicking the Dock icon is
/// noise. When the owner is wedged, or is a stray Debug copy under DerivedData, the alert is a
/// dead end: the lock is real, nothing on screen answers, and the only way back in is Activity
/// Monitor.
///
/// The rule is a pure function so the whole table can be asserted without a lock, a process or a
/// window, in the shape `OrphanedAgentChildSweep` already uses for the same reason.
///
/// **Fail closed at every ambiguity.** No card, an unreadable card, a pid that no longer means
/// the process the card named, or a card with no heartbeat beside it all end at the alert — the
/// behaviour that shipped. Only a card whose identity still checks out *and* a heartbeat that
/// has stopped can put a destructive choice in front of the user, and even then it is a choice.
enum SingleInstanceTriage {

    // MARK: - Types

    enum Verdict: Equatable {
        /// The owner is alive and answering. Bring it to the front and leave quietly.
        case activateOwner(pid: pid_t, bundlePath: String)
        /// The process that took the lock is gone, and the lock is still held.
        ///
        /// Nothing but a descriptor a dead process left behind can be holding it, and the
        /// likeliest holders are that launch's own orphaned agent children: an `flock` lives on
        /// the open file description and every `forkpty` child inherited one. `O_CLOEXEC` stops
        /// new children inheriting it, but the children of a build that shipped without the flag
        /// survive the upgrade, so this stays reachable.
        case orphanedLockHolders(ownerPID: pid_t, bundlePath: String)
        /// The owner is verifiably itself and has stopped beating. Offer to end it.
        ///
        /// `staleness` is carried because the record of a takeover has to say *how* dead the
        /// owner looked, and it is not recoverable once the file has been replaced.
        case offerTakeover(pid: pid_t, bundlePath: String, staleness: TimeInterval)
        /// Today's behaviour: say what is happening and quit.
        case alertOnly(Refusal)
    }

    /// Journalled verbatim, so the reason a launch refused to offer anything is legible.
    enum Refusal: String {
        /// An owner from before this mechanism existed, a hand-made file, or a torn write.
        case noOwnerCard
        /// The machine would not say whether the pid is still the process that wrote the card.
        /// Distinct from "gone", which is actionable, because the two lead to opposite actions
        /// and a launch that cannot tell them apart must do neither.
        case ownerIdentityUnreadable
        /// A card that checks out with nothing beside it. Silence is not evidence of death.
        case heartbeatMissing
    }

    /// What the machine says about the pid the card names.
    ///
    /// Three answers rather than a `Bool`, because "the owner is gone while its lock is still
    /// held" is a *different* situation from "the owner is unrecognisable" and has a different
    /// remedy. Collapsing them was how the inherited-descriptor lockout had no answer at all.
    enum OwnerIdentity: Equatable {
        /// Alive, and the kernel's start time for it is the card's.
        case confirmed
        /// The pid is gone, or now names something started later. Either way the process that
        /// wrote the card is not running, and the lock it took is still held by somebody.
        case gone
        /// The machine would not say. Nothing may be concluded.
        case unreadable
    }

    // MARK: - Decision

    static func verdict(
        card: SingleInstanceOwnerCard?,
        ownerIdentity: OwnerIdentity,
        heartbeatAge: TimeInterval?
    ) -> Verdict {
        guard let card else { return .alertOnly(.noOwnerCard) }

        switch ownerIdentity {
        case .unreadable:
            return .alertOnly(.ownerIdentityUnreadable)
        case .gone:
            // Reached only because our own acquire was refused, so the lock is demonstrably
            // held — by a descriptor the dead owner handed out, since the owner itself is gone.
            return .orphanedLockHolders(ownerPID: pid_t(card.pid), bundlePath: card.bundlePath)
        case .confirmed:
            break
        }

        guard let heartbeatAge else { return .alertOnly(.heartbeatMissing) }
        guard SingleInstanceHeartbeat.isStale(age: heartbeatAge) else {
            return .activateOwner(pid: pid_t(card.pid), bundlePath: card.bundlePath)
        }
        return .offerTakeover(
            pid: pid_t(card.pid),
            bundlePath: card.bundlePath,
            staleness: heartbeatAge
        )
    }

    /// Whether the pid on the card still means the process that wrote it.
    ///
    /// The sweep's guard exactly: a pid alone is never acted on, because pids are handed out
    /// again and the number on a card written an hour ago may name a browser now. A recycled pid
    /// reads as `gone` rather than as `unreadable` — the *owner* is certainly not running, which
    /// is the fact the verdict turns on, and nothing downstream ever signals that pid.
    static func identity(
        of card: SingleInstanceOwnerCard,
        probe: (pid_t) -> AgentChildProbe = OrphanedAgentChildSweep.liveProbe(of:)
    ) -> OwnerIdentity {
        switch probe(pid_t(card.pid)) {
        case .running(let startTime):
            return startTime == card.startTime ? .confirmed : .gone
        case .absent:
            return .gone
        case .unreadable:
            return .unreadable
        }
    }
}

import Foundation

// MARK: - Dormant Session Census

/// Which sessions Threading knows to have no process behind them.
///
/// This is the *necessary* gate for `ArtifactKind.agentSessionScratch`, and it is stated as a
/// positive set on purpose. The obvious shape — hand the scanner the sessions that are **live**
/// and let it offer everything else — inverts badly at exactly the wrong moment: an empty answer,
/// whether from a bug, a store that has not loaded, or a census taken before restoration
/// finished, would mean *every session directory on the disk is deletable*. A set of the sessions
/// known to be dormant fails the other way. Empty offers nothing.
///
/// It also settles a case no filesystem check can. `/tmp/claude-501/…` is minted by **Claude Code**,
/// not by Threading — Threading only assigns the session id that names the leaf. So a `claude`
/// started by hand in Terminal leaves a directory of exactly the same shape, belonging to a
/// session this app has never heard of. Such an id is not in this set, so it is **refused rather
/// than assumed dead**, and its scratchpad is never offered. Reclaiming it would need proof
/// Threading does not have.
///
/// Measured on 2026-08-17: `/private/tmp/claude-501` held 97 GB across 3,873 session directories,
/// 3,861 of them belonging to sessions that no longer existed. Filesystem evidence could not tell
/// them apart — `lsof` saw an open handle for only 2 of the 14 sessions that were running, because
/// a session that is alive but idle holds nothing open in its own scratchpad. Session state is the
/// only reading that answers.
@MainActor
enum DormantSessionCensus {

    /// The sessions across `projects` that have no terminal allocated.
    ///
    /// `SessionActivity.dormant` is the whole question: it means *no terminal allocated; the
    /// session can be resumed*, which is precisely "no process is writing here". Every other
    /// state — idle included — describes a running agent, and an idle agent is one keystroke from
    /// building in the directory this would otherwise offer.
    static func dormant(in projects: [Project]) -> Set<SessionID> {
        var dormant: Set<SessionID> = []

        for project in projects {
            for session in project.sessions
            where AgentRuntime.shared.activity(sessionID: session.id) == .dormant {
                dormant.insert(session.id)
            }
        }

        return dormant
    }

    /// The same census over every project the store knows, for callers that hold no list of their
    /// own. Kept beside the injectable form so the two cannot disagree about what a session is.
    static func dormant() -> Set<SessionID> {
        dormant(in: ProjectStore.shared.projects)
    }
}

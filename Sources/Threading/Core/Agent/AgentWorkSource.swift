import Foundation

/// Where one session's Activity reading comes from, and therefore what the card may claim.
///
/// The panel used to have one honest state and one dishonest one: work, or `0 of N files` drawn
/// over a complete repository atlas. Zero is a real answer for a chat that read nothing and a lie
/// for a chat nothing is watching, and the picture is identical either way. This is the fact that
/// tells them apart, resolved from what the runtime and the checkout can actually deliver.
///
/// Capability-shaped rather than runtime-shaped: nothing here names an agent. `.transcriptReplay`
/// is the fact that a normalizable local conversation exists, and a turn checkpoint is the fact
/// that this session took a turn in a git checkout — so a sixth runtime is classified the day it
/// earns the one or performs the other, with no edit to this file.
enum AgentWorkSource: Equatable, Sendable {

    /// Threading renders the conversation and records every tool call as it streams.
    case live

    /// The runtime writes a durable local transcript Threading can normalize; `AgentWorkHydration`
    /// folds it in from a persisted resume point.
    case transcript

    /// No per-call source at all. The only evidence is the pair of trees a turn checkpoint
    /// recorded, which says *that* a file changed and never who touched it or whether it was read.
    case gitObserved

    /// Nothing feeds this session. The card says so instead of reporting zeros.
    case unavailable(Reason)

    /// Why a session has no source, because the two cases deserve different sentences.
    enum Reason: Equatable, Sendable {
        /// The runtime keeps no transcript Threading can read. A git-observed floor will appear
        /// once the session has taken a turn in a checkout.
        case runtimeKeepsNoReadableTranscript
        /// The runtime has a readable format, but this session has no transcript yet: it has
        /// never run, or it has not been given an identifier.
        case transcriptNotWrittenYet
    }

    /// Whether reads and edits are facts this session can report at all. A count that cannot be
    /// produced is withheld rather than shown as zero.
    var reportsExactCalls: Bool {
        switch self {
        case .live, .transcript: return true
        case .gitObserved, .unavailable: return false
        }
    }

    /// Whether the card draws its atlas, ribbon and counts at all.
    var hasAnySource: Bool {
        switch self {
        case .live, .transcript, .gitObserved: return true
        case .unavailable: return false
        }
    }

    // MARK: - Resolution

    /// The pure rule, so the classification is testable without a session, a store or a window.
    ///
    /// Ordered by how much each source can say: a rendered conversation sees every call, a
    /// transcript sees every call the runtime wrote down, and a checkpoint pair sees only files.
    static func resolve(
        usesNativeUI: Bool,
        hasReadableTranscript: Bool,
        runtimeKeepsReadableTranscripts: Bool,
        hasTurnCheckpoints: Bool
    ) -> AgentWorkSource {
        if usesNativeUI { return .live }
        if hasReadableTranscript { return .transcript }
        if hasTurnCheckpoints { return .gitObserved }
        return .unavailable(
            runtimeKeepsReadableTranscripts
                ? .transcriptNotWrittenYet
                : .runtimeKeepsNoReadableTranscript
        )
    }
}

// MARK: - Session resolution

extension AgentWorkSource {

    /// The same rule against a live session. Every input is an in-memory lookup or a path built
    /// from one: this is asked on every card refresh, so it reads no file and spawns no process.
    @MainActor
    static func resolve(sessionID: SessionID) -> AgentWorkSource {
        guard let session = ProjectStore.shared.session(withID: sessionID) else {
            return .unavailable(.transcriptNotWrittenYet)
        }
        let project = ProjectStore.shared.executionProject(forSessionID: sessionID)
        let transcript = project.flatMap { SessionTranscript.url(for: session, in: $0) }
        return resolve(
            usesNativeUI: session.usesNativeUI,
            hasReadableTranscript: transcript != nil,
            runtimeKeepsReadableTranscripts: session.kind.supports(.transcriptReplay),
            hasTurnCheckpoints: GitTurnBaselineStore.shared.hasCheckpoints(forSessionID: sessionID)
        )
    }
}

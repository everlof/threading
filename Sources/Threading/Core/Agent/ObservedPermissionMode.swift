import Foundation

// MARK: - Observed Permission Mode

/// The permission mode a session is **in**, as opposed to the one Threading launched it with.
///
/// Every other surface in the app reads `AgentSession.permissionMode` — the record, which states
/// what the next launch will ask for and is edited from the session's `⋯` menu. That record is
/// deliberately not a live mirror: a terminal's own Shift+Tab changes the running agent's posture
/// and writes nothing back, and a session that never chose has no record at all. Anything that
/// wants to *report* the posture rather than set it has to ask here instead.
///
/// **This is the seam, not the reader.** One runtime can answer today and the shape says so out
/// loud rather than by omission: a surface asks here, a runtime declares
/// `AgentCapabilities.transcriptPermissionModeRecord`, and `record(for:)` names what its posture
/// is read out of. Adding a second runtime is those two edits plus a reader — no call site moves,
/// and the exhaustive switch makes a fifth `AgentKind` a build error here rather than a silent
/// `nil` under whichever `else` was written first.
///
/// The one thing it will not do is fall back to the record. A posture is the fact where being
/// confidently wrong is most expensive — Bypass Permissions read off a launch flag the user has
/// since Shift+Tabbed out of is a promise the app cannot keep — so an unobservable runtime, an
/// unreadable transcript and a session that has not started yet all answer nil, and the surfaces
/// asking show nothing.
///
/// A second kind of caller asks the opposite question. `ResolvedPermissionMode` wants the mode a
/// session *will* run in, and takes this as its third source — below the settings that decide the
/// next launch, because what a session got to is not what the next one starts at. That is not the
/// fallback refused above: it is this answer used where it is the only one, and labelled as an
/// observation where it lands.
@MainActor
enum ObservedPermissionMode {

    // MARK: - Types

    /// Where a runtime writes the posture down.
    ///
    /// A named case rather than a bool so the *reason* a runtime can be read survives in the
    /// type: a second one will not necessarily use a transcript, and the day it does not, the
    /// switch below has somewhere to say so.
    enum Record: Equatable {
        /// Claude appends `{"type":"permission-mode","permissionMode":…}` to the session's own
        /// transcript. See `ClaudeTranscriptPermissionMode`.
        case claudeTranscript
    }

    /// One session's readable posture: the file it is in, and the reader that answers for it.
    ///
    /// A value rather than a branch inside each method so the two entry points cannot diverge —
    /// `known` and `revalidate` are the same question asked on and off the main thread, and a
    /// runtime wired into one and not the other would answer from memory for ever.
    private struct Source {
        let url: URL
        let known: @MainActor (URL) -> AgentPermissionMode?
        let revalidate:
            @MainActor (URL, @escaping @MainActor @Sendable (AgentPermissionMode?) -> Void) -> Void
    }

    // MARK: - Public Methods

    /// What a runtime writes its posture into, or nil when it writes none.
    ///
    /// The exhaustive switch is the table and `AgentCapabilities.transcriptPermissionModeRecord`
    /// is the contract surfaces ask before they have a session in hand.
    /// `ObservedPermissionModeTests` holds the two to each other, so a runtime cannot claim the
    /// capability and answer nothing, or answer while claiming nothing.
    static func record(for kind: AgentKind) -> Record? {
        switch kind {
        case .claude:
            return .claudeTranscript

        case .codex, .grok, .openCode, .cursor:
            return nil
        }
    }

    /// What has already been read for this session, or nil when nothing has been or nothing can
    /// be. Touches no disk, so a view may ask while it paints.
    static func known(for session: AgentSession, in project: Project) -> AgentPermissionMode? {
        guard let source = source(for: session, in: project) else { return nil }
        return source.known(source.url)
    }

    /// Re-reads behind the paint, calling back only when the answer moved.
    ///
    /// The completion never fires for a session whose runtime records nothing, which is what
    /// lets a caller ask unconditionally and leave the decision to the table.
    static func revalidate(
        for session: AgentSession,
        in project: Project,
        completion: @escaping @MainActor @Sendable (AgentPermissionMode?) -> Void
    ) {
        guard let source = source(for: session, in: project) else { return }
        source.revalidate(source.url, completion)
    }

    // MARK: - Private Methods

    /// This session's readable posture, or nil where there is none to read.
    ///
    /// A session with no transcript id has not been launched or resumed yet, so there is no file
    /// — the same nil as a runtime that writes no record, and correct for the same reason:
    /// nothing has been observed.
    private static func source(for session: AgentSession, in project: Project) -> Source? {
        switch record(for: session.kind) {
        case .claudeTranscript:
            guard let transcriptID = session.resumeState.transcriptID,
                  let url = ClaudeTranscript.url(sessionID: transcriptID, for: session, in: project)
            else { return nil }

            return Source(
                url: url,
                known: { ClaudeTranscriptPermissionMode.known(at: $0) },
                revalidate: { ClaudeTranscriptPermissionMode.revalidate(at: $0, completion: $1) }
            )

        case nil:
            return nil
        }
    }
}

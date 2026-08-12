import Foundation

// MARK: - Observed Usage Limit

/// Whether a session's agent is stopped on its account's usage limit right now.
///
/// **This is the seam, not the reader**, and the same shape as `ObservedPermissionMode` beside
/// it for the same reason: a surface asks here, a runtime declares
/// `AgentCapabilities.transcriptUsageLimitRecord` and names what its refusal is read out of, and
/// a fifth `AgentKind` is a build error in this file rather than a silent `nil` under whichever
/// `else` was written first.
///
/// It will not guess. A runtime that records nothing answers nil, and so does one whose session
/// has never been launched — the account may well be spent, and `AccountUsageService` can even
/// say so from the toolbar, but "this account has no allowance left" is not the same statement as
/// "this conversation asked and was refused", and only the second one may stop a row's spinner.
@MainActor
enum ObservedUsageLimit {

    // MARK: - Types

    /// Where a runtime writes a refusal down.
    ///
    /// A named case rather than a bool so the *reason* a runtime can be read survives in the
    /// type. A second one need not use a transcript at all — a runtime whose stream states the
    /// refusal is read by the conversation that owns the stream, which is why native sessions do
    /// not come through here.
    enum Record: Equatable {
        /// Claude appends a synthetic assistant record carrying `error: "rate_limit"` to the
        /// session's own transcript. See `ClaudeTranscriptUsageLimit`.
        case claudeTranscript
    }

    // MARK: - Public Methods

    /// What a runtime writes its refusals into, or nil when it writes none.
    ///
    /// The exhaustive switch is the table and `AgentCapabilities.transcriptUsageLimitRecord` is
    /// the contract surfaces ask before they have a session in hand. `ObservedUsageLimitTests`
    /// holds the two to each other, so a runtime cannot claim the capability and answer nothing,
    /// or answer while claiming nothing.
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
    static func known(for session: AgentSession, in project: Project) -> UsageLimitStop? {
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
        completion: @escaping @MainActor @Sendable (UsageLimitStop?) -> Void
    ) {
        guard let source = source(for: session, in: project) else { return }
        source.revalidate(source.url, completion)
    }

    // MARK: - Private Methods

    /// One session's readable refusal: the file it is in, and the reader that answers for it.
    private struct Source {
        let url: URL
        let known: @MainActor (URL) -> UsageLimitStop?
        let revalidate:
            @MainActor (URL, @escaping @MainActor @Sendable (UsageLimitStop?) -> Void) -> Void
    }

    private static func source(for session: AgentSession, in project: Project) -> Source? {
        switch record(for: session.kind) {
        case .claudeTranscript:
            guard let transcriptID = session.resumeState.transcriptID,
                  let url = ClaudeTranscript.url(sessionID: transcriptID, for: session, in: project)
            else { return nil }

            return Source(
                url: url,
                known: { ClaudeTranscriptUsageLimit.known(at: $0) },
                revalidate: { ClaudeTranscriptUsageLimit.revalidate(at: $0, completion: $1) }
            )

        case nil:
            return nil
        }
    }
}

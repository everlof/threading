import AppKit

@MainActor
extension AgentToolCoordinator {

    // MARK: Archive

    /// Asks for this session to be filed away once the turn asking has ended.
    ///
    /// The tool answers immediately and the archive happens later, which is the whole shape of
    /// the feature rather than an implementation detail: archiving stops the agent, and an agent
    /// stopped inside its own tool call never sees the result of it — the user is left looking at
    /// a reply that was cut off mid-sentence by the very thing they asked for. So this arms
    /// `SessionArchiveScheduler` and says so, in words the agent can pass on to the user.
    ///
    /// The session is the one the call arrived on. There is no argument for choosing another,
    /// and the MCP URL is what carries the identity, so an agent cannot file away a conversation
    /// that is not its own.
    func archiveSession(
        _ arguments: ArchiveSessionArguments,
        for sessionID: SessionID
    ) -> MCPToolResult {
        let title = dependencies.projects.session(withID: sessionID)?.displayTitle

        switch dependencies.archiveScheduler.request(
            sessionID: sessionID,
            reason: arguments.reason
        ) {
        case .scheduled, .alreadyPending:
            let name = title.map { "“\($0)”" } ?? "This session"
            return .success("""
                \(name) will be archived when this turn ends. Finish your reply as normal — \
                the session is filed away a moment after it lands, its agent stops, and the \
                user sees a receipt with an Undo on it. Call cancel_session_archive if they \
                change their mind before then.
                """)
        case .refused(let reason):
            return .failure(reason)
        }
    }

    // MARK: Naming

    /// Names the session the call arrived on, after what the conversation turned out to be.
    ///
    /// This writes `agentTitle` — the same slot the terminal title and the transcript's own
    /// `ai-title` land in — and deliberately not `customTitle`. A custom title is the user's
    /// explicit rename, which outranks the agent everywhere and stops the name following it;
    /// an agent that wrote there would be pinning a name the user never chose, and silently
    /// switching off every later update including its own.
    ///
    /// It writes as `.chosen`, which is what keeps the name on screen: the terminal title
    /// re-asserts the CLI's old `ai-title` within seconds and the turn-end transcript read
    /// re-reads the same record, and both used to put the old name straight back. Those
    /// transports write as `.reported` and now lose to this; only another chosen name — or
    /// the user's own rename, which outranks everything — moves it again.
    ///
    /// The name goes through `ProjectStore.updateAgentTitle` rather than being validated here,
    /// so a tool call is held to exactly the rule the two title transports are held to. What
    /// it answers with is what actually happened: a name refused as the agent's, the account's
    /// or the project's own reports as a failure, because an agent told otherwise will tell
    /// the user the session was renamed when the sidebar still says what it said before.
    func setSessionName(
        _ arguments: SetSessionNameArguments,
        for sessionID: SessionID
    ) -> MCPToolResult {
        let requested = (arguments.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requested.isEmpty else {
            return .failure(
                "Provide a name: two to five words describing this conversation."
            )
        }

        let name = String(requested.prefix(ImportDefaults.titleLimit))
        guard let session = dependencies.projects.session(withID: sessionID) else {
            return .failure("This session is no longer in the sidebar.")
        }

        guard dependencies.projects.updateAgentTitle(name, for: sessionID, source: .chosen) else {
            return .failure("""
                “\(name)” was not used: it repeats something the row already shows — the \
                agent's name, the account's, or the project's. Name the conversation \
                instead, in the words that tell it apart from the others in the sidebar.
                """)
        }

        // Two ways the name can be stored and still not be the one on screen. Both are the
        // user's own settled choice rather than a failure, so neither is reported as one —
        // but an agent that said "renamed" with nothing visibly changed would be wrong.
        //
        // Read from the copy taken before the write on purpose: both branches turn on what the
        // agent title does *not* affect — the user's own rename, and a sidebar told to ignore
        // agent titles — so re-reading the session here would answer the same and only suggest
        // the value had moved.
        if let customTitle = session.customTitle, !customTitle.isEmpty {
            return .success("""
                Named “\(name)”. The sidebar still shows “\(customTitle)”, which the user \
                typed themselves — their name outranks yours, and this one takes over if \
                they ever clear it.
                """)
        }

        guard AppSettings.usesAgentTitleInSidebar else {
            return .success("""
                Named “\(name)”. The sidebar is set to ignore agent titles, so the row still \
                reads “\(session.displayTitle)” until that is turned back on under \
                Settings ▸ General.
                """)
        }

        return .success("This session is now called “\(name)”.")
    }

    // MARK: Archive

    /// Takes the pending request back.
    ///
    /// Deliberately not an un-archive: once the row has gone the way back belongs to the user,
    /// on the receipt, and an agent that could reverse its own archive could also reverse theirs.
    func cancelSessionArchive(for sessionID: SessionID) -> MCPToolResult {
        switch dependencies.archiveScheduler.cancel(sessionID: sessionID) {
        case .cancelled:
            return .success("This session is no longer going to be archived.")
        case .nothingPending:
            return .success("""
                Nothing was pending, so nothing changed. If the session has already been \
                archived, the user takes that back from the receipt in the sidebar or from \
                Settings ▸ Archived.
                """)
        }
    }
}

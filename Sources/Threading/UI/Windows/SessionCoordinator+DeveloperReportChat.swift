import AppKit

#if DEBUG

// MARK: - Starting The Chat A Report Opens

/// What actually happens when a development build sends a report to a chat.
///
/// `DeveloperReportChat` owns *which project, configured how, opened with what*; this owns
/// *doing it*, for the reason `SessionCoordinator+ScheduledMessages` exists — the coordinator
/// already owns every lifecycle decision, and a route that reached for its own sidebar would be
/// a second answer to "where does a session appear".
extension SessionCoordinator {

    /// Creates the chat, launches it with the report as its opening prompt, and selects it.
    ///
    /// **Selected, unlike a scheduled start.** That one deliberately does not reach across
    /// whatever the user is reading, because it fires at 09:00 with nobody present. Here the
    /// user pressed a button a moment ago and is waiting to watch the agent read the report, so
    /// the new row coming up is the receipt — the same reason a remotely started session is
    /// selected.
    ///
    /// The launch carries the prompt as a **launch argument or an opening stream message**,
    /// which `launchInBackground` is free to do because this session has never run: there is no
    /// restored conversation for a CLI to ask its summarise-or-read-in-full question about, and
    /// nothing is being typed into a TUI that might be mid-turn.
    func startDeveloperReportChat(
        _ request: DeveloperReportChatRequest,
        fallbackProjectID: ProjectID?
    ) -> DeveloperReportChatOutcome {
        guard let projectID = DeveloperReportChat.targetProjectID(
            projects: environment.projectStore.projects,
            sourceRoot: DeveloperReportChat.sourceRoot,
            fallback: fallbackProjectID
        ), let project = environment.projectStore.project(withID: projectID) else {
            return .failed(message: DeveloperReportChatStrings.noProject)
        }

        let plan = DeveloperReportChat.plan(
            projectID: project.id,
            sessions: project.sessions,
            defaultKind: environment.settings.defaultAgentKind
        )

        // Through the same composer every other new chat uses, so a report chat is not the one
        // chat in the app that ignores the user's standing opening message.
        let opening = NewChatOpeningMessage.compose(
            prompt: DeveloperReportChat.framedReport(request.report),
            prefix: environment.settings.newChatOpeningPrefix,
            suffix: environment.settings.newChatOpeningSuffix
        )

        guard let session = startSessionUnattended(plan: plan, title: request.title) else {
            return .failed(message: DeveloperReportChatStrings.notCreated)
        }
        guard container.launchInBackground(sessionID: session.id, initialPrompt: opening) else {
            return .failed(message: DeveloperReportChatStrings.notStarted)
        }

        environment.eventLog.record(.session, "Report sent to a new chat", [
            "session": session.id.uuidString,
            "project": project.id.uuidString,
            "agent": plan.kind.rawValue,
            "prompt": opening ?? ""
        ])

        sidebar.reload()
        sidebar.select(sessionID: session.id)
        return .started(projectName: project.name)
    }
}

#endif

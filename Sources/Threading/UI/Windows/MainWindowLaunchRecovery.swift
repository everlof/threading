import AppKit

// MARK: - Launch Failure, Answered

/// What the window does with the two offers on the launch-failure surface: file it, or hand it
/// to an agent.
///
/// Split out for `MainWindowStorageTools`' reason — the controller owns the window, the sidebar
/// and the sheets, and a route that reached for its own would be a second answer to "where does
/// a session appear" — and because these three methods are one story: a failure becomes a
/// briefed chat, the chat proposes a repair, and the user decides.
extension MainWindowController {

    // MARK: - Reporting

    func terminalContainer(
        _ container: TerminalContainerViewController,
        didRequestProblemReport failure: SessionLaunchFailure,
        for sessionID: SessionID
    ) {
        let session = ProjectStore.shared.session(withID: sessionID)
        presentReportProblem(
            prefill: (
                title: L10n.format(
                    "%@ could not start",
                    session?.kind.displayName ?? L10n.string("An agent")
                ),
                detail: LaunchFailureReport.body(failure, session: session)
            ),
            surface: "launchFailure"
        )
    }

    // MARK: - Recovery

    /// Prepares a working copy, records the ticket, and opens a chat briefed to repair it.
    ///
    /// Everything that could fail does so before a session exists. A chat created and then left
    /// without a working copy would be an agent asked to repair a file it was never given, which
    /// is the one way this feature could make things worse than the failure it is answering.
    func terminalContainer(
        _ container: TerminalContainerViewController,
        didRequestLaunchRecovery failure: SessionLaunchFailure,
        for sessionID: SessionID
    ) {
        guard let session = ProjectStore.shared.session(withID: sessionID),
              let path = failure.transcriptPath else { return }

        let original = URL(fileURLWithPath: path)
        let workspace = LaunchRecoveryWorkspace()
        let workingCopy: URL
        do {
            workingCopy = try workspace.prepare(original: original, for: sessionID)
        } catch {
            presentLaunchRecoveryProblem(error.localizedDescription)
            return
        }

        guard let recovery = sessionCoordinator.startLaunchRecoveryChat(
            for: session,
            failure: failure,
            original: original,
            workingCopy: workingCopy
        ) else {
            presentLaunchRecoveryProblem(LaunchRecoveryStrings.chatNotCreated)
            return
        }

        do {
            try LaunchRecoveryRegistry(workspace: workspace).write(
                LaunchRecoveryTicket(
                    targetSessionID: sessionID,
                    recoverySessionID: recovery.id,
                    originalPath: original.path,
                    workingCopyPath: workingCopy.path,
                    kind: session.kind
                )
            )
        } catch {
            presentLaunchRecoveryProblem(error.localizedDescription)
            return
        }

        EventLog.shared.record(.session, "Started a conversation repair", [
            "session": sessionID.uuidString,
            "recovery": recovery.id.uuidString,
            "cause": failure.knownCause ?? "unrecognised"
        ])
    }

    // MARK: - The Repair Tool

    /// The recovery agent reporting back.
    ///
    /// Note what is *not* read from the arguments: which conversation this is about. That comes
    /// from the caller's own ticket, so a chat can only ever propose a repair for the file
    /// Threading gave it — see `LaunchRecoveryTicket`.
    func proposeConversationRepair(
        _ arguments: ConversationRepairArguments,
        for sessionID: SessionID,
        completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
    ) {
        let workspace = LaunchRecoveryWorkspace()
        let registry = LaunchRecoveryRegistry(workspace: workspace)
        guard let ticket = registry.ticket(forRecoverySession: sessionID) else {
            completion(.failure(LaunchRecoveryStrings.notARecoveryChat))
            return
        }

        let account = LaunchRecoveryAccount(
            whatWasWrong: arguments.whatWasWrong,
            whatWasDone: arguments.whatWasDone
        )

        // A "could not fix it" report is a complete, useful outcome and takes the short path: it
        // is written down and shown, and nothing is replaced. Only a claimed repair is checked.
        guard arguments.repaired == true, let repairedPath = arguments.repairedPath else {
            presentRepairOutcome(ticket: ticket, account: account, repaired: nil)
            completion(.success(LaunchRecoveryStrings.reportedWithoutRepair))
            return
        }

        do {
            try workspace.verify(
                repaired: URL(fileURLWithPath: repairedPath),
                for: ticket.targetSessionID,
                kind: ticket.kind
            )
        } catch {
            // Refused to the agent rather than to the user: this is a claim Threading could
            // check and found wanting, and the agent is the one that can act on knowing.
            completion(.failure(error.localizedDescription))
            return
        }

        presentRepairOutcome(
            ticket: ticket,
            account: account,
            repaired: URL(fileURLWithPath: repairedPath)
        )
        completion(.success(LaunchRecoveryStrings.repairProposed))
    }

    // MARK: - Private Methods

    /// Shows the user what the agent found and, when there is a checked file, offers to use it.
    private func presentRepairOutcome(
        ticket: LaunchRecoveryTicket,
        account: LaunchRecoveryAccount,
        repaired: URL?
    ) {
        let title = ProjectStore.shared.session(withID: ticket.targetSessionID)?.displayTitle
            ?? L10n.string("this conversation")

        // Through `ConfirmationAlert.choose` rather than a hand-built alert: this is a question
        // with more than one affirmative answer, and the register is what makes "may this be
        // switched off" a decision somebody made rather than a button nobody added.
        var options: [ConfirmationOption] = []
        if repaired != nil {
            options.append(ConfirmationOption(title: L10n.string("Use Repaired File")))
        }
        options.append(ConfirmationOption(title: L10n.string("Report This…")))

        let chosen = ConfirmationAlert.choose(ChoiceRequest(
            prompt: .conversationRepairOutcome,
            title: repaired == nil
                ? L10n.format("“%@” could not be repaired", title)
                : L10n.format("Use the repaired “%@”?", title),
            message: account.sentence(
                repairing: title,
                willReplace: repaired != nil,
                originalName: ticket.original.lastPathComponent
            ),
            options: options,
            cancelTitle: repaired == nil
                ? L10n.string("OK")
                : L10n.string("Keep the Original"),
            style: repaired == nil ? .informational : .warning
        ))

        let acceptedRepair = repaired != nil && chosen == 0
        let choseReport = chosen == (repaired == nil ? 0 : 1)

        if acceptedRepair, let repaired {
            acceptRepair(repaired, ticket: ticket, account: account, conversationTitle: title)
        }
        if choseReport {
            presentRepairReport(
                ticket: ticket,
                account: account,
                conversationTitle: title,
                wasAccepted: acceptedRepair
            )
        }
    }

    /// The diagnosis, as a report the user reads before deciding to send it.
    private func presentRepairReport(
        ticket: LaunchRecoveryTicket,
        account: LaunchRecoveryAccount,
        conversationTitle: String,
        wasAccepted: Bool
    ) {
        presentReportProblem(
            prefill: (
                title: L10n.format("Conversation repair: %@", conversationTitle),
                detail: account.report(
                    conversationTitle: conversationTitle,
                    original: ticket.original,
                    wasAccepted: wasAccepted
                )
            ),
            surface: "conversationRepair"
        )
    }

    /// Puts the checked file in place, clears the failure, and retires the recovery chat.
    private func acceptRepair(
        _ repaired: URL,
        ticket: LaunchRecoveryTicket,
        account: LaunchRecoveryAccount,
        conversationTitle: String
    ) {
        let workspace = LaunchRecoveryWorkspace()
        do {
            try workspace.accept(
                repaired: repaired,
                replacing: ticket.original,
                for: ticket.targetSessionID
            )
        } catch {
            presentLaunchRecoveryProblem(error.localizedDescription)
            return
        }

        // The row is repaired in place: same session, same name, same history, now resumable.
        // The recovery chat has done its job and is archived rather than left as a second row
        // about a conversation that is no longer broken.
        ProjectStore.shared.update(sessionID: ticket.targetSessionID) { stored in
            stored.lastLaunchFailure = nil
        }
        sessionCoordinator.archiveSessionAfterRecovery(
            ticket.recoverySessionID,
            repaired: conversationTitle,
            onReport: { [weak self] in
                self?.presentRepairReport(
                    ticket: ticket,
                    account: account,
                    conversationTitle: conversationTitle,
                    wasAccepted: true
                )
            }
        )
        LaunchRecoveryRegistry(workspace: workspace).forget(
            targetSessionID: ticket.targetSessionID
        )

        EventLog.shared.record(.session, "Accepted a conversation repair", [
            "session": ticket.targetSessionID.uuidString,
            "recovery": ticket.recoverySessionID.uuidString
        ])

        sidebarViewController.reload()
        containerViewController.reopenIfShowing(sessionID: ticket.targetSessionID)
    }

    private func presentLaunchRecoveryProblem(_ detail: String) {
        let alert = ThemedAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.string("Couldn’t set up the repair")
        alert.informativeText = detail
        alert.addButton(withTitle: L10n.string("OK"))
        alert.runModal()
    }
}

// MARK: - What The Agent Said

/// The recovery agent's own account, kept apart from the words Threading wraps it in.
///
/// It is agent-authored text going into an alert and possibly into a ticket, so it is held as
/// data and only ever *shown*: nothing here is parsed, matched or branched on.
struct LaunchRecoveryAccount {

    let whatWasWrong: String?
    let whatWasDone: String?

    /// The sentence in the alert.
    func sentence(
        repairing title: String,
        willReplace: Bool,
        originalName: String
    ) -> String {
        var parts: [String] = []
        if let whatWasWrong, !whatWasWrong.isEmpty {
            parts.append(whatWasWrong)
        }
        if let whatWasDone, !whatWasDone.isEmpty {
            parts.append(whatWasDone)
        }
        if parts.isEmpty {
            parts.append(L10n.string("The agent gave no account of what it found."))
        }
        if willReplace {
            parts.append(L10n.format(
                "Threading has checked the repaired file and will keep a copy of %@ before "
                    + "replacing it.",
                originalName
            ))
        }
        return parts.joined(separator: "\n\n")
    }

    /// The prefilled report body, which is the diagnosis plus what was decided about it.
    func report(conversationTitle: String, original: URL, wasAccepted: Bool) -> String {
        var lines = [
            L10n.format("Conversation: %@", conversationTitle),
            L10n.format("File: %@", original.path),
            wasAccepted
                ? L10n.string("Outcome: the repaired file was accepted.")
                : L10n.string("Outcome: the original was kept.")
        ]
        if let whatWasWrong, !whatWasWrong.isEmpty {
            lines.append("")
            lines.append(L10n.string("What was wrong"))
            lines.append(whatWasWrong)
        }
        if let whatWasDone, !whatWasDone.isEmpty {
            lines.append("")
            lines.append(L10n.string("What was done"))
            lines.append(whatWasDone)
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Launch Failure Report

/// The prefilled body of a report about a launch that failed.
enum LaunchFailureReport {

    static func body(_ failure: SessionLaunchFailure, session: AgentSession?) -> String {
        var lines: [String] = []
        if let session {
            lines.append(L10n.format("Agent: %@", session.kind.displayName))
        }
        lines.append(failure.summary)
        lines.append("")
        lines.append(failure.report)
        return lines.joined(separator: "\n")
    }
}

// MARK: - Strings

enum LaunchRecoveryStrings {

    static var notARecoveryChat: String {
        L10n.string(
            "This chat was not opened to repair a conversation, so there is nothing to propose."
        )
    }

    static var chatNotCreated: String {
        L10n.string("The repair chat could not be created.")
    }

    static var repairProposed: String {
        L10n.string("Reported. The user has been shown what you found and asked to decide.")
    }

    static var reportedWithoutRepair: String {
        L10n.string("Reported. The user has been shown what you found.")
    }
}

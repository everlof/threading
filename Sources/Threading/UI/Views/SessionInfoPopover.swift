import AppKit

/// AppKit presentation adapter for the shared session hover-card body.
final class SessionInfoPopoverViewController: NSViewController {
    typealias Info = SessionInfoCardView.Info

    private let info: Info
    private let isEmbedded: Bool

    init(info: Info, isEmbedded: Bool = false) {
        self.info = info
        self.isEmbedded = isEmbedded
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = SessionInfoCardView(info: info, isEmbedded: isEmbedded)
    }
}

/// macOS gathers the already-owned session facts only when the pointer requests a card.
/// The shared card renders the result without reading a store or launching a process.
@MainActor
extension SessionInfoCardView.Info {
    /// Built from the session, so the row does not have to know how to read git or
    /// resolve accounts.
    init(session: AgentSession, activity: SessionActivity) {
        title = session.displayTitle

        let account = AgentAccountDiscovery.account(
            for: session.kind,
            handle: session.accountHandle
        )
        var line = session.kind.displayName
        if let account, !account.presentation().visibleName.isEmpty {
            line += " · \(account.presentation().visibleName)"
        }

        // A side chat's row shows a fork glyph instead of its agent's mark, so this is
        // where the agent is named — and where the lineage the glyph stands for is spelt
        // out, since the parent's title is not otherwise on the row.
        if let parentID = session.forkedFrom,
           let parent = ProjectStore.shared.session(withID: parentID) {
            line += " · \(SessionPopoverDefaults.sideChatPrefix) \(parent.displayTitle)"
        }

        agentLine = line
        agentIcon = session.kind.icon
        handoffLine = SessionPopoverDefaults.handoffLine(for: session.handoff)

        let supervision = ControlGrantStore.shared.overview(for: session.id)
        if ControlGrantStore.shared.isManager(session.id) {
            let activities = supervision.children.map { AgentRuntime.shared.activity(sessionID: $0) }
            let working = supervision.children.filter {
                AgentRuntime.shared.runtimeSnapshot(sessionID: $0).hasPendingOutcome
            }.count
            let waiting = activities.filter { $0 == .awaitingUser || $0 == .needsAttention }.count
            let detail = [
                working > 0 ? L10n.format("%lld working", Int64(working)) : nil,
                waiting > 0 ? L10n.format("%lld waiting", Int64(waiting)) : nil,
            ].compactMap { $0 }.joined(separator: ", ")
            let count = supervision.children.count
            roleLine = count == 0
                ? L10n.string("Manages no chats yet")
                : L10n.format(
                    "Manages %lld chats%@",
                    Int64(count),
                    detail.isEmpty ? "" : " · \(detail)"
                )
        } else if let parentID = session.subagentParentID,
                  let parent = ProjectStore.shared.session(withID: parentID) {
            // The brief is the tenure's while it lasts; the lineage outlives it.
            let brief = supervision.managedBy == parentID
                ? supervision.brief?.split(whereSeparator: \.isNewline).first.map(String.init)
                : nil
            roleLine = [L10n.format("Subagent of %@", parent.displayTitle), brief]
                .compactMap { $0 }.joined(separator: " · ")
        } else if let managerID = supervision.managedBy,
                  let manager = ProjectStore.shared.session(withID: managerID) {
            let brief = supervision.brief?
                .split(whereSeparator: \.isNewline).first.map(String.init)
            roleLine = [L10n.format("Managed by %@", manager.displayTitle), brief]
                .compactMap { $0 }.joined(separator: " · ")
        } else {
            roleLine = nil
        }

        let project = ProjectStore.shared.executionProject(forSessionID: session.id)
        executionHost = ProjectStore.shared.project(forSessionID: session.id)?.executionHost?.destination
        let folderPath = project?.folderPath
        path = folderPath ?? ""
        // The session's own record first: a dormant session belongs to the branch it
        // ran on, not whatever the checkout has moved to since.
        branch = session.branch ?? folderPath.flatMap { GitInfo.currentBranch(for: $0) }
        worktree = folderPath.flatMap { GitInfo.worktreeName(for: $0) }

        // Read, never resolved: the tracker did the git work once, off the main actor, when
        // the drift was classified. A hover card is not a place to start a child process.
        switch SessionExecutionLocusTracker.shared.drift(forSessionID: session.id) {
        case .none:
            elsewhere = nil
        case .siblingCheckout(let checkout):
            elsewhere = checkout.branch.map {
                SessionPopoverDefaults.elsewhereCheckoutLabel(checkout.displayName, $0)
            } ?? checkout.displayName
        case .unrelated(let path):
            elsewhere = SessionPopoverDefaults.abbreviatingHome(path)
        }

        soundLine = SoundOverrideAudit.toolTipLine(
            for: .session(session.id),
            overrides: session.soundOverrides
        )
        conductLine = RowConductSummary.forSession(session)?.sentence

        dormancyReason = activity == .dormant
            ? SessionRestorationLedger.shared.outcome(for: session.id)
                .flatMap(SessionPopoverDefaults.dormancyReason(for:))
            : nil

        switch activity {
        case .dormant:
            stateText = SessionPopoverDefaults.dormantState
            stateSymbol = SessionPopoverDefaults.dormantSymbol
        case .working:
            stateText = SessionPopoverDefaults.workingState
            stateSymbol = SessionPopoverDefaults.workingSymbol
        case .readyWithBackgroundWork:
            stateText = L10n.string("Ready · background work running")
            stateSymbol = SessionPopoverDefaults.runningSymbol
        case .awaitingUser:
            stateText = SessionPopoverDefaults.waitingState
            stateSymbol = SessionPopoverDefaults.waitingSymbol
        case .needsAttention:
            stateText = SessionPopoverDefaults.finishedState
            stateSymbol = SessionPopoverDefaults.finishedSymbol
        case .idle:
            stateText = SessionPopoverDefaults.runningState
            stateSymbol = SessionPopoverDefaults.runningSymbol
        case .limitReached:
            // Read from what has already been scanned rather than re-read here: the card
            // is built while the pointer rests on a row, and the mark it is explaining was
            // raised by the same reading. A session whose stop is not in memory still says
            // it stopped — the state is the row's, the hint is a detail.
            let hint = project.flatMap {
                ObservedUsageLimit.known(for: session, in: $0)?.resetHint
            }
            stateText = hint.map(SessionPopoverDefaults.limitState(resetHint:))
                ?? SessionPopoverDefaults.limitState
            stateSymbol = SessionPopoverDefaults.limitSymbol
        }
    }
}

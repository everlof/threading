import AppKit
@testable import CoreSlice

/// Supplies the shared hover card from the sidebar's already loaded catalogue and live runtime.
/// Building a card never scans an account, opens a transcript or mounts a hidden conversation.
@MainActor
enum LinuxSessionInfoAdapter {
    static func info(
        for runtime: ProjectSnapshot.SavedRuntime,
        in project: ProjectSnapshot,
        branch: String?,
        worktree: String?,
        activity: NativeSessionActivity?,
        isRunning: Bool
    ) -> SessionInfoCardView.Info {
        let state = state(activity: activity, attention: runtime.attention(at: Date()),
                          isRunning: isRunning)
        let reason = !isRunning
            ? SessionID(uuidString: runtime.id)
                .flatMap { SessionRestorationLedger.shared.outcome(for: $0) }
                .flatMap(SessionPopoverDefaults.dormancyReason(for:))
            : nil
        let account = runtime.account.map { " · \($0)" } ?? ""
        return SessionInfoCardView.Info(
            title: runtime.title,
            agentLine: (runtime.kind?.displayName ?? "Agent") + account,
            agentIcon: runtime.kind.flatMap { ProviderMarks.image(for: $0, selected: false) },
            handoffLine: runtime.handoffLine,
            roleLine: nil,
            path: project.path,
            branch: runtime.branch ?? branch,
            worktree: worktree,
            elsewhere: nil,
            soundLine: nil,
            conductLine: nil,
            executionHost: nil,
            stateText: state.text,
            stateSymbol: state.symbol,
            dormancyReason: reason
        )
    }

    private static func state(
        activity: NativeSessionActivity?,
        attention: AgentSessionRowPresentation.Attention?,
        isRunning: Bool
    ) -> (text: String, symbol: String) {
        guard isRunning else {
            return (SessionPopoverDefaults.dormantState, SessionPopoverDefaults.dormantSymbol)
        }
        switch activity {
        case .working, .loading:
            return (SessionPopoverDefaults.workingState, SessionPopoverDefaults.workingSymbol)
        case .awaitingUser:
            return (SessionPopoverDefaults.waitingState, SessionPopoverDefaults.waitingSymbol)
        case .readyWithBackgroundWork:
            return (L10n.string("Ready · background work running"),
                    SessionPopoverDefaults.runningSymbol)
        case .idle, nil:
            if attention == .woke {
                return (SessionPopoverDefaults.finishedState, SessionPopoverDefaults.finishedSymbol)
            }
            return (SessionPopoverDefaults.runningState, SessionPopoverDefaults.runningSymbol)
        }
    }
}

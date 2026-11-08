import AppKit

@MainActor
enum SubagentAccountApprovalPresenter {
    @MainActor private final class PendingTerminalApproval {
        let request: SubagentAccountApproval
        weak var window: NSWindow?
        let presentation = ConfirmationPresentation()

        init(request: SubagentAccountApproval, window: NSWindow) {
            self.request = request
            self.window = window
        }
    }

    private static var terminalQueue: [PendingTerminalApproval] = []

    static func present(_ request: SubagentAccountApproval, in window: NSWindow?) {
        if let conversation = AgentRuntime.shared.conversation(for: request.parentID) {
            conversation.presentSubagentAccountApproval(request)
            return
        }
        // Terminal parents have no transcript surface to host the card. The same one-shot
        // controls sit in an attributed, non-suppressible confirmation instead.
        guard let window, AgentRuntime.shared.isRunning(sessionID: request.parentID),
              terminalQueue.count < 128,
              terminalQueue.filter({ $0.request.parentID == request.parentID }).count
                < SubagentAccountApproval.maximumPendingPerSession else {
            request.deny()
            return
        }
        let pending = PendingTerminalApproval(request: request, window: window)
        request.onResolution = { [weak pending] in
            guard let pending else { return }
            let wasFirst = terminalQueue.first === pending
            terminalQueue.removeAll { $0 === pending }
            pending.presentation.dismiss()
            if wasFirst { showNextTerminalApproval() }
        }
        terminalQueue.append(pending)
        request.beginWaiting()
        if terminalQueue.count == 1 { showNextTerminalApproval() }
    }

    private static func showNextTerminalApproval() {
        guard let pending = terminalQueue.first else { return }
        let request = pending.request
        guard let window = pending.window,
              AgentRuntime.shared.isRunning(sessionID: request.parentID) else {
            request.deny()
            return
        }
        let parent = ProjectStore.shared.session(withID: request.parentID)?.displayTitle ?? ""
        request.refresh()
        ConfirmationAlert.choose(choiceRequest(request, parentTitle: parent),
            in: window, presentation: pending.presentation) { _ in request.deny() }
    }

    static func choiceRequest(_ request: SubagentAccountApproval, parentTitle: String) -> ChoiceRequest {
        ChoiceRequest(
            prompt: .approveSubagentAccount,
            title: L10n.string("Approve subagent account"),
            message: parentTitle,
            options: [],
            cancelTitle: L10n.string("Cancel"),
            style: .informational,
            accessory: SubagentAccountApprovalCard(request: request).scrollableAccessory()
        )
    }
}

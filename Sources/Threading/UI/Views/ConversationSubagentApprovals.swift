import AppKit

extension ConversationViewController {
    func presentSubagentAccountApproval(_ request: SubagentAccountApproval) {
        _ = view
        guard subagentAccountApprovals.count < SubagentAccountApproval.maximumPendingPerSession else {
            request.deny()
            return
        }
        request.onResolution = { [weak self, weak request] in
            guard let self, let request else { return }
            let wasFirst = self.subagentAccountApprovals.first?.id == request.id
            self.subagentAccountApprovals.removeAll { $0.id == request.id }
            if wasFirst {
                let ownsFocus = (self.view.window?.firstResponder as? NSView).map { responder in
                    self.activeSubagentAccountCard.map { responder.isDescendant(of: $0) } ?? false
                } ?? false
                self.transcript.remove(.surface(.retained(request.id)))
                self.activeSubagentAccountCard = nil
                self.showNextPermissionIfIdle()
                if ownsFocus { self.focusPrompt() }
            }
            self.refreshDecisionStatus()
            self.delegate?.conversationDidChangeActivity(self)
        }
        subagentAccountApprovals.append(request)
        request.beginWaiting()
        if subagentAccountApprovals.count == 1 { showNextPermissionIfIdle() }
        refreshDecisionStatus()
        SessionSnoozeCenter.shared.record(.approvalRequested, for: sessionID)
        delegate?.conversationDidChangeActivity(self)
        if !isVisible { NSApp.requestUserAttention(.informationalRequest) }
    }

    func showNextSubagentAccountApproval() {
        guard activePermissionCard == nil, activeSubagentAccountCard == nil,
              let request = subagentAccountApprovals.first else { return }
        let card = SubagentAccountApprovalCard(request: request)
        activeSubagentAccountCard = card
        card.onLayoutChange = { [weak self] in
            self?.transcript.noteHeightChanged(of: .surface(.retained(request.id)))
        }
        transcript.append(
            PresentationItem(id: .surface(.retained(request.id)), content: .surface(.retained(card))),
            arriving: true)
        request.refresh()
        scrollToBottom()
        NSAccessibility.post(element: card, notification: .layoutChanged)
    }

    func cancelSubagentAccountApprovals() {
        let requests = subagentAccountApprovals
        subagentAccountApprovals.removeAll()
        if let first = requests.first { transcript.remove(.surface(.retained(first.id))) }
        activeSubagentAccountCard = nil
        for request in requests { request.deny() }
    }
}

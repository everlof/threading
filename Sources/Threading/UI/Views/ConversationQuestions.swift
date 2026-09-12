import AppKit

extension ConversationViewController {
    func answerRemoteQuestion(id: String, answers: [String: String]?) -> Bool {
        guard let uuid = UUID(uuidString: id), let card = questionCards[uuid],
              answers.map(card.request.accepts) ?? true else { return false }
        if let answers { card.submit(answers) } else { card.cancelRequest() }
        return true
    }

    func presentQuestion(
        _ request: ConversationQuestionRequest,
        answer: @escaping ([String: String]?) -> Void
    ) {
        _ = view
        guard questionCards[request.id] == nil,
              questionCards.count < ConversationQuestionRequest.Limits.pendingRequests else {
            answer(nil)
            return
        }
        let card = ConversationQuestionCard(request: request) { [weak self] answers in
            self?.removeQuestion(id: request.id)
            answer(answers)
        }
        card.onLayoutChange = { [weak self] in
            self?.transcript.noteHeightChanged(of: .surface(.retained(request.id)))
        }
        questionCards[request.id] = card
        questionOrder.append(request.id)
        refreshDecisionStatus()
        transcript.append(PresentationItem(
            id: .surface(.retained(request.id)), content: .surface(.retained(card))
        ))
        RemoteSessionMirrorRegistry.shared.sessionConversationChanged(sessionID)
        delegate?.conversationDidChangeActivity(self)
        // Use the same follow policy as incoming prose; a reader inspecting older work keeps
        // their position and can return to the live edge with the existing floating control.
        scrollToBottom()
        NSAccessibility.post(element: card, notification: .layoutChanged)
    }

    func removeQuestion(id: UUID) {
        guard let card = questionCards.removeValue(forKey: id) else { return }
        questionOrder.removeAll { $0 == id }
        let responder = view.window?.firstResponder
        let editorOwner = (responder as? NSTextView)?.delegate as? NSView
        let ownsFocus = (responder as? NSView)?.isDescendant(of: card) == true
            || editorOwner?.isDescendant(of: card) == true
        card.invalidate()
        transcript.remove(.surface(.retained(id)))
        refreshDecisionStatus()
        if ownsFocus { focusPrompt() }
        RemoteSessionMirrorRegistry.shared.sessionConversationChanged(sessionID)
        delegate?.conversationDidChangeActivity(self)
    }
}

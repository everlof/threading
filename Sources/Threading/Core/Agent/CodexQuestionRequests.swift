import Foundation

/// Bounded RPC ownership for inline questions. Taking an entry before invoking either callback
/// makes answer, server cancellation and process exit mutually exclusive even under reentrancy.
@MainActor
final class CodexQuestionRequests {
    private var pending: [JSONRPCRequestID: ConversationQuestionRequest] = [:]
    var onPresent: ((ConversationQuestionRequest, @escaping ([String: String]?) -> Void) -> Void)?
    var onResolved: ((UUID) -> Void)?
    var respond: ((JSONRPCRequestID, [String: Any]?, String?) -> Void)?

    func receive(id: JSONRPCRequestID, parameters: [String: Any], threadID: String?, turnID: String?) {
        guard pending[id] == nil else { return }
        guard pending.count < ConversationQuestionRequest.Limits.pendingRequests,
              let threadID, let turnID,
              parameters["threadId"] as? String == threadID,
              parameters["turnId"] as? String == turnID,
              let request = ConversationQuestionRequest.codex(parameters),
              let onPresent else {
            respond?(id, nil, "This question is unsupported, invalid, or no longer belongs to the active turn.")
            return
        }
        pending[id] = request
        onPresent(request) { [weak self] answers in
            guard let self, self.pending[id]?.id == request.id else { return }
            if let answers, !request.accepts(answers) { return }
            self.pending[id] = nil
            if let answers {
                self.respond?(id, ["answers": answers.mapValues { ["answers": [$0]] }], nil)
            } else {
                // Empty answers explicitly decline the form; never choose a suggested option.
                self.respond?(id, ["answers": [String: String]()], nil)
            }
            self.onResolved?(request.id)
        }
    }

    func resolve(id: JSONRPCRequestID) {
        guard let request = pending.removeValue(forKey: id) else { return }
        onResolved?(request.id)
    }

    func invalidate() {
        let requests = pending.values.map(\.id)
        pending.removeAll()
        for id in requests { onResolved?(id) }
    }
}

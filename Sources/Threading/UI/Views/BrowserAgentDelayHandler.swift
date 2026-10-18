import WebKit

/// Agent actionability waits use the host's clock. WebKit can throttle even a 50 ms DOM
/// timer past the entire tool deadline after a tab has been hidden long enough.
/// Installed only in the isolated client world; website scripts cannot request host timers.
@MainActor
final class BrowserAgentDelayHandler: NSObject, WKScriptMessageHandlerWithReply {
    static let name = "threadingAgentDelay"
    static let maximumDelayMilliseconds = 1_000.0
    static let maximumPendingReplies = 64
    private var pendingReplies = 0

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        guard let body = message.body as? [String: Any],
              let token = body["token"] as? String, !token.isEmpty, token.utf8.count <= 128,
              let value = body["milliseconds"] as? NSNumber,
              value.doubleValue.isFinite,
              (0...Self.maximumDelayMilliseconds).contains(value.doubleValue) else {
            replyHandler(nil, "Invalid browser action delay.")
            return
        }
        guard pendingReplies < Self.maximumPendingReplies else {
            replyHandler(nil, "Too many pending browser action delays.")
            return
        }
        guard let page = message.webView else {
            replyHandler(nil, "The browser closed before the action delay.")
            return
        }
        let frame = message.frameInfo
        pendingReplies += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + value.doubleValue / 1_000) { [self, weak page] in
            pendingReplies -= 1
            guard let page else {
                replyHandler(nil, "The browser closed during the action delay.")
                return
            }
            // Resolving only through replyHandler loses WebKit's user-gesture context. Resume
            // the waiting promise inside a fresh API evaluation, so file inputs and pop-ups
            // retain the same activation semantics as the original callAsyncJavaScript action.
            page.callAsyncJavaScript(
                Self.resumeScript,
                arguments: ["token": token],
                in: frame,
                in: .defaultClient
            ) { result in
                switch result {
                case .success: replyHandler(0, nil)
                case .failure: replyHandler(nil, "Could not resume the browser action delay.")
                }
            }
        }
    }

    private static let resumeScript = """
        const pending = globalThis.__threadingAgentDelays;
        const resolve = pending?.get(token);
        if (!resolve) return false;
        pending.delete(token);
        resolve();
        return true;
        """
}

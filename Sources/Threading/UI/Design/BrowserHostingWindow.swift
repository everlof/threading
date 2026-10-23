import AppKit
import WebKit

/// Refuse agent-driven WebKit focus before AppKit asks the current editor to resign.
/// Declining WKWebView.becomeFirstResponder is too late: the editor has already lost focus.
class BrowserHostingWindow: NSWindow {
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        guard BrowserKeyboardFocus.allows(responder, in: self) else { return false }
        return super.makeFirstResponder(responder)
    }
}

@MainActor
enum BrowserKeyboardFocus {
    private static var operationCounts: [ObjectIdentifier: Int] = [:]
    private static var userFocusDepth = 0

    /// One entry per actively driven page, shared across nested bridge/rendering operations.
    static func beginAgentOperation(on page: WKWebView) -> () -> Void {
        let identity = ObjectIdentifier(page)
        operationCounts[identity, default: 0] += 1
        var finished = false
        return {
            guard !finished else { return }
            finished = true
            guard let count = operationCounts[identity] else { return }
            if count == 1 { operationCounts.removeValue(forKey: identity) }
            else { operationCounts[identity] = count - 1 }
        }
    }

    /// A host-owned handoff, such as asking the user to fill a password, is explicit intent.
    static func withUserFocus<T>(_ body: () -> T) -> T {
        userFocusDepth += 1
        defer { userFocusDepth -= 1 }
        return body()
    }

    static func allows(_ responder: NSResponder?, in window: NSWindow) -> Bool {
        guard !operationCounts.isEmpty, userFocusDepth == 0,
              responder !== window.firstResponder else { return true }

        // currentEvent outlives dispatch. Only the actual event-routing scope proves that a
        // person is clicking the page or traversing to it, even during a long agent wait.
        if let event = ApplicationEventDispatchContext.current, event.window === window {
            switch event.type {
            case .leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown: return true
            default: break
            }
        }

        var view = responder as? NSView
        while let candidate = view {
            if operationCounts[ObjectIdentifier(candidate)] != nil { return false }
            view = candidate.superview
        }
        return true
    }
}

import Foundation

/// The point in a document navigation at which an agent action may continue.
enum BrowserNavigationReadiness: String {
    case commit
    case domContentLoaded = "domcontentloaded"
    case load

    var completionMessage: String {
        switch self {
        case .commit:
            return "Navigation committed; the document and subresources may still be loading."
        case .domContentLoaded:
            return "DOMContentLoaded fired; subresources may still be loading."
        case .load:
            return ""
        }
    }
}

/// Owns the race-sensitive lifecycle of one browser navigation request.
///
/// WebKit supplies events through the UI adapter, but supersession, readiness, stale callback
/// rejection, and timeout completion are application behavior. Keeping them here makes those
/// rules testable without constructing a web view or window.
@MainActor
final class BrowserNavigationCoordinator {
    struct NavigationID: Equatable, Sendable {
        fileprivate let rawValue: Int
    }

    enum CommitAction: Equatable {
        case none
        case readDocumentToken(for: NavigationID)
    }

    typealias Completion = (_ success: Bool, _ message: String) -> Void

    private struct TrackedNavigation {
        let id: NavigationID
        let readiness: BrowserNavigationReadiness
        let completion: Completion
        var hasCommitted = false
        var documentToken: String?
        var observedDOMContentLoadedTokens: Set<String> = []
    }

    private var nextID = 0
    private var tracked: TrackedNavigation?

    var hasPendingNavigation: Bool { tracked != nil }

    @discardableResult
    func begin(
        waitUntil readiness: BrowserNavigationReadiness,
        completion: @escaping Completion
    ) -> NavigationID {
        finish(false, "Superseded by a newer navigation.")
        nextID += 1
        let id = NavigationID(rawValue: nextID)
        tracked = TrackedNavigation(
            id: id,
            readiness: readiness,
            completion: completion
        )
        return id
    }

    func isPending(_ id: NavigationID) -> Bool {
        tracked?.id == id
    }

    /// Marks the main document committed and tells the adapter whether it must read the isolated
    /// document token. The token read remains in WebKit; matching it to the current navigation
    /// belongs here.
    func didCommit() -> CommitAction {
        guard var current = tracked else { return .none }
        current.hasCommitted = true
        tracked = current

        switch current.readiness {
        case .commit:
            finish(true, current.readiness.completionMessage)
            return .none
        case .domContentLoaded:
            return .readDocumentToken(for: current.id)
        case .load:
            return .none
        }
    }

    /// Records the token read from the exact committed document. A stale async JavaScript result
    /// is ignored by navigation identity even if a later page happens to reuse the same URL.
    func recordDocumentToken(_ documentToken: String, for id: NavigationID) {
        guard !documentToken.isEmpty,
              var current = tracked,
              current.id == id,
              current.readiness == .domContentLoaded else { return }
        current.documentToken = documentToken
        let alreadyObserved = current.observedDOMContentLoadedTokens.contains(documentToken)
        tracked = current
        if alreadyObserved {
            finish(true, current.readiness.completionMessage)
        }
    }

    /// Records the isolated-world DOM event. It may arrive before or after the document-token
    /// read; completion happens only once both observations name the committed document.
    func observedDOMContentLoaded(_ documentToken: String) {
        guard !documentToken.isEmpty,
              var current = tracked,
              current.readiness == .domContentLoaded else { return }
        current.observedDOMContentLoadedTokens.insert(documentToken)
        if current.observedDOMContentLoadedTokens.count > 8 {
            current.observedDOMContentLoadedTokens = [documentToken]
        }
        let isCurrentDocument = current.hasCommitted && current.documentToken == documentToken
        tracked = current
        if isCurrentDocument {
            finish(true, current.readiness.completionMessage)
        }
    }

    func didFinishLoading() {
        guard let current = tracked else { return }
        finish(true, current.readiness.completionMessage)
    }

    func timeout(_ id: NavigationID, after seconds: TimeInterval) {
        guard let current = tracked, current.id == id else { return }
        finish(
            true,
            "Did not reach \(current.readiness.rawValue) after \(Int(seconds))s; "
                + "returning what has rendered."
        )
    }

    func finish(_ success: Bool, _ message: String) {
        let completion = tracked?.completion
        tracked = nil
        completion?(success, message)
    }
}

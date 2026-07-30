import Foundation

/// Where the window has been: the selection history behind the toolbar's back and forward
/// buttons (⌃⌘← / ⌃⌘→), the way Xcode's Go Back retraces editors.
///
/// A pure value, deliberately: pushing, retracing and pruning are exactly the kind of
/// bookkeeping that grows corner cases (replay must not re-push, a deleted session must fall
/// out of both stacks, adjacent duplicates must not make Back a no-op), and a value type lets
/// tests state each rule without building a window.
///
/// The *owner* decides what a visit is. Only a page actually presented is pushed — and a page
/// presented *by* Back or Forward is not pushed again, which the owner enforces by matching
/// the arriving page against the one it is replaying.
struct NavigationHistory: Equatable {

    /// One thing the content pane can show. A session's conversation, a project's composer,
    /// or a settings page — the same three pages the sidebar can put there.
    enum Page: Equatable, Hashable {
        case session(SessionID)
        case composer(ProjectID)
        case settings(String)
    }

    private(set) var backStack: [Page] = []
    private(set) var forwardStack: [Page] = []
    private(set) var current: Page?

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    /// The page now on screen. Re-visiting the current page is a no-op — selecting the row you
    /// are already reading must not spend a Back step. A genuine visit forks the timeline:
    /// whatever was ahead is gone, as in every browser.
    mutating func visit(_ page: Page) {
        guard page != current else { return }
        if let current { backStack.append(current) }
        current = page
        forwardStack.removeAll()
    }

    /// Steps back and reports the page to present, or nil at the beginning of history.
    mutating func goBack() -> Page? {
        guard let previous = backStack.popLast() else { return nil }
        if let current { forwardStack.append(current) }
        current = previous
        return previous
    }

    /// Steps forward and reports the page to present, or nil at the end of history.
    mutating func goForward() -> Page? {
        guard let next = forwardStack.popLast() else { return nil }
        if let current { backStack.append(current) }
        current = next
        return next
    }

    /// Drops every page the given test refuses — deleted sessions, removed projects — and
    /// collapses what that leaves: adjacent duplicates inside a stack, and a stack ending in
    /// the current page, both of which would make a Back press visibly do nothing.
    mutating func prune(keeping isValid: (Page) -> Bool) {
        backStack = Self.collapsingAdjacentDuplicates(backStack.filter(isValid))
        forwardStack = Self.collapsingAdjacentDuplicates(forwardStack.filter(isValid))
        if let current, !isValid(current) {
            self.current = nil
        }
        while backStack.last != nil, backStack.last == current {
            backStack.removeLast()
        }
        while forwardStack.last != nil, forwardStack.last == current {
            forwardStack.removeLast()
        }
    }

    private static func collapsingAdjacentDuplicates(_ pages: [Page]) -> [Page] {
        pages.reduce(into: []) { result, page in
            if result.last != page { result.append(page) }
        }
    }
}

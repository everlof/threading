import Foundation

/// Owns one window's page-selection timeline and its temporary Settings detour.
///
/// The window controller still knows how to present each page. This coordinator owns which page
/// comes next, which arrival is a replay rather than a fresh visit, and which page Settings must
/// return to. Those transitions are independent of AppKit and can be verified without a window.
@MainActor
final class WindowNavigationCoordinator {
    private var history = NavigationHistory()
    private var pendingReplayTarget: NavigationHistory.Page?
    private var settingsReturnTarget: NavigationHistory.Page?

    var canGoBack: Bool { history.canGoBack }
    var canGoForward: Bool { history.canGoForward }

    /// Records a page that actually arrived. A deferred sidebar callback matching the pending
    /// replay consumes that marker instead of creating a new history branch.
    func recordVisit(_ page: NavigationHistory.Page) {
        if pendingReplayTarget == page {
            pendingReplayTarget = nil
        } else {
            pendingReplayTarget = nil
            history.visit(page)
        }
    }

    func goBack() -> NavigationHistory.Page? {
        guard let target = history.goBack() else { return nil }
        pendingReplayTarget = target
        return target
    }

    func goForward() -> NavigationHistory.Page? {
        guard let target = history.goForward() else { return nil }
        pendingReplayTarget = target
        return target
    }

    /// Remembers the pane Settings replaced. The target is taken exactly once on the ordinary
    /// close path; sideways navigation abandons it because history has become authoritative.
    func beginSettingsDetour(from page: NavigationHistory.Page?) {
        settingsReturnTarget = page
    }

    func takeSettingsReturnTarget() -> NavigationHistory.Page? {
        defer { settingsReturnTarget = nil }
        return settingsReturnTarget
    }

    func abandonSettingsDetour() {
        settingsReturnTarget = nil
    }

    /// Removes destinations that no longer exist from every retained route, including the page
    /// hidden behind Settings. Returning to a deleted session must not resurrect a dead target.
    func prune(keeping isValid: (NavigationHistory.Page) -> Bool) {
        history.prune(keeping: isValid)
        if let pendingReplayTarget, !isValid(pendingReplayTarget) {
            self.pendingReplayTarget = nil
        }
        if let settingsReturnTarget, !isValid(settingsReturnTarget) {
            self.settingsReturnTarget = nil
        }
    }
}

import AppKit

/// Finds the browser an agent's `browser_*` tools act on, wherever the user has put it.
///
/// A browser tab travels: the panel builds it, the drawer adopts it (`TabTransferCoordinator`),
/// and the tools' promise is that they keep working across the move. That promise is about *the
/// session's* browser, not the panel's — so resolution is stated once here, against every host,
/// rather than as a fallback bolted onto one of them. Bolting was the first shape and it leaked:
/// `browser(for:)` consulted the fallback, `activateBrowser` did not and built a second browser
/// beside the user's, and the lease looked its tab up in the panel alone and so refused every
/// page the user had moved.
///
/// Window-owned for the same reason `TabTransferCoordinator` is: only the window sees all the
/// hosts. Order is preference, not merely search order — the panel is where a browser is built
/// and where a session with none gets one, so the panel answers first.
@MainActor
final class SessionBrowserResolver {

    /// A browser and where it was found, so a caller that must *show* what it acted on knows
    /// which host to open rather than assuming the panel.
    struct Location {
        let browser: BrowserViewController
        /// The tab itself, not just its id: a caller listing browsers needs the strip's own
        /// title, and deriving that a second time is how two lists start disagreeing.
        let tab: PaneTab
        let hostID: TabHostID

        var tabID: UUID { tab.id }
    }

    private let hosts: () -> [(TabHostID, SessionBrowserHosting)]

    /// Hosts are supplied as a closure because they outlive nothing and own everything: the
    /// window builds them lazily, and a resolver holding them would be a retain cycle through
    /// the controller that holds it.
    init(hosts: @escaping () -> [(TabHostID, SessionBrowserHosting)]) {
        self.hosts = hosts
    }

    /// One host, for the panel-only case a test or a headless coordinator wants.
    convenience init(panel: SessionBrowserHosting) {
        self.init(hosts: { [(.displayPanel, panel)] })
    }

    /// Every browser-bearing tab the session has, across every host, in host order.
    ///
    /// This exists because the alternative kept being written by hand. The remote workspace
    /// mirror concatenated the panel's tabs and the drawer's with a `+`, and a `+` compiles
    /// unchanged when a host is added — so a new host would have gone missing from the mirror
    /// with nothing failing anywhere, unlike the exhaustive `TabHostID` switches that would have
    /// named themselves. One host list, one definition, and adding a host reaches every reader.
    func locations(for sessionID: SessionID) -> [Location] {
        hosts().flatMap { hostID, host in
            host.browserTabs(for: sessionID).compactMap { tab in
                tab.browser.map { Location(browser: $0, tab: tab, hostID: hostID) }
            }
        }
    }

    /// The browser this session's agent drives, with its host — each host's own preference
    /// first, in host order.
    func location(for sessionID: SessionID) -> Location? {
        for (hostID, host) in hosts() {
            guard let tabID = host.preferredBrowserTabID(for: sessionID),
                  let tab = host.browserTabs(for: sessionID).first(where: { $0.id == tabID }),
                  let browser = tab.browser
            else { continue }
            return Location(browser: browser, tab: tab, hostID: hostID)
        }
        return nil
    }

    func browser(for sessionID: SessionID) -> BrowserViewController? {
        location(for: sessionID)?.browser
    }

    /// Brings a resolved browser to the front of its own host's strip. The host still decides
    /// what activation means; opening the *pane* is the window's job, not this type's.
    func activate(_ location: Location, for sessionID: SessionID) {
        host(location.hostID)?.activateBrowserTab(id: location.tabID, for: sessionID)
    }

    /// The window showing this session's browser — where a prompt about that page belongs.
    ///
    /// Nil when no host holds one, or when the host that does is not on screen; the caller
    /// decides what to fall back to, because "no window" and "the app's main window" are
    /// different answers and only the caller knows whether the difference matters.
    func window(for sessionID: SessionID) -> NSWindow? {
        location(for: sessionID).flatMap { host($0.hostID)?.hostWindow }
    }

    private func host(_ hostID: TabHostID) -> SessionBrowserHosting? {
        hosts().first { $0.0 == hostID }?.1
    }

    /// Where one *particular* browser lives — what a lease re-checks before acting on a page it
    /// resolved earlier. A browser that has been closed, or whose tab moved to a host this
    /// resolver does not know, is correctly nil: the lease is stale either way.
    func location(of browser: BrowserViewController, for sessionID: SessionID) -> Location? {
        locations(for: sessionID).first { $0.browser === browser }
    }
}

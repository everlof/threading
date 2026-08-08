import AppKit
import ThreadingRemoteKit

@MainActor
extension AgentToolCoordinator {
    // MARK: Panel Tabs

    func panelListTabs(for sessionID: SessionID) -> MCPToolResult {
        let tabs = displayPaneController.tabs(for: sessionID)
        guard !tabs.isEmpty else {
            return .success("No tabs are open in this session's display panel.")
        }

        let activeID = displayPaneController.activeTabID(for: sessionID)
        let listed: [PanelTabsPayload.Tab] = tabs.enumerated().map { index, tab in
            var kind = "document"
            var title = tab.title
            if tab.browser != nil {
                kind = "browser"
                if let browser = tab.browser {
                    let pageURL = browser.currentURL
                        ?? browser.restoredURL.flatMap(URL.init(string:))
                    if let pageURL, !hasBrowserAccess(to: pageURL, for: sessionID) {
                        title = "Restricted page"
                    } else if pageURL == nil, browser.restoredURL != nil {
                        title = "Restricted page"
                    }
                }
            } else if tab.review != nil {
                kind = "git review"
            } else if tab.terminal != nil {
                kind = "terminal"
            } else if tab.files != nil {
                kind = "file tree"
            } else if tab.attachments != nil {
                kind = "attachments"
            } else if tab.subagents != nil {
                kind = "subagents"
            } else if tab.extensionPanel != nil {
                kind = "extension panel"
            } else if tab.compare != nil {
                kind = "compare"
            } else if case .image? = tab.content?.body {
                kind = "image"
            }
            return PanelTabsPayload.Tab(
                index: index,
                id: tab.id.uuidString,
                kind: kind,
                title: title,
                active: tab.id == activeID
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        let payload = PanelTabsPayload(count: tabs.count, tabs: listed)
        guard let data = try? encoder.encode(payload),
              let text = String(data: data, encoding: .utf8) else {
            return .failure("Could not list the tabs.")
        }
        return .success(text)
    }

    func panelActivateTab(
        _ arguments: PanelActivateTabArguments,
        for sessionID: SessionID
    ) -> MCPToolResult {
        let activated: Bool
        switch arguments.tab {
        case .index(let index):
            activated = displayPaneController.activateTab(index: index, for: sessionID)
        case .identifier(let string):
            if let index = Int(string) {
                activated = displayPaneController.activateTab(index: index, for: sessionID)
            } else if let id = UUID(uuidString: string) {
                activated = displayPaneController.activateTab(id: id, for: sessionID)
            } else {
                return .failure("Missing or invalid argument: tab (a tab index or id).")
            }
        case nil:
            return .failure("Missing or invalid argument: tab (a tab index or id).")
        }

        guard activated else {
            return .failure("No such tab. Call panel_list_tabs to see what is open.")
        }

        revealDisplayPane(for: sessionID)
        let tab = displayPaneController.tabs(for: sessionID)
            .first { $0.id == displayPaneController.activeTabID(for: sessionID) }
        let title = tab?.title ?? "the tab"
        if let panel = tab?.extensionPanel {
            guard let reference = dependencies.notificationTargets.issue(
                .extensionPanel(
                    extensionIdentifier: panel.extensionIdentifier,
                    panelID: panel.panelID
                ),
                for: sessionID
            ) else { return .success("Activated \"\(title)\".") }
            return .targeted(
                "Activated \"\(title)\".",
                reference: reference,
                kind: "extensionPanel"
            )
        }
        if let browser = tab?.browser,
           let location = browserResolver.location(of: browser, for: sessionID) {
            guard let reference = dependencies.notificationTargets.issue(
                .browserTab(id: location.tabID.uuidString.lowercased()),
                for: sessionID
            ) else { return .success("Activated \"\(title)\".") }
            return .targeted(
                "Activated \"\(title)\".",
                reference: reference,
                kind: "browserTab"
            )
        }
        return .success("Activated \"\(title)\".")
    }

    /// Opens the display pane if the request came from the session on screen; a background
    /// session's panel waits until it is selected, exactly as its content does.
    @discardableResult
    func revealDisplayPane(for sessionID: SessionID) -> Bool {
        let isVisible = sessionID == visibleSessionID()
        if isVisible {
            displayPaneController.showSession(sessionID)
            setPaneVisible(true)
        }
        return isVisible
    }

    /// The same courtesy for a tool that drove *the browser* rather than filled the panel:
    /// opens whichever pane holds it, resolving that itself.
    ///
    /// Most browser tools know only that they acted on the session's browser, so this is the
    /// form nearly all of them want. A session with no browser at all falls back to the panel,
    /// which is where one would be built.
    @discardableResult
    func revealBrowserPane(for sessionID: SessionID) -> Bool {
        guard let location = browserResolver.location(for: sessionID) else {
            return revealDisplayPane(for: sessionID)
        }
        return revealBrowserPane(for: sessionID, hostID: location.hostID)
    }

    /// The form for a caller that has just resolved a location and should not pay to resolve it
    /// twice. Showing the panel after driving a browser the user keeps in the drawer would open
    /// an unrelated pane and leave the page that moved off screen.
    @discardableResult
    func revealBrowserPane(for sessionID: SessionID, hostID: TabHostID) -> Bool {
        let isVisible = sessionID == visibleSessionID()
        if isVisible {
            if hostID == .displayPanel {
                displayPaneController.showSession(sessionID)
            }
            revealBrowserHost(hostID)
        }
        return isVisible
    }

}

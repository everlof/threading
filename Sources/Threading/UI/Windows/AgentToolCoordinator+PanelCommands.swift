import AppKit

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
        let title = displayPaneController.tabs(for: sessionID)
            .first { $0.id == displayPaneController.activeTabID(for: sessionID) }?.title ?? "the tab"
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

}

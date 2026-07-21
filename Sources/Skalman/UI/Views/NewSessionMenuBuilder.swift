import AppKit

/// Identifies the agent and account a "new session" menu item will start.
final class NewSessionRequest: NSObject {
    let kind: AgentKind
    let accountHandle: String?

    init(kind: AgentKind, accountHandle: String?) {
        self.kind = kind
        self.accountHandle = accountHandle
    }
}

/// Builds the "new session" menu items, shared by the main menu and the sidebar's
/// context menu so both offer the same agents and accounts.
enum NewSessionMenuBuilder {

    // MARK: - Public Methods

    /// Appends one item per agent, expanding agents with multiple logins into a submenu of
    /// accounts. An agent with a single account stays a flat item, so the common
    /// single-login setup gains no extra nesting.
    static func addItems(to menu: NSMenu, target: AnyObject, action: Selector) {
        for kind in AgentKind.allCases {
            let accounts = AgentAccountDiscovery.accounts(for: kind)

            guard kind.supportsAccounts, accounts.count > 1 else {
                menu.addItem(makeItem(
                    title: "New \(kind.displayName) Session",
                    request: NewSessionRequest(kind: kind, accountHandle: nil),
                    target: target,
                    action: action
                ))
                continue
            }

            let submenu = NSMenu()
            for account in accounts {
                submenu.addItem(makeItem(
                    title: account.displayName,
                    request: NewSessionRequest(kind: kind, accountHandle: account.handle),
                    target: target,
                    action: action
                ))
            }

            let parent = NSMenuItem(title: "New \(kind.displayName) Session", action: nil, keyEquivalent: "")
            parent.submenu = submenu
            menu.addItem(parent)
        }
    }

    // MARK: - Private Methods

    private static func makeItem(
        title: String,
        request: NewSessionRequest,
        target: AnyObject,
        action: Selector
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.representedObject = request
        item.target = target
        return item
    }
}

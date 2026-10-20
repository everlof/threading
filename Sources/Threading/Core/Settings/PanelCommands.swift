import Foundation

/// Panel creation is a host command by default. Menus contribute presentation, never closures
/// with a separate implementation. Dynamic targets retain values, not constructed controllers.
enum PanelCommandTarget: Equatable {
    case simulator, androidDevice, realDevice, audit, browser, privateBrowser, overview, compare
    case supervision
    case notificationTest, webExtensions
    case nativePlugin(URL)
    case nativePluginSection(identifier: String, section: String)
    case extensionPanel(identifier: String, panelID: String)
}

enum PanelCommands {
    struct Entry {
        let id: String
        let title: String
        let icon: String
        let target: PanelCommandTarget?
        /// What the command palette shows under the title, and searches.
        var detail: String? = nil
    }

    static let entries: [Entry] = [
        Entry(id: AppCommands.ID.newTerminalTab, title: "Terminal", icon: "terminal", target: nil),
        Entry(id: "panel.simulator", title: "iOS Simulator", icon: "iphone", target: .simulator),
        // Both open the one Simulator workspace; each brings its own platform, beside the other's.
        Entry(id: "panel.android", title: "Android Emulator", icon: "candybarphone", target: .androidDevice,
              detail: "Show an Android emulator or a USB Android phone, beside any iOS Simulator"),
        Entry(id: "panel.realDevice", title: "iPhone Device", icon: "iphone.gen2", target: .realDevice,
              detail: "Preview and control a paired physical iPhone"),
    ] + NativePluginManagedOffer.all.flatMap { offer in
        offer.paneSections.compactMap { section -> Entry? in
            guard let command = section.command else { return nil }
            return Entry(
                id: command.id, title: command.titleKey, icon: command.symbol,
                target: .nativePluginSection(
                    identifier: offer.identifier, section: section.identifier
                ), detail: command.detailKey
            )
        }
    } + [
        Entry(id: "panel.notificationTest", title: "Push Test", icon: "bell.badge",
              target: .notificationTest,
              detail: "Send a test notification from this chat to the Mac or iPhone"),
        Entry(id: "panel.audit", title: "Execution audit", icon: "checklist.checked", target: .audit),
        Entry(id: "panel.browser", title: "New Browser", icon: "globe", target: .browser),
        Entry(id: "panel.webExtensions", title: "Web Extensions", icon: "puzzlepiece.extension", target: .webExtensions,
              detail: "Build, run and debug browser extensions across browsers"),
        Entry(id: "panel.privateBrowser", title: "Private Browser", icon: "hand.raised.fill", target: .privateBrowser),
        Entry(id: "panel.overview", title: "Overview", icon: "rectangle.grid.1x2", target: .overview),
        Entry(id: AppCommands.ID.review, title: "Review", icon: "plus.forwardslash.minus", target: nil),
        Entry(id: "panel.compare", title: "Compare Files…", icon: "rectangle.on.rectangle", target: .compare),
        Entry(id: AppCommands.ID.attachments, title: "Attachments", icon: "paperclip", target: nil)
    ]
    static let supervision = Entry(id: "panel.supervision", title: "Chats", icon: "person.3", target: .supervision)

    static let additionalCommands: [AppCommand] = (entries + [supervision]).compactMap { entry in
        guard let target = entry.target else { return nil }
        return AppCommand(id: entry.id, group: .view, title: entry.title, detail: entry.detail,
                          defaultShortcut: nil, isEditable: true, scope: .session,
                          iconName: entry.icon, panelTarget: target)
    }

    static func nativePluginID(_ url: URL) -> String {
        "panel.native." + url.lastPathComponent
    }

    static func nativePluginSectionID(identifier: String, section: String) -> String {
        "panel.nativeSection.\(identifier).\(section)"
    }

    static func extensionPanelID(identifier: String, panelID: String) -> String {
        "panel.extension.\(identifier).\(panelID)"
    }
}

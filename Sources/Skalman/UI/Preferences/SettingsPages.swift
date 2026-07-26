import AppKit
import SkalmanExtensionKit

/// The settings catalogue shared by sidebar, content pane, toolbar, and deep links.
///
/// Page IDs are the identity. Titles and positions are presentation and may change as extensions
/// start or stop; no caller persists or routes by an array index.
@MainActor
enum SettingsPages {
    struct Page {
        let id: String
        let hostPage: ExtensionHostSettingsPage?
        let title: String
        let symbol: String
        let make: () -> NSViewController
    }

    static let generalID = ExtensionHostSettingsPage.general.rawValue
    static let accountsID = ExtensionHostSettingsPage.accounts.rawValue
    static let profilesID = ExtensionHostSettingsPage.profiles.rawValue
    static let themesID = ExtensionHostSettingsPage.themes.rawValue
    static let motionID = ExtensionHostSettingsPage.motion.rawValue
    static let extensionsID = ExtensionHostSettingsPage.extensions.rawValue
    static let toolsID = ExtensionHostSettingsPage.tools.rawValue
    static let keyboardID = ExtensionHostSettingsPage.keyboard.rawValue
    static let usageID = ExtensionHostSettingsPage.usage.rawValue
    static let storageID = ExtensionHostSettingsPage.storage.rawValue
    static let archivedID = ExtensionHostSettingsPage.archived.rawValue

    // Compatibility names for existing doors while they migrate to IDs.
    static let storageTitle = "Storage"
    static let usageTitle = "Usage"
    static let themesTitle = "Themes"
    static let keyboardTitle = "Keyboard"

    static let builtIn: [Page] = [
        Page(
            id: generalID,
            hostPage: .general,
            title: "General",
            symbol: "gearshape"
        ) { GeneralPreferencesViewController() },
        Page(
            id: accountsID,
            hostPage: .accounts,
            title: "Accounts",
            symbol: "person.2"
        ) { AccountsPreferencesViewController() },
        Page(
            id: profilesID,
            hostPage: .profiles,
            title: "Profiles",
            symbol: "person.crop.circle"
        ) { ProfilePreferencesViewController() },
        Page(
            id: themesID,
            hostPage: .themes,
            title: themesTitle,
            symbol: "paintpalette"
        ) { ThemePreferencesViewController() },
        Page(
            id: motionID,
            hostPage: .motion,
            title: "Motion",
            symbol: "sparkles"
        ) { MotionPreferencesViewController() },
        Page(
            id: extensionsID,
            hostPage: .extensions,
            title: "Extensions",
            symbol: "puzzlepiece.extension"
        ) { ExtensionsPreferencesViewController() },
        Page(
            id: toolsID,
            hostPage: .tools,
            title: "Tools",
            symbol: "wrench.and.screwdriver"
        ) { ToolsPreferencesViewController() },
        Page(
            id: keyboardID,
            hostPage: .keyboard,
            title: keyboardTitle,
            symbol: "keyboard"
        ) { KeyboardPreferencesViewController() },
        Page(
            id: usageID,
            hostPage: .usage,
            title: usageTitle,
            symbol: "chart.bar"
        ) { UsagePreferencesViewController() },
        Page(
            id: storageID,
            hostPage: .storage,
            title: storageTitle,
            symbol: "internaldrive"
        ) { StoragePreferencesViewController() },
        Page(
            id: archivedID,
            hostPage: .archived,
            title: "Archived",
            symbol: "archivebox"
        ) { ArchivedPreferencesViewController() }
    ]

    static var all: [Page] {
        builtIn + ExtensionSettingsRegistry.shared.pages.map { registered in
            Page(
                id: registered.id,
                hostPage: nil,
                title: "\(registered.extensionName) — \(registered.page.title)",
                symbol: registered.page.symbol
            ) {
                ExtensionSettingsViewController(page: registered)
            }
        }
    }

    static func page(id: String) -> Page? {
        all.first { $0.id == id }
    }

    static func index(ofID id: String) -> Int? {
        all.firstIndex { $0.id == id }
    }

    static func index(ofTitle title: String) -> Int? {
        all.firstIndex { $0.title == title }
    }

    static func id(ofTitle title: String) -> String? {
        all.first { $0.title == title }?.id
    }

    static var sidebarItems: [SettingsSidebar.Item] {
        all.map { SettingsSidebar.Item(id: $0.id, title: $0.title, symbol: $0.symbol) }
    }
}

import AppKit

/// The settings pages, in order — the single source of truth shared by the sidebar (which
/// lists them) and the content pane (which builds the chosen one).
enum SettingsPages {

    struct Page {
        let title: String
        let symbol: String
        let make: () -> NSViewController
    }

    /// Named so the sidebar can find this page without hardcoding its position, which moves
    /// whenever a page is added above it.
    static let storageTitle = "Storage"

    static let all: [Page] = [
        Page(title: "General", symbol: "gearshape") { GeneralPreferencesViewController() },
        Page(title: "Accounts", symbol: "person.2") { AccountsPreferencesViewController() },
        Page(title: "Profiles", symbol: "person.crop.circle") { ProfilePreferencesViewController() },
        Page(title: "Themes", symbol: "paintpalette") { ThemePreferencesViewController() },
        Page(title: "Tools", symbol: "wrench.and.screwdriver") { ToolsPreferencesViewController() },
        Page(title: storageTitle, symbol: "internaldrive") { StoragePreferencesViewController() },
        Page(title: "Archived", symbol: "archivebox") { ArchivedPreferencesViewController() }
    ]

    static var sidebarItems: [SettingsSidebar.Item] {
        all.map { SettingsSidebar.Item(title: $0.title, symbol: $0.symbol) }
    }
}

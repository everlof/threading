import AppKit

/// The settings pages, in order — the single source of truth shared by the sidebar (which
/// lists them) and the content pane (which builds the chosen one).
enum SettingsPages {

    struct Page {
        let title: String
        let symbol: String
        let make: () -> NSViewController
    }

    static let all: [Page] = [
        Page(title: "General", symbol: "gearshape") { GeneralPreferencesViewController() },
        Page(title: "Accounts", symbol: "person.2") { AccountsPreferencesViewController() },
        Page(title: "Profiles", symbol: "person.crop.circle") { ProfilePreferencesViewController() },
        Page(title: "Themes", symbol: "paintpalette") { ThemePreferencesViewController() },
        Page(title: "Archived", symbol: "archivebox") { ArchivedPreferencesViewController() }
    ]

    static var sidebarItems: [SettingsSidebar.Item] {
        all.map { SettingsSidebar.Item(title: $0.title, symbol: $0.symbol) }
    }
}

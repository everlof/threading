import AppKit
import ThreadingExtensionKit

// MARK: - Settings Search

/// One page a settings search turned up, and the terms inside it the query actually landed on.
///
/// The terms are why this type exists. A search that answers only "General, Themes" makes the
/// reader open both to find out which one it meant; the same search answering "General —
/// notifications, mute" has already told them. They are the page's own curated vocabulary, so
/// they name features rather than repeating whatever was typed.
struct SettingsSearchMatch: Equatable {
    let pageID: String
    let title: String
    let symbol: String
    /// Empty when the page matched on its title alone, which needs no second line to explain it.
    let terms: [String]
}

/// How a settings query is read. One implementation, because the sidebar's list and the results
/// page have to agree about what matched — two spellings of "contains" is how a section appears
/// in one and not the other.
enum SettingsSearch {

    /// How many of a page's terms a result will show before it stops being a summary.
    static let maximumTermsShown = 4

    /// A page matches when **every** token is somewhere in its text: typing more words narrows,
    /// which is the only behaviour a multi-word query can have that is not a surprise.
    static func matches(query: String, text: String) -> Bool {
        let tokens = query.split(whereSeparator: \.isWhitespace)
        guard !tokens.isEmpty else { return true }
        return tokens.allSatisfy { text.range(of: String($0), options: options) != nil }
    }

    /// The terms worth showing under a matched page: the ones **any** token touched.
    ///
    /// Any rather than all, and deliberately different from `matches`: the page qualified
    /// because its text as a whole holds every token, but no single term has to. Requiring all
    /// of them here would leave a two-word query matching a page and then explaining nothing.
    static func terms(in terms: [String], touchedBy query: String) -> [String] {
        let tokens = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return [] }
        return terms
            .filter { term in tokens.contains { term.range(of: $0, options: options) != nil } }
            .prefix(maximumTermsShown)
            .map { $0 }
    }

    /// Collapses a raw term list to what a reader should see: one row per concept, first
    /// spelling wins, each led by a capital so a row reads as a label rather than as a keyword.
    static func presentable(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        return terms.compactMap { term in
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { return nil }
            return trimmed.prefix(1).localizedUppercase + trimmed.dropFirst()
        }
    }

    /// The same comparison the highlight uses. Kept as one value rather than two identical
    /// literals: a filter that is a shade more forgiving than the highlight shows a page with
    /// nothing lit up in it, which reads as the search having found it for no reason.
    private static let options = SearchTextMatch.comparisonOptions
}

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
        let searchTerms: [String]
        let make: () -> NSViewController

        @MainActor
        var searchableText: String {
            let extensionTerms = hostPage.map {
                ExtensionSettingsRegistry.shared.searchTerms(for: $0)
            } ?? []
            return ([title] + searchTerms + extensionTerms).joined(separator: " ")
        }

        /// The page's terms as a reader would see them: no title (the row above already carries
        /// it) and no near-duplicates.
        ///
        /// `terms(_:)` deliberately expands each value into its localised variants so a search
        /// in either language finds the page, which means the raw list holds "sessions",
        /// "Sessions" and whatever the current locale calls it. All three are one concept, and
        /// three rows saying it is worse than none.
        @MainActor
        var displayTerms: [String] {
            let extensionTerms = hostPage.map {
                ExtensionSettingsRegistry.shared.searchTerms(for: $0)
            } ?? []
            return SettingsSearch.presentable(searchTerms + extensionTerms)
        }
    }

    static let generalID = ExtensionHostSettingsPage.general.rawValue
    static let remoteAccessID = "remote-access"
    static let privacyID = "privacy"
    static let githubID = "github"
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
    /// No `hostPage`: an extension contributing rows to the page that resets the app — and that
    /// names where its own state lives — is a door nothing needs to be opened.
    static let advancedID = "advanced"

    // Compatibility names for existing doors while they migrate to IDs.
    static var storageTitle: String { L10n.string("Storage") }
    static var usageTitle: String { L10n.string("Usage") }
    static var themesTitle: String { L10n.string("Themes") }
    static var keyboardTitle: String { L10n.string("Keyboard") }

    static let builtIn: [Page] = [
        Page(
            id: generalID,
            hostPage: .general,
            title: L10n.string("General"),
            symbol: "gearshape",
            searchTerms: terms(
                "sessions", "agent", "attachments", "startup", "closing", "shell",
                "branch", "project icons", "account avatars", "Codex hooks",
                "Claude Remote Control", "notifications", "mute", "sound", "alerts",
                "confirmations", "don't ask again", "ask before", "opening message",
                "first message", "instructions"
            )
        ) { GeneralPreferencesViewController() },
        Page(
            id: remoteAccessID,
            hostPage: nil,
            title: L10n.string("Remote Access"),
            symbol: "iphone",
            searchTerms: terms("iPhone", "pair", "QR code", "remote", "device", "security")
        ) { RemoteAccessPreferencesViewController() },
        Page(
            id: accountsID,
            hostPage: .accounts,
            title: L10n.string("Accounts"),
            symbol: "person.2",
            searchTerms: terms("Claude", "Codex", "login", "avatar", "emoji", "name", "enabled")
        ) { AccountsPreferencesViewController() },
        Page(
            id: privacyID,
            hostPage: nil,
            title: L10n.string("Privacy"),
            symbol: "hand.raised",
            searchTerms: terms(
                "permissions", "accessibility", "screen recording", "notifications",
                "files and folders", "keychain", "sandbox", "TCC", "security"
            )
        ) { PrivacyPreferencesViewController() },
        Page(
            id: githubID,
            hostPage: nil,
            title: L10n.string("GitHub"),
            symbol: "checkmark.seal",
            searchTerms: terms(
                "checks", "credentials", "device flow", "gh", "token", "connect",
                "private repositories", "client ID", "app"
            )
        ) { GitHubPreferencesViewController() },
        Page(
            id: profilesID,
            hostPage: .profiles,
            title: L10n.string("Profiles"),
            symbol: "person.crop.circle",
            searchTerms: terms(
                "terminal font", "terminal size", "cursor", "scrollback", "colour",
                "background", "dropped images"
            )
        ) { ProfilePreferencesViewController() },
        Page(
            id: themesID,
            hostPage: .themes,
            title: themesTitle,
            symbol: "paintpalette",
            searchTerms: terms(
                "appearance", "app theme", "terminal theme", "font", "typeface",
                "text size", "colors", "colours", "palette", "large text"
            )
        ) { ThemePreferencesViewController() },
        Page(
            id: motionID,
            hostPage: .motion,
            title: L10n.string("Motion"),
            symbol: "sparkles",
            searchTerms: terms("animation", "working indicator", "orb", "chat names", "transition")
        ) { MotionPreferencesViewController() },
        Page(
            id: extensionsID,
            hostPage: .extensions,
            title: L10n.string("Extensions"),
            symbol: "puzzlepiece.extension",
            searchTerms: terms(
                "plugins", "install", "enable", "reload", "remove", "capabilities",
                "identity rendering"
            )
        ) { ExtensionsPreferencesViewController() },
        Page(
            id: toolsID,
            hostPage: .tools,
            title: L10n.string("Tools"),
            symbol: "wrench.and.screwdriver",
            searchTerms: terms(
                "MCP", "browser", "agents", "permissions", "enabled",
                "website access", "origin", "revoke"
            )
        ) { ToolsPreferencesViewController() },
        Page(
            id: keyboardID,
            hostPage: .keyboard,
            title: keyboardTitle,
            symbol: "keyboard",
            searchTerms: terms(
                "shortcuts", "keys", "bindings", "commands", "reset",
                "return", "enter", "send", "new line", "composer"
            )
        ) { KeyboardPreferencesViewController() },
        Page(
            id: usageID,
            hostPage: .usage,
            title: usageTitle,
            symbol: "chart.bar",
            searchTerms: terms("tokens", "cost", "spend", "account", "checkout", "model", "day")
        ) { UsagePreferencesViewController() },
        Page(
            id: storageID,
            hostPage: .storage,
            title: storageTitle,
            symbol: "internaldrive",
            searchTerms: terms("disk", "build output", "cache", "reclaim", "remove", "space")
        ) { StoragePreferencesViewController() },
        Page(
            id: archivedID,
            hostPage: .archived,
            title: L10n.string("Archived"),
            symbol: "archivebox",
            searchTerms: terms("conversations", "sessions", "restore", "delete")
        ) { ArchivedPreferencesViewController() },
        // Last, and deliberately: it is the page nobody needs until something is wrong, and its
        // two buttons are the widest-reaching in Settings.
        Page(
            id: advancedID,
            hostPage: nil,
            title: L10n.string("Advanced"),
            // Not `wrench.and.screwdriver`: Tools already wears it, and two sidebar rows in
            // one icon read as one destination twice.
            symbol: "gearshape.2",
            searchTerms: terms(
                "reset", "start over", "fresh", "erase", "corrupt", "preferences file",
                "application support", "where", "location", "reveal", "backup", "restart"
            )
        ) { AdvancedPreferencesViewController() }
    ]

    static var all: [Page] {
        builtIn + ExtensionSettingsRegistry.shared.pages.map { registered in
            Page(
                id: registered.id,
                hostPage: nil,
                title: "\(registered.extensionName) — \(registered.page.title)",
                symbol: registered.page.symbol,
                searchTerms: ExtensionSettingsRegistry.searchTerms(for: registered)
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
        all.map {
            SettingsSidebar.Item(
                id: $0.id,
                title: $0.title,
                symbol: $0.symbol,
                searchText: $0.searchableText
            )
        }
    }

    /// Every page whose text the query lands in, each carrying the terms it landed on.
    static func search(_ query: String) -> [SettingsSearchMatch] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return all
            .filter { SettingsSearch.matches(query: trimmed, text: $0.searchableText) }
            .map {
                SettingsSearchMatch(
                    pageID: $0.id,
                    title: $0.title,
                    symbol: $0.symbol,
                    terms: SettingsSearch.terms(in: $0.displayTerms, touchedBy: trimmed)
                )
            }
    }

    private static func terms(_ values: String...) -> [String] {
        values.flatMap { value in
            let sentenceCase = value.prefix(1).uppercased() + String(value.dropFirst())
            var terms = [value]
            for candidate in [L10n.string(value), L10n.string(sentenceCase)]
                where !terms.contains(candidate) {
                terms.append(candidate)
            }
            return terms
        }
    }
}

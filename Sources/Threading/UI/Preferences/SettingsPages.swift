import AppKit
import ThreadingExtensionKit

// MARK: - Settings Search

/// One row of a settings page, as the search knows it: the title the page draws, the section
/// caption over it, and any extra vocabulary the row answers to.
///
/// The title doubles as the row's **anchor**: `SettingsUI` tags every built row with an
/// identifier derived from its localized title (`SettingsRowAnchor`), so a search result that
/// names an entry can open the page, scroll to the row and mark it — rather than leaving the
/// reader to run their own search inside the page the result pointed at.
/// `SettingsAnchorResolutionTests` builds each indexed page and fails on an entry whose title no
/// built row carries, which is what keeps this catalogue and the pages from drifting apart.
struct SettingsEntry: Equatable {
    /// The row's localized display title — exactly what the page draws, because it is also the
    /// anchor the reveal looks for.
    let title: String
    /// The localized section caption the row sits under, nil for an uncaptioned card.
    let section: String?
    /// Extra words the row answers to, beyond its own title ("beep" for the bell).
    let terms: [String]

    /// Everything a query may land on to count as *this row*. The page title is included so
    /// "general sound" narrows to the sound rows rather than to nothing.
    func searchableText(pageTitle: String) -> String {
        ([title, section ?? "", pageTitle] + terms).joined(separator: " ")
    }
}

/// The one spelling of a settings destination's full path — "General › Notifications › Alert
/// sound" — shared by the AI suggestions and anywhere else a result stands far from its page.
enum SettingsPath {
    static let separator = " › "

    static func display(pageTitle: String, section: String?, title: String?) -> String {
        [pageTitle, section, title].compactMap { $0 }.joined(separator: separator)
    }
}

/// How a settings query is read. One implementation, because the sidebar's page rows and its
/// row-level results have to agree about what matched — two spellings of "contains" is how a
/// destination appears in one and not the other.
enum SettingsSearch {

    /// A candidate matches when **every** token is somewhere in its text: typing more words
    /// narrows, which is the only behaviour a multi-word query can have that is not a surprise.
    static func matches(query: String, text: String) -> Bool {
        let tokens = query.split(whereSeparator: \.isWhitespace)
        guard !tokens.isEmpty else { return true }
        return tokens.allSatisfy { text.range(of: String($0), options: options) != nil }
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
        /// The sidebar section the page sits under — presentation, like the title, and
        /// localized the same way. Pages sharing a group must be contiguous in `builtIn`;
        /// the sidebar draws one caption per run.
        let group: String
        let searchTerms: [String]
        /// The page's static rows, for the search results that name a setting rather than a
        /// page. Empty on pages whose rows are dynamic or table-backed — those still match at
        /// page level through `searchTerms`, they just cannot promise a row to scroll to.
        let entries: [SettingsEntry]
        let make: () -> NSViewController

        @MainActor
        init(
            id: String,
            hostPage: ExtensionHostSettingsPage?,
            title: String,
            symbol: String,
            group: String,
            searchTerms: [String],
            entries: [SettingsEntry]? = nil,
            make: @escaping () -> NSViewController
        ) {
            self.id = id
            self.hostPage = hostPage
            self.title = title
            self.symbol = symbol
            self.group = group
            self.searchTerms = searchTerms
            self.entries = entries ?? SettingsPages.entries(for: id)
            self.make = make
        }

        @MainActor
        var searchableText: String {
            let extensionTerms = hostPage.map {
                ExtensionSettingsRegistry.shared.searchTerms(for: $0)
            } ?? []
            let entryText = entries.map { $0.searchableText(pageTitle: title) }
            return ([title] + searchTerms + extensionTerms + entryText).joined(separator: " ")
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
    /// No `hostPage`: an extension contributing rows to the page that spends the user's rate
    /// limits on a schedule is a door nothing needs opened.
    static let usageWindowsID = "usage-windows"
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

    // The sidebar's sections. Six, and the membership is the argument: **App** is how the app
    // itself behaves, **Appearance** how it looks (the terminal profile lives here — its font
    // and cursor are appearance, wherever the word "profile" suggests otherwise), **Agents**
    // everything about the agents Threading launches (their logins, the tools they reach, what
    // they spent), **Access** who reaches the app and what the app may reach (a paired iPhone,
    // GitHub, the macOS grants), **Data** what is on disk and the resets — the pages that are
    // reports and housekeeping rather than preferences, which is exactly what a caption can
    // finally say — and **Extensions** the packages plus every page one contributes.
    static var appGroup: String { L10n.string("App") }
    static var appearanceGroup: String { L10n.string("Appearance") }
    static var agentsGroup: String { L10n.string("Agents") }
    static var accessGroup: String { L10n.string("Access") }
    static var dataGroup: String { L10n.string("Data") }
    static var extensionsGroup: String { L10n.string("Extensions") }

    static let builtIn: [Page] = [
        // MARK: App
        Page(
            id: generalID,
            hostPage: .general,
            title: L10n.string("General"),
            symbol: "gearshape",
            group: appGroup,
            searchTerms: terms(
                "sessions", "agent", "attachments", "startup", "closing", "shell",
                "branch", "compact tree", "indentation", "sidebar density",
                "project icons", "account avatars", "Codex hooks",
                "Claude Remote Control", "notifications", "mute", "sound", "alerts",
                // The bell has its own words: nobody searching for the noise a TUI makes types
                // "notifications", and "beep" is what they will have called it.
                "bell", "beep", "terminal bell", "alert sound",
                // The gate covers both kinds, so it answers to neither one's words.
                "silence", "silence sounds",
                // The per-event tier and the list of what has already been given a sound.
                // Somebody hunting a mystery noise types the noise's words, not the page's.
                "custom sounds", "per-event sounds", "customize events", "override",

                "confirmations", "don't ask again", "ask before", "opening message",
                "first message", "instructions", "conversation speed", "fast mode",
                "standard mode", "service tier", "credits",
                // The Startup section's own verbs, added the day a search for
                // "automatic loading on startup" found nothing: the section relaunches and
                // reopens sessions, and none of those words appeared here.
                "relaunch", "reopen", "restore", "resume automatically", "running at quit",
                // The window policy's own words, for the same reason: "dormant" is what the user
                // sees, and none of the terms above lead to the setting that decides it.
                "dormant", "recently used", "restore window", "restore limit", "days"
            ),
            // Static rows are projected from `AppSettingDefinitions`. Dynamic runs — the
            // per-agent attachment toggles, per-prompt confirmations, per-alert notification
            // list and custom-sound audit — stay page-level because a stale anchor is worse
            // than none.
        ) { GeneralPreferencesViewController() },
        Page(
            id: keyboardID,
            hostPage: .keyboard,
            title: keyboardTitle,
            symbol: "keyboard",
            group: appGroup,
            searchTerms: terms(
                "shortcuts", "keys", "bindings", "commands", "reset",
                "return", "enter", "send", "new line", "composer"
            ),
            // The two standing decisions. The command inventories are dynamic disclosure
            // cards, so they stay page-level.
        ) { KeyboardPreferencesViewController() },
        // MARK: Appearance
        Page(
            id: themesID,
            hostPage: .themes,
            title: themesTitle,
            symbol: "paintpalette",
            group: appearanceGroup,
            searchTerms: terms(
                "appearance", "app theme", "terminal theme", "font", "typeface",
                "text size", "colors", "colours", "palette", "large text"
            ),
            // The theme list, preview and colour editor are their own surfaces rather than
            // rows; only the App and Fonts cards are addressable.
        ) { ThemePreferencesViewController() },
        Page(
            id: profilesID,
            hostPage: .profiles,
            title: L10n.string("Profiles"),
            symbol: "person.crop.circle",
            group: appearanceGroup,
            searchTerms: terms(
                // "terminal selection" sits third because the terms shown under a result are
                // capped: a search for "terminal" lands on the two above it as well, and the
                // one the reader is most likely to be hunting for has to survive the cap.
                "terminal font", "terminal size", "terminal selection", "copy on select",
                "clipboard", "cursor", "scrollback", "colour", "background", "dropped images"
            ),
        ) { ProfilePreferencesViewController() },
        Page(
            id: motionID,
            hostPage: .motion,
            title: L10n.string("Motion"),
            symbol: "sparkles",
            group: appearanceGroup,
            searchTerms: terms("animation", "working indicator", "orb", "chat names", "transition"),
        ) { MotionPreferencesViewController() },
        // MARK: Agents
        Page(
            id: accountsID,
            hostPage: .accounts,
            title: L10n.string("Accounts"),
            symbol: "person.2",
            group: agentsGroup,
            searchTerms: terms("Claude", "Codex", "login", "avatar", "emoji", "name", "enabled")
        ) { AccountsPreferencesViewController() },
        Page(
            id: toolsID,
            hostPage: .tools,
            title: L10n.string("Tools"),
            symbol: "wrench.and.screwdriver",
            group: agentsGroup,
            searchTerms: terms(
                "MCP", "browser", "agents", "permissions", "enabled",
                "website access", "origin", "revoke"
            )
        ) { ToolsPreferencesViewController() },
        Page(
            id: usageID,
            hostPage: .usage,
            title: usageTitle,
            symbol: "chart.bar",
            group: agentsGroup,
            searchTerms: terms("tokens", "cost", "spend", "account", "checkout", "model", "day")
        ) { UsagePreferencesViewController() },
        Page(
            id: usageWindowsID,
            hostPage: nil,
            title: L10n.string("Usage Windows"),
            symbol: "clock.arrow.trianglehead.counterclockwise.rotate.90",
            group: agentsGroup,
            searchTerms: terms(
                "rate limit", "5-hour window", "session limit", "reset", "schedule",
                "poke", "weekly limit", "working hours", "workday",
                "curfew", "quiet hours", "wind-down", "wrap-up", "interrupt", "stop the agent"
            ),
            // The schedule and the two policies. The per-account rows and the poke ledger are
            // dynamic.
        ) { UsageWindowPreferencesViewController() },
        // MARK: Access
        Page(
            id: remoteAccessID,
            hostPage: nil,
            title: L10n.string("Remote Access"),
            symbol: "iphone",
            group: accessGroup,
            searchTerms: terms("iPhone", "pair", "QR code", "remote", "device", "security"),
            // The pairing card's headings are runtime state, and the paired-device rows are
            // dynamic; the standing switches are what a search can promise.
        ) { RemoteAccessPreferencesViewController() },
        Page(
            id: githubID,
            hostPage: nil,
            title: L10n.string("GitHub"),
            symbol: "checkmark.seal",
            group: accessGroup,
            searchTerms: terms(
                "checks", "credentials", "device flow", "gh", "token", "connect",
                "private repositories", "client ID", "app"
            ),
        ) { GitHubPreferencesViewController() },
        Page(
            id: privacyID,
            hostPage: nil,
            title: L10n.string("Privacy"),
            symbol: "hand.raised",
            group: accessGroup,
            searchTerms: terms(
                "permissions", "accessibility", "screen recording", "notifications",
                "files and folders", "keychain", "sandbox", "TCC", "security"
            ),
        ) { PrivacyPreferencesViewController() },
        // MARK: Data
        Page(
            id: storageID,
            hostPage: .storage,
            title: storageTitle,
            symbol: "internaldrive",
            group: dataGroup,
            searchTerms: terms("disk", "build output", "cache", "reclaim", "remove", "space")
        ) { StoragePreferencesViewController() },
        Page(
            id: archivedID,
            hostPage: .archived,
            title: L10n.string("Archived"),
            symbol: "archivebox",
            group: dataGroup,
            searchTerms: terms("conversations", "sessions", "restore", "delete")
        ) { ArchivedPreferencesViewController() },
        // Last of the built-in destinations, and deliberately: it is the page nobody needs
        // until something is wrong, and its two buttons are the widest-reaching in Settings.
        // Only the Extensions section follows, because `all` appends extension-contributed
        // pages at the end and they have to land inside their own section's run.
        Page(
            id: advancedID,
            hostPage: nil,
            title: L10n.string("Advanced"),
            // Not `wrench.and.screwdriver`: Tools already wears it, and two sidebar rows in
            // one icon read as one destination twice.
            symbol: "gearshape.2",
            group: dataGroup,
            searchTerms: terms(
                "reset", "start over", "fresh", "erase", "corrupt", "preferences file",
                "application support", "where", "location", "reveal", "backup", "restart"
            ),
        ) { AdvancedPreferencesViewController() },
        // MARK: Extensions
        Page(
            id: extensionsID,
            hostPage: .extensions,
            title: L10n.string("Extensions"),
            symbol: "puzzlepiece.extension",
            group: extensionsGroup,
            searchTerms: terms(
                "plugins", "install", "enable", "reload", "remove", "capabilities",
                "identity rendering"
            )
        ) { ExtensionsPreferencesViewController() }
    ]

    static var all: [Page] {
        builtIn + ExtensionSettingsRegistry.shared.pages.map { registered in
            Page(
                id: registered.id,
                hostPage: nil,
                title: "\(registered.extensionName) — \(registered.page.title)",
                symbol: registered.page.symbol,
                group: extensionsGroup,
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
        all.map { page in
            SettingsSidebar.Item(
                id: page.id,
                title: page.title,
                symbol: page.symbol,
                searchText: page.searchableText,
                group: page.group,
                entries: page.entries.map {
                    SettingsSidebar.Item.Entry(
                        title: $0.title,
                        section: $0.section,
                        searchText: $0.searchableText(pageTitle: page.title)
                    )
                }
            )
        }
    }

    /// Built-in row metadata is authored with its persistence and remote contract. Localisation
    /// remains a UI projection, so the Foundation-only definition model never imports AppKit.
    private static func entries(for pageID: String) -> [SettingsEntry] {
        let rows = AppSettingDefinitions.all
            .filter { $0.remotePolicy != .hidden }
            .flatMap(\.presentations)
            .filter { $0.pageID == pageID }
        return rows.sorted { $0.catalogueOrder < $1.catalogueOrder }.map { presentation in
            SettingsEntry(
                title: L10n.string(presentation.rowAnchor),
                section: presentation.section.map { L10n.string($0) },
                terms: presentation.searchTerms.flatMap(expanded(_:))
            )
        }
    }

    private static func terms(_ values: String...) -> [String] {
        values.flatMap(expanded(_:))
    }

    /// One vocabulary value, plus its localized variants, so a search in either language finds
    /// the page.
    private static func expanded(_ value: String) -> [String] {
        let sentenceCase = value.prefix(1).uppercased() + String(value.dropFirst())
        var terms = [value]
        for candidate in [L10n.string(value), L10n.string(sentenceCase)]
            where !terms.contains(candidate) {
            terms.append(candidate)
        }
        return terms
    }

}

import Foundation

// MARK: - Paths

/// The one spelling of a settings destination's full path — "General › Notifications › Alert
/// sound" — shared by the AI suggestions, the command palette, and anywhere else a result stands
/// far from its page.
enum SettingsPath {
    static let separator = " › "

    static func display(pageTitle: String, section: String?, title: String?) -> String {
        [pageTitle, section, title].compactMap { $0 }.joined(separator: separator)
    }
}

// MARK: - Destinations

/// One place in Settings something can be *sent to*: a whole page, or one row on it.
///
/// A settings row is not a command. Nothing runs, and binding a chord to "scroll to Alert sound"
/// is not a preference anybody wants — so destinations stay out of `CommandRegistry`, out of the
/// menu bar and out of the Keyboard page, which would otherwise gain two hundred rows that can
/// never carry a key.
///
/// They are still the thing most often hunted for by name, and the palette is where a name is
/// typed. So the command plane admits them as their own origin: searchable and invocable like a
/// command, never rebindable, and answering with navigation rather than an effect. Invoking one
/// opens Settings on its page and reveals its row (`SettingsRowAnchor`/`SettingsRowReveal`),
/// which is why `rowTitle` is the row's *title* — that title is the anchor.
struct SettingsDestination: Equatable, Sendable {
    /// The stable page id, as `SettingsPages` knows it.
    let pageID: String
    let pageTitle: String
    /// The sidebar group the page sits under — "App", "Extensions".
    let group: String
    /// The row's section caption. Nil for a page, and for a row on an uncaptioned card.
    let section: String?
    /// The row's localized title, which is also the anchor a reveal scrolls to. Nil means the
    /// destination is the page itself.
    let rowTitle: String?
    /// Extra vocabulary the destination answers to, beyond its own title — "beep" for the bell.
    let keywords: [String]

    init(
        pageID: String,
        pageTitle: String,
        group: String,
        section: String? = nil,
        rowTitle: String? = nil,
        keywords: [String] = []
    ) {
        self.pageID = pageID
        self.pageTitle = pageTitle
        self.group = group
        self.section = section
        self.rowTitle = rowTitle
        self.keywords = keywords
    }

    /// What the palette invokes.
    ///
    /// Derived from the page id and the row's title rather than stored, because a destination is
    /// assembled fresh from the current catalogue every time the palette opens. Nothing persists
    /// it: destinations carry no shortcut, so there is no override keyed on this id to drop when
    /// a row is renamed or the app is run in another language.
    var id: String {
        guard let rowTitle else { return "\(SettingsDestinationCatalog.pagePrefix)\(pageID)" }
        return "\(SettingsDestinationCatalog.rowPrefix)\(pageID)#\(rowTitle)"
    }

    /// What the palette shows as the row's name: the setting, or the page.
    var title: String { rowTitle ?? pageTitle }

    /// What the palette shows under the name — where the destination lives, not what it is.
    ///
    /// A row says its page and section ("General › Notifications"); the row's own title is
    /// already the line above. A page says the Settings group holding it ("Settings › App"), so
    /// a page row and a setting row never read as the same kind of thing.
    var detail: String {
        guard rowTitle != nil else {
            return SettingsPath.display(
                pageTitle: L10n.string("Settings"),
                section: group,
                title: nil
            )
        }
        return SettingsPath.display(pageTitle: pageTitle, section: section, title: nil)
    }
}

/// Every settings destination the palette may offer, assembled from a catalogue projection.
///
/// Pure and Foundation-only: the UI decides which pages and rows exist right now and hands them
/// over already localized, and this owns identity, de-duplication and the bound.
enum SettingsDestinationCatalog {
    static let pagePrefix = "settings.page."
    static let rowPrefix = "settings.row."

    /// The app's own catalogue is ~20 pages and under a hundred rows; the rest is whatever
    /// extensions installed, each capped at 128 fields by the extension contract but unbounded
    /// in *how many* extensions there are. The palette caps presentation at 100 rows and filters
    /// off the main thread, so this bound is about the array the main actor builds on open, not
    /// about the list a reader sees.
    static let maximumDestinations = 2000

    /// Deduplicated by id, first spelling wins — the same rule the anchors use, so a page that
    /// repeats a title offers the row the catalogue listed first, which is the row a reveal
    /// finds.
    static func catalog(_ destinations: [SettingsDestination]) -> [SettingsDestination] {
        var seen = Set<String>()
        var result: [SettingsDestination] = []
        result.reserveCapacity(min(destinations.count, maximumDestinations))
        for destination in destinations {
            guard result.count < maximumDestinations else { break }
            guard seen.insert(destination.id).inserted else { continue }
            result.append(destination)
        }
        return result
    }

    /// Whether an id names a destination at all, without a catalogue in hand — the cheap gate an
    /// invoker uses before it goes looking.
    static func isDestinationID(_ id: String) -> Bool {
        id.hasPrefix(pagePrefix) || id.hasPrefix(rowPrefix)
    }

    static func destination(
        id: String,
        in destinations: [SettingsDestination]
    ) -> SettingsDestination? {
        destinations.first { $0.id == id }
    }
}

extension SettingsDestination {
    /// The one projection from a settings destination into the host contract, matching
    /// `AppCommand.hostDescriptor` for commands.
    func hostDescriptor() -> HostCommandDescriptor {
        HostCommandDescriptor(
            id: id,
            title: title,
            detail: detail,
            group: HostCommandDescriptor.settingsGroup,
            shortcut: nil,
            origin: .settings,
            scope: .application,
            risk: .ordinary,
            availability: .available,
            keywords: keywords
        )
    }
}

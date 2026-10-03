import AppKit

/// A choice offered by a themed menu control.
///
/// Feature code describes meaning and state; `ThemedMenuPresenter` draws the complete dropdown
/// from app roles. Keeping presentation details out of this type means both `ChipView` and
/// `ThemedPopUp` share one visual and behavioral contract.
/// One run of a themed menu subtitle, for the line that is more than one uniform ink.
///
/// The account rows' usage reading is why this exists: `Claude Code · 5h 22% · 7d 15%` as one
/// secondary string is a wall of equally weighted numbers, and the comparison the menu exists
/// for lives in exactly two of them. A tone names what a run *is* — furniture or a value, calm
/// or under pressure — and the row resolves it to a colour at draw time, so a live theme switch
/// re-inks the next frame rather than honouring colours frozen in at decoration time.
public struct ThemedMenuSubtitleSegment {

    /// Semantic, not a colour: the row owns the palette, including the grounds where a tone
    /// cannot be honoured at all (a classic selection band flattens every run to its own ink).
    public enum Tone {
        /// The subtitle's own ink — what a plain, unsegmented subtitle draws in.
        case standard
        /// Quieter than the line: labels and separators, the furniture between values.
        case muted
        /// A value near its limit, in the theme's warning role.
        case warning
        /// A value nearly spent, in the theme's negative role.
        case critical
    }

    public let text: String
    public let tone: Tone

    public init(_ text: String, _ tone: Tone = .standard) {
        self.text = text
        self.tone = tone
    }
}

/// One reading a row states as a *column* rather than as words inside its line.
///
/// The account rows are why this exists. A subtitle can hold `5h 27% · 7d 81% · 7d resets in
/// 19h 36m`, and for one row it reads fine — but the menu's job is comparing several, and a
/// value's position in a sentence is decided by the length of the name in front of it. Three
/// logins therefore put their three 5-hour numbers at three different x positions, and the
/// comparison the menu exists for becomes a search.
///
/// A metric names its column (`label`) instead of its place, so the row can stack every login's
/// same-named window in one column with tabular digits under it. `fraction` is the same reading
/// again as a length, which is what makes the ranking pre-attentive; nil draws the track alone,
/// for a window whose number is not knowable rather than one that is empty. `tone` is semantic
/// for the same reason `ThemedMenuSubtitleSegment.Tone` is — the row owns the palette, and a
/// classic selection band flattens both text and bar to its own authored ink.
public struct ThemedMenuMetric {

    /// The column this reading belongs in, and its written name — `5h`, `7d`. Rows sharing a
    /// label share a column; a row with no metric for a column leaves it empty, which is how
    /// a plan metering one window says so beside a plan metering two.
    public let label: String
    /// The precise answer, in the column's own digits — `27%`, or `—` where the window's number
    /// would be a leftover from the window before it.
    public let value: String
    /// The same answer as a length, 0…1. Nil draws the empty track: no bar at all would read as
    /// a missing column, and a full-length one as a spent window.
    public let fraction: Double?
    public let tone: ThemedMenuSubtitleSegment.Tone

    public init(
        label: String,
        value: String,
        fraction: Double?,
        tone: ThemedMenuSubtitleSegment.Tone = .standard
    ) {
        self.label = label
        self.value = value
        self.fraction = fraction
        self.tone = tone
    }
}

public struct ThemedMenuItem {
    /// What choosing this row can do. Kept as one value because an action and a submenu are
    /// mutually exclusive interaction contracts: a row that carries both answers its press
    /// with the action while its chevron and hover answer with the submenu.
    private enum Destination {
        case none
        case action(() -> Void)
        case submenu([ThemedMenuEntry])
    }

    public let title: String
    /// Explanatory hover and assistive help that adds meaning beyond the visible title.
    ///
    /// This stays separate from `subtitle`: a subtitle is part of the menu's standing layout,
    /// while help is supplementary and appears only when somebody lingers or asks assistive
    /// technology for more detail. The row owns both presentations so callers never install a
    /// second tracking area over menu chrome.
    public var help: String?
    public var subtitle: String?
    /// The complete chord that invokes the same action outside this menu.
    ///
    /// One value drives every modifier and the key, rather than asking a caller to bake glyphs
    /// into the title. The row can therefore align a real shortcut column and keep a rebound
    /// command truthful. `keyEquivalent` remains as the historical command-only shorthand used
    /// by the component-gallery reproductions below.
    public var shortcut: KeyboardShortcut?
    public var keyEquivalent: String?
    /// Toned runs over `subtitle`, set through `setSubtitle(_:)` so the two cannot disagree.
    /// The row draws these when present; everything that is not drawing — the tooltip, the
    /// type-to-filter, the measured width — keeps reading the plain string. One font across
    /// every run, deliberately: tones change ink only, so the plain string measures exactly
    /// what the styled line draws.
    public private(set) var subtitleSegments: [ThemedMenuSubtitleSegment]?
    /// Readings this row states in shared columns beside its title, aligned with every other
    /// row's. See `ThemedMenuMetric`. Empty on a row that has none — a menu whose rows all have
    /// none reserves no columns at all.
    public var metrics: [ThemedMenuMetric] = []
    /// The one fact that follows the columns, right-aligned in a column of its own: the account
    /// rows' reset countdown. Separated from the metrics because it is not a reading of a
    /// window, and separated from the subtitle because it is the fact that must never be the
    /// thing an over-long line truncates.
    public var trailingDetail: String?
    /// A quiet qualifier drawn immediately after the title, in the same line — the account
    /// rows' plan name. It belongs to the title rather than to the subtitle: it identifies the
    /// row, and demoting it to a second line gives a subtitle-height row to every login whose
    /// provider happens to report a plan.
    public var titleDetail: String?
    public var image: NSImage?
    public var preview: ThemedMenuPreview?
    /// A second action offered at the trailing edge under the pointer, which does not choose the
    /// row. See `ThemedMenuAccessory`. Set after construction like the other trailing columns,
    /// because it is a property of the *list* a row was put in — one caller builds the row and
    /// the list's owner decides that its rows can be auditioned.
    public var accessory: ThemedMenuAccessory?
    public var representedValue: Any?
    public var isSelected: Bool
    public var isEnabled: Bool
    private let destination: Destination

    public var onChoose: (() -> Void)? {
        guard case .action(let action) = destination else { return nil }
        return action
    }

    /// Entries this item opens beside itself. A row carrying these draws a chevron and opens on
    /// hover, on ⌘-less right-arrow, and on press; choosing anywhere in the chain closes the
    /// whole menu. `Destination` makes the parent-or-action rule structural rather than a
    /// convention each caller and interaction path has to remember.
    public var submenu: [ThemedMenuEntry]? {
        guard case .submenu(let entries) = destination else { return nil }
        return entries
    }

    public init(
        title: String,
        help: String? = nil,
        subtitle: String? = nil,
        shortcut: KeyboardShortcut? = nil,
        keyEquivalent: String? = nil,
        image: NSImage? = nil,
        preview: ThemedMenuPreview? = nil,
        representedValue: Any? = nil,
        isSelected: Bool = false,
        isEnabled: Bool = true
    ) {
        self.init(
            title: title,
            help: help,
            subtitle: subtitle,
            shortcut: shortcut,
            keyEquivalent: keyEquivalent,
            image: image,
            preview: preview,
            representedValue: representedValue,
            isSelected: isSelected,
            isEnabled: isEnabled,
            destination: .none
        )
    }

    public init(
        title: String,
        help: String? = nil,
        subtitle: String? = nil,
        shortcut: KeyboardShortcut? = nil,
        keyEquivalent: String? = nil,
        image: NSImage? = nil,
        preview: ThemedMenuPreview? = nil,
        representedValue: Any? = nil,
        isSelected: Bool = false,
        isEnabled: Bool = true,
        onChoose: (() -> Void)?
    ) {
        self.init(
            title: title,
            help: help,
            subtitle: subtitle,
            shortcut: shortcut,
            keyEquivalent: keyEquivalent,
            image: image,
            preview: preview,
            representedValue: representedValue,
            isSelected: isSelected,
            isEnabled: isEnabled,
            destination: onChoose.map(Destination.action) ?? .none
        )
    }

    public init(
        title: String,
        help: String? = nil,
        subtitle: String? = nil,
        shortcut: KeyboardShortcut? = nil,
        keyEquivalent: String? = nil,
        image: NSImage? = nil,
        preview: ThemedMenuPreview? = nil,
        representedValue: Any? = nil,
        isSelected: Bool = false,
        isEnabled: Bool = true,
        submenu: [ThemedMenuEntry]
    ) {
        self.init(
            title: title,
            help: help,
            subtitle: subtitle,
            shortcut: shortcut,
            keyEquivalent: keyEquivalent,
            image: image,
            preview: preview,
            representedValue: representedValue,
            isSelected: isSelected,
            isEnabled: isEnabled,
            destination: .submenu(submenu)
        )
    }

    private init(
        title: String,
        help: String?,
        subtitle: String?,
        shortcut: KeyboardShortcut?,
        keyEquivalent: String?,
        image: NSImage?,
        preview: ThemedMenuPreview?,
        representedValue: Any?,
        isSelected: Bool,
        isEnabled: Bool,
        destination: Destination
    ) {
        self.title = title
        self.help = help
        self.subtitle = subtitle
        self.shortcut = shortcut
        self.keyEquivalent = keyEquivalent
        self.image = image
        self.preview = preview
        self.representedValue = representedValue
        self.isSelected = isSelected
        self.isEnabled = isEnabled
        self.destination = destination
    }

    /// The full chord a row draws. Historical fixture call sites that provide one bare key are
    /// command-key rows by definition, which preserves their authored classic-theme grammar.
    public var resolvedShortcut: KeyboardShortcut? {
        shortcut ?? keyEquivalent.map { KeyboardShortcut(key: $0, modifiers: .command) }
    }

    /// Sets both halves of a styled subtitle at once: the runs the row draws, and the plain
    /// join every non-drawing consumer keeps — the tooltip, the filter, the measured width.
    /// One entry point rather than two properties, because the two drifting apart is a row
    /// whose tooltip says something its pixels do not.
    public mutating func setSubtitle(_ segments: [ThemedMenuSubtitleSegment]) {
        subtitleSegments = segments.isEmpty ? nil : segments
        subtitle = segments.isEmpty ? nil : segments.map(\.text).joined()
    }

    /// Everything the row says, as one sentence — for the tooltip and for VoiceOver.
    ///
    /// Columns are a picture, and a picture is exactly what neither of those consumers gets.
    /// Announcing `item.title` alone was survivable while the reading lived in the subtitle the
    /// tooltip already carried; once it moved into aligned columns and a drawn bar, a row
    /// announced by its name alone would be a login with no reading at all.
    public var spokenSummary: String {
        var parts: [String] = []
        // Every part is admitted only when it has something in it, the title included: a row
        // built to carry a reading and no name — which is how `AccountUsageMenu.summary`
        // borrows this — otherwise opens with the separator and reads as a dropped word.
        if !title.isEmpty { parts.append(title) }
        if let titleDetail, !titleDetail.isEmpty { parts.append(titleDetail) }
        parts += metrics.map { "\($0.label) \($0.value)" }
        if let trailingDetail, !trailingDetail.isEmpty { parts.append(trailingDetail) }
        if let subtitle, !subtitle.isEmpty { parts.append(subtitle) }
        return parts.joined(separator: ThemedMenuItemDefaults.spokenSeparator)
    }
}

public enum ThemedMenuItemDefaults {
    /// Between the parts of a spoken or hovered summary. A comma rather than the drawn `·`,
    /// because this string exists for the two consumers that read it aloud or wrap it.
    public static let spokenSeparator = ", "
}

/// A live view standing in for a choice, so a menu of animations can be watched rather than
/// read one selection at a time.
///
/// An image would not do: what these rows are choosing between *is* movement, and a still of an
/// animation says only that there is one. The view is the caller's, made once and handed over,
/// which is also what keeps a preview honest — the working indicator's row draws the same
/// `WorkingOrbView` the conversation status draws, and a name transition's row the same
/// `MorphingTitleLabel` the sidebar morphs, rather than a second rendering of either.
public struct ThemedMenuPreview {

    public enum Placement {
        /// A fixed slot before the title, which still draws beside it.
        case leading
        /// The title's own place. The row draws no title of its own, because the preview *is*
        /// the name — which is the only way a text transition can be shown at all.
        case title
    }

    public let placement: Placement
    public let view: NSView

    /// The row's highlight arrived or left, by pointer or by arrow key.
    ///
    /// The row reports it; the preview decides what it means. An orb runs whether or not it is
    /// pointed at — a dropdown of animations is a comparison, and a comparison needs them all
    /// moving — while eleven names morphing at once is unreadable, so a name transition plays
    /// only where the highlight is.
    ///
    /// `false` is also delivered when the row leaves the window, so a menu dismissed
    /// mid-demonstration ends it rather than leaving something stepping against a view nobody
    /// can see.
    public var highlightChanged: ((Bool) -> Void)?
}

/// A second thing a row can do, offered at its trailing edge and never chosen by accident.
///
/// A row answers a press with one action — choosing it — and that is the right contract almost
/// everywhere. It is the wrong one for a list whose entries are something to *experience* rather
/// than read. A sound is the case: its name is not the sound, so the only way to find out what
/// `Funk` is was to accept it, and comparing three of them left the third one written into the
/// setting whether or not it was the one wanted.
///
/// Three properties make that safe, and all three are the point:
///
/// - **It never chooses.** The press is consumed here, so the menu stays open and the setting
///   stays where it was. Comparing is the whole reason the affordance exists.
/// - **It is quiet until the row is current.** Nothing is drawn until the pointer is on the row
///   or the keyboard highlight is, which is the same rule the chrome keeps everywhere else: a
///   column of glyphs down a menu of names would compete with the names.
/// - **Its column is reserved on every row of the menu regardless.** Revealing a control that
///   was not costing width would reflow the row under the pointer, and a title that shortens as
///   you arrive is worse than a glyph that was always there.
///
/// One gesture deliberately ignores it: a press held on the control that opened the menu and
/// released over a row chooses that row, accessory or not. A sweep is a choosing gesture from the
/// moment it leaves the button — the platform's own menus track a held press exactly this way and
/// offer nothing to press inside one — so the accessory answers a click on an open menu, which is
/// how a picker is actually used. `ThemedMenuAccessoryTests` pins it so the day it changes is a
/// decision.
public struct ThemedMenuAccessory {
    /// The symbol drawn in the trailing slot, resolved through `ThemedMenuIcon` so it is the
    /// size and weight every other mark in a menu is.
    public let symbolName: String
    /// What pressing it does, in the imperative: "Play". VoiceOver offers it under this name and
    /// the row says it as a tooltip while the pointer is on the glyph, which is the only
    /// explanation a hover-revealed control gets to give.
    public let title: String
    public let action: () -> Void

    public init(symbolName: String, title: String, action: @escaping () -> Void) {
        self.symbolName = symbolName
        self.title = title
        self.action = action
    }
}

/// The mark a menu row leads with, resolved once at the menu's own size and weight.
///
/// A row's `image` stays an `NSImage` because it is not always a symbol — an installed app's
/// icon, an account's mark and a theme's swatch all arrive as artwork with colours of their own.
/// Where it *is* a symbol, this is the single place that says how large and how heavy, so a menu
/// built in one feature cannot draw its icons a point off the menu built in the next. The point
/// size is `control` rather than the slot's nominal one: these sit beside a 13pt title, and that
/// pairing is what `Design.Symbol.control` is measured for.
@MainActor
public enum ThemedMenuIcon {
    public static func symbol(_ name: String) -> NSImage? {
        Design.Symbol.image(
            name,
            slot: ThemedMenuMetrics.imageSize,
            pointSize: Design.Symbol.control
        )
    }

    /// The same, one column over and one size down: a trailing accessory's glyph. The point size
    /// is derived from the slot rather than stated, so a smaller mark is *configured* smaller and
    /// keeps the stroke weight its optical size chose instead of being a shrunk render of a
    /// larger one.
    public static func accessorySymbol(_ name: String) -> NSImage? {
        Design.Symbol.image(
            name,
            slot: ThemedMenuMetrics.accessorySize,
            pointSize: Design.Symbol.pointSize(forSlot: ThemedMenuMetrics.accessorySize)
        )
    }
}

public enum ThemedMenuEntry {
    case item(ThemedMenuItem)
    case separator
    /// A name over the rows that follow it, choosing nothing itself.
    ///
    /// A separator says "these are different"; a header says what the next ones *are*, which is
    /// what lets every row underneath stop repeating it. The composer's identity menu is the
    /// case: one flat list of every runtime's logins had to write `Claude Code · ` on all three
    /// Claude rows, and that segment — the longest on the line — is what pushed the reading past
    /// the panel's width cap. Grouping is not navigation here: a header is not a submenu and
    /// costs no extra trip, so the list stays one press deep.
    case header(String)
}

/// The semantic payload handed to menu-presentation test seams.
public struct ThemedMenuPresentation {
    public let entries: [ThemedMenuEntry]
    public let minimumWidth: CGFloat

    /// Creates the semantic payload a menu presenter draws. Public because a native extension
    /// that composes with ThreadingDesignKit must be able to use the same menu surface as the
    /// host rather than falling back to `NSMenu` chrome.
    public init(entries: [ThemedMenuEntry], minimumWidth: CGFloat) {
        self.entries = entries
        self.minimumWidth = minimumWidth
    }
}

extension ThemedMenuEntry {
    /// The item this entry carries — nil for a separator. How call sites and tests read a
    /// built menu, since entries are values rather than a mutable menu object.
    public var item: ThemedMenuItem? {
        if case .item(let item) = self { return item }
        return nil
    }

    public var isItem: Bool { item != nil }
}

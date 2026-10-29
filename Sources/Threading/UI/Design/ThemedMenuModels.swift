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

/// One reading a row states as a *meter line* rather than as words inside its subtitle.
///
/// The account rows are why this exists. A subtitle can hold `5h 27% · 7d 81% · 7d resets in
/// 19h 36m`, and for one row it reads fine — but the menu's job is comparing several, and a
/// value's position in a sentence is decided by the length of the name in front of it. Three
/// logins therefore put their three 5-hour numbers at three different x positions, and the
/// comparison the menu exists for becomes a search.
///
/// A metric names its line (`label`) instead of its place, so every row puts its same-named
/// reading on the same line at the same x — every login's `5h` beside its name, every `7d`
/// directly under it. `fraction` is the reading again as a length, which is what makes the
/// ranking pre-attentive; nil draws the track alone, for a window whose number is not knowable
/// rather than one that is empty. `timeMark` puts the clock on the same bar, so spend is read
/// against time rather than against nothing. `tone` is semantic for the same reason
/// `ThemedMenuSubtitleSegment.Tone` is — the row owns the palette, and a classic selection band
/// flattens text, bar and tick to its own authored ink.
public struct ThemedMenuMetric {

    /// The line this reading belongs on, and its written name — `5h`, `7d`. Rows sharing a
    /// label share a line; a row with no metric for a line leaves it empty, which is how a plan
    /// metering one window says so beside a plan metering two.
    public let label: String
    /// The precise answer, in the line's own digits — `27%`, or `—` where the window's number
    /// would be a leftover from the window before it.
    public let value: String
    /// The same answer as a length, 0…1. Nil draws the empty track: no bar at all would read as
    /// a missing line, and a full-length one as a spent window.
    public let fraction: Double?
    public let tone: ThemedMenuSubtitleSegment.Tone
    /// How far through its period the reading's clock stands, 0…1, drawn as a tick across the
    /// bar. Fill short of the tick is spending slower than time passes; fill past it is spending
    /// faster — the one thing a percentage on its own cannot say. Nil draws no tick, for a period
    /// whose length or position is not known.
    public let timeMark: Double?
    /// The line's last word, right-aligned in a column of its own — the account rows' reset
    /// countdown, `13m` or `4d 2h`. Nil leaves the cell empty.
    public let detail: String?
    /// What `detail` says in words, for the two consumers that see neither its column nor the
    /// line it ends — the tooltip and VoiceOver: `resets in 13m` for `13m`.
    public let spokenDetail: String?
    public let detailTone: ThemedMenuSubtitleSegment.Tone

    public init(
        label: String,
        value: String,
        fraction: Double?,
        tone: ThemedMenuSubtitleSegment.Tone = .standard,
        timeMark: Double? = nil,
        detail: String? = nil,
        spokenDetail: String? = nil,
        detailTone: ThemedMenuSubtitleSegment.Tone = .muted
    ) {
        self.label = label
        self.value = value
        self.fraction = fraction
        self.tone = tone
        self.timeMark = timeMark
        self.detail = detail
        self.spokenDetail = spokenDetail ?? detail
        self.detailTone = detailTone
    }

    /// `5h 46% resets in 13m` — the line as a reader who cannot see it is told it.
    public var spokenReading: String {
        guard let spokenDetail, !spokenDetail.isEmpty else { return "\(label) \(value)" }
        return "\(label) \(value) \(spokenDetail)"
    }
}

/// The meter block every row of one menu shares: which label takes which line, and the width of
/// each of a line's four cells — name, bar, value, detail.
///
/// One value, measured once per menu by `ThemedMenuMetrics.metricPlan` and handed to every row,
/// so the rows cannot each decide where their bars start. That is what lets a column of bars be
/// compared by length and a column of values be scanned without reading.
public struct ThemedMenuMetricPlan: Equatable, Sendable {
    /// One label per line, top down — `["5h", "7d"]`. Empty when no row has a reading.
    public let lines: [String]
    public let labelWidth: CGFloat
    public let barWidth: CGFloat
    public let valueWidth: CGFloat
    /// Zero when no row's metric carries a detail, which closes the column and its gap.
    public let detailWidth: CGFloat
    public let innerGap: CGFloat
    public let detailGap: CGFloat

    public static let empty = ThemedMenuMetricPlan(
        lines: [], labelWidth: 0, barWidth: 0, valueWidth: 0, detailWidth: 0,
        innerGap: 0, detailGap: 0
    )

    public var isEmpty: Bool { lines.isEmpty }

    /// From a line's name to the end of its detail.
    public var width: CGFloat {
        guard !isEmpty else { return 0 }
        return labelWidth + innerGap + barWidth + innerGap + valueWidth
            + (detailWidth > 0 ? detailGap + detailWidth : 0)
    }
}

/// Where one meter line of a menu row was drawn, as `ThemedMenuReferenceFixture.meterLines`
/// reports it: enough for a test to check that lines stack and align across rows, and that the
/// clock's tick is drawn where the reading says.
public struct ThemedMenuMeterLine: Equatable {
    public let label: String
    public let barRect: NSRect
    public let tickRect: NSRect?
    public let valueRect: NSRect
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
    /// Readings this row states as meter lines at its trailing edge, aligned with every other
    /// row's. See `ThemedMenuMetric`. Empty on a row that has none — a menu whose rows all have
    /// none reserves no meter block at all.
    public var metrics: [ThemedMenuMetric] = []
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
    /// What this row becomes while a modifier is held — the platform's alternate menu item.
    /// See `ThemedMenuAlternate`. Set after construction like the accessory, and ignored on a
    /// row that opens a submenu: a parent turning into an action under its own open panel would
    /// leave that panel hanging off a row that no longer owns it.
    public var alternate: ThemedMenuAlternate?
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

    /// The row as it reads while `modifiers` are held: its alternate when they name it exactly,
    /// otherwise itself.
    ///
    /// Only the act changes. The name, the mark and the help are the alternate's, and the action
    /// is its alone — a row that drew "Remove Without Asking" and then ran the asking remove would
    /// be the one outcome worse than no alternate at all. Everything describing the *subject*
    /// rather than the act — subtitle, readings, selection, enablement — stays the row's, so the
    /// columns the panel reserved from the authored rows still line up. The shortcut goes: it is
    /// the chord for the row's own action, and printing it beside a different one would be a lie.
    public func resolved(holding modifiers: NSEvent.ModifierFlags) -> ThemedMenuItem {
        guard showsAlternate(holding: modifiers), let alternate else { return self }
        var shown = ThemedMenuItem(
            title: alternate.title,
            help: alternate.help,
            subtitle: subtitle,
            shortcut: nil,
            keyEquivalent: nil,
            image: alternate.image ?? image,
            preview: preview,
            representedValue: nil,
            isSelected: isSelected,
            isEnabled: isEnabled,
            destination: .action(alternate.action)
        )
        if let subtitleSegments { shown.setSubtitle(subtitleSegments) }
        shown.metrics = metrics
        shown.titleDetail = titleDetail
        shown.accessory = accessory
        return shown
    }

    /// Whether `modifiers` turn this row into its alternate.
    public func showsAlternate(holding modifiers: NSEvent.ModifierFlags) -> Bool {
        submenu == nil && alternate?.isTriggered(by: modifiers) == true
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
    /// Meters are a picture, and a picture is exactly what neither of those consumers gets.
    /// Announcing `item.title` alone was survivable while the reading lived in the subtitle the
    /// tooltip already carried; once it moved into aligned meters with a drawn bar and tick, a
    /// row announced by its name alone would be a login with no reading at all.
    public var spokenSummary: String {
        var parts: [String] = []
        // Every part is admitted only when it has something in it, the title included: a row
        // built to carry a reading and no name — which is how `AccountUsageMenu.summary`
        // borrows this — otherwise opens with the separator and reads as a dropped word.
        if !title.isEmpty { parts.append(title) }
        if let titleDetail, !titleDetail.isEmpty { parts.append(titleDetail) }
        parts += metrics.map(\.spokenReading)
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

/// The act a row offers instead while a modifier is held: the Option key's "Delete
/// Immediately" under Finder's "Move to Trash".
///
/// It exists for the fast path a person already knows they want — removing without the
/// confirmation, copying the path instead of revealing the folder — and costs nothing to anyone
/// who does not: no row is added, and the panel looks exactly as it did until the key goes down.
/// While it is held the row *says* the other act, so the press is never a surprise: the name a
/// person reads is always the action they get.
///
/// Three rules, all of them the platform's:
///
/// - **The chord is exact.** ⌥ alone reveals an Option alternate; ⌥⇧ does not, so a menu can one
///   day carry two without the larger chord also triggering the smaller one.
/// - **The panel is measured for both titles**, so pressing the key never resizes the menu under
///   the pointer.
/// - **The keyboard and VoiceOver reach it too.** Holding the key while pressing Return chooses
///   it, and the row offers it as an accessibility action, because a capability that needs a
///   held key and a pointer together would be one most people could not use.
public struct ThemedMenuAlternate {
    /// The four keys a person chords with. Caps Lock, Fn and the numeric-pad bit ride along in
    /// `modifierFlags` without anyone meaning them, so an exact comparison ignores them.
    private static let chordModifiers: NSEvent.ModifierFlags = [.option, .shift, .control, .command]

    public let title: String
    public let modifiers: NSEvent.ModifierFlags
    /// Nil keeps the row's own mark, which is usually right: the alternate acts on the same thing.
    public var image: NSImage?
    public var help: String?
    public let action: () -> Void

    public init(
        title: String,
        modifiers: NSEvent.ModifierFlags = .option,
        image: NSImage? = nil,
        help: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.modifiers = modifiers.intersection(Self.chordModifiers)
        self.image = image
        self.help = help
        self.action = action
    }

    /// Whether `flags` are exactly this alternate's chord. An alternate with no modifier is never
    /// shown: it would replace its row permanently, which is a different title, not an alternate.
    public func isTriggered(by flags: NSEvent.ModifierFlags) -> Bool {
        !modifiers.isEmpty && flags.intersection(Self.chordModifiers) == modifiers
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


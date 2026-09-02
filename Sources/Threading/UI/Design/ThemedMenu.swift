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
}

// MARK: - Presentation

/// Where an open menu hangs from.
///
/// A dropdown belongs to the control that opened it and lines up under that control's edge. A
/// menu opened by a secondary click belongs to the *pointer*: anchoring one to its whole view
/// instead puts it in the same place wherever inside the view the click landed, which reads as
/// the menu ignoring the click that asked for it.
public enum ThemedMenuAnchor {
    /// Under — or over, where there is no room — the control that opened it, aligned to its
    /// leading edge.
    case control
    /// One corner on a point given in window coordinates: the secondary-click idiom.
    case pointer(NSPoint)
}

/// A view whose presentation changes while a menu opened from it or one of its descendants is
/// on screen.
///
/// The menu is part of the source's interaction, even though its full-window overlay sits
/// elsewhere in the view tree. Publishing that fact from the presenter keeps the source control
/// held and lets a container carry hover-only actions while the pointer travels into the menu.
/// The session remembers the observer chain it opened with, so dismissal reaches the same views
/// even when a list has since detached or rearranged them.
@MainActor
public protocol ThemedMenuPresentationObserving: NSView {
    func themedMenuPresentationDidChange(isPresented: Bool)
}

/// Presents a completely app-owned dropdown above the window's content.
///
/// An overlay rather than `NSMenu`, `NSPopover`, or a borderless panel is deliberate:
///
/// - every visible pixel comes from the active app theme;
/// - the dropdown escapes any scroll view that contains its source;
/// - no second window steals key status or introduces system material;
/// - one surface owns outside-click dismissal and keyboard navigation.
///
/// The returned object is an opaque token for programmatic dismissal and for forwarding a held
/// press's drag; callers never depend on the implementation class. **The menu does not need it
/// to stay alive**: the session owns itself for as long as it is on screen (see
/// `ThemedMenuSession.open`). It used to be the caller's retention that kept the menu working,
/// and a call site that dropped the token got the worst possible failure — the overlay stayed
/// over the whole window, every dismissal callback already dead, and the window read as hung.
@MainActor
public enum ThemedMenuPresenter {

    @discardableResult
    public static func present(
        _ presentation: ThemedMenuPresentation,
        from source: NSView,
        anchor: ThemedMenuAnchor = .control,
        selectedEntryIndex: Int?,
        onChoose: @escaping (Int, ThemedMenuItem) -> Void,
        onDismiss: @escaping () -> Void
    ) -> AnyObject? {
        guard let window = source.window,
              let root = window.contentView,
              presentation.entries.contains(where: \.isItem)
        else { return nil }

        // This overlay draws inside the window; a popover is a child window above it. One left
        // open would cover the dropdown and eat the clicks meant for its rows, so opening a
        // menu closes the popovers hanging off the same window — see
        // `ThemedPopover.closeAll(presentedFrom:)`.
        ThemedPopover.closeAll(presentedFrom: window)

        // A window carries one root menu. Most controls dismiss the current overlay through
        // its outside-click handoff before opening the next one, but secondary-click routes do
        // not pass through that overlay. Without this replacement, a caller retaining one menu
        // token overwrites the first token, deallocating its session while leaving its overlay
        // attached and unable to dismiss. Close every extant session in this window before the
        // new one can replace its owner's token.
        for session in ThemedMenuSession.open.allObjects where session.window === window {
            session.close()
        }

        return ThemedMenuSession(
            presentation: presentation,
            source: source,
            anchor: anchor,
            root: root,
            window: window,
            selectedEntryIndex: selectedEntryIndex,
            onChoose: onChoose,
            onDismiss: onDismiss
        )
    }

    public static func dismiss(_ token: AnyObject?) {
        (token as? ThemedMenuSession)?.close()
    }

    /// Whether a dropdown is up in `window` right now.
    ///
    /// A dropdown is a view rather than a window, so nothing about the window itself says one
    /// is open — and `ThemedPopover`, which would draw over it, has to ask. Counted per open
    /// session rather than read off the view tree, so a menu still fading out is already gone.
    public static func isMenuOpen(in window: NSWindow) -> Bool {
        ThemedMenuSession.open.allObjects.contains { $0.window === window }
    }

    /// The press-drag-release idiom: the button went down on the source control and is still
    /// down while the pointer moves over the open menu, so rows highlight under the pointer
    /// exactly as a held `NSMenu` tracks.
    ///
    /// An open session watches that press itself (see `heldPressMask`); this is the same
    /// tracking entered by hand, for a caller holding the events already.
    public static func dragUpdated(_ token: AnyObject?, event: NSEvent) {
        (token as? ThemedMenuSession)?.dragUpdated(event)
    }

    /// The held press ends. Over an enabled row it chooses; back over the source it goes
    /// sticky (the ordinary click-then-browse open); anywhere else it lets the menu go.
    public static func dragEnded(_ token: AnyObject?, event: NSEvent) {
        (token as? ThemedMenuSession)?.dragEnded(event)
    }

    /// Which half of a press-drag-release an opening menu should listen for, or nil for a menu
    /// that no held button opened — a keyboard route, an accessibility action, a click already
    /// released — where there is no press to track and every later drag belongs to something
    /// else.
    ///
    /// `opening` is the event AppKit is dispatching as the menu opens, which is what makes this
    /// *this* press rather than any button that happens to be down; the button state is the
    /// corroboration, and either one alone is enough. A menu opened from a timer during a held
    /// press is still tracking that press, and a synthesized open (tests, scripted UI) has no
    /// current event to read.
    public static func heldPressMask(
        opening event: NSEvent?,
        pressedButtons: Int
    ) -> NSEvent.EventTypeMask? {
        let left: NSEvent.EventTypeMask = [.leftMouseDragged, .leftMouseUp]
        let right: NSEvent.EventTypeMask = [.rightMouseDragged, .rightMouseUp]
        switch event?.type {
        case .leftMouseDown, .leftMouseDragged:
            return left
        case .rightMouseDown, .rightMouseDragged:
            return right
        default:
            break
        }
        if pressedButtons & 0b01 != 0 { return left }
        if pressedButtons & 0b10 != 0 { return right }
        return nil
    }
}

// MARK: - Handoff

/// A control whose press opens a `ThemedMenuPresenter` dropdown.
///
/// This roster is what lets the click that dismisses one menu *land* on a sibling that opens
/// another. The overlay swallows its dismissing click the way `NSMenu` does — but hit testing
/// is not what drives hover, so a chip under the overlay keeps its hover invitation (it even
/// widens to its full label) while a click on it would silently vanish. A control that shows
/// that invitation must honour the click: the overlay re-dispatches it, and the press behaves
/// exactly as if no menu had been open. Everything else keeps the platform's swallow — a click
/// on the terminal to let a menu go must not also type into it.
@MainActor
public protocol ThemedMenuOpening: NSView {
    /// Whether a press would open this control's menu right now — enabled, and for controls
    /// that carry both gestures, configured to present one.
    var opensMenuOnPress: Bool { get }
}

// Gathered here rather than spread across the adopters: who may take the handoff is the
// presenter's contract, and one place states the whole roster.
extension ChipView: ThemedMenuOpening {
    public var opensMenuOnPress: Bool { isEnabled }
}

extension ThemedPopUp: ThemedMenuOpening {
    public var opensMenuOnPress: Bool { isEnabled }
}

extension ThemedIconButton: ThemedMenuOpening {
    public var opensMenuOnPress: Bool { presentsMenu && isEnabled }
}

/// Where a press-drag-release ended, as the overlay reports it to the session.
private enum ThemedMenuDragTarget {
    case row(Int, ThemedMenuItem)
    /// On the panel, but not on anything choosable — a separator, padding, a disabled row.
    case surface
    case outside
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

// MARK: - Geometry

@MainActor
public enum ThemedMenuLayout {
    /// Modern popovers float off their opener. A classic dropdown is the other half of its
    /// control and starts on the control's edge, as a Win32 popup menu does.
    public static var gap: CGFloat { ThemedMenuMetrics.usesClassicGrammar ? 0 : Design.Spacing.tight }
    public static let screenInset: CGFloat = Design.Spacing.small
    /// The tallest panel a window may carry — a share of the window rather than a flat number.
    /// The cap was a flat 360, set when the longest menu was half its eventual size; by the
    /// time the session row's menu had grown, it overflowed that cap in every ordinarily sized
    /// window, which made scrolling the *normal* state and put Delete Session below the fold
    /// on every right-click. A menu's ceiling is the window it serves: a tall window shows the
    /// whole list, and the floor keeps a cramped window exactly where the flat cap left it.
    public static let maximumHeightRatio: CGFloat = 0.75
    public static let maximumHeightFloor: CGFloat = 360
    public static let maximumWidth: CGFloat = 440

    public static func maximumHeight(in bounds: NSRect) -> CGFloat {
        max(maximumHeightFloor, bounds.height * maximumHeightRatio)
    }

    /// How few rows a panel may be squeezed to before it stops being a list at all.
    ///
    /// The room beside a control is the room its window has, and a small window has almost
    /// none: a pop-up in a dialog sized to its own two lines of text opened a list of
    /// ninety-six quarter hours **one and a half rows tall**, which says "there is more here"
    /// and nothing else — not one answer the user could have been looking for was on screen.
    /// Four rows is where a dropdown starts reading as a list; below that the panel stops
    /// respecting the control's edge and takes the window instead (see `frame`), which is what
    /// a platform menu does on a screen too short to hold it.
    public static let minimumVisibleRows: CGFloat = 4

    public static var minimumUsefulHeight: CGFloat {
        ThemedMenuMetrics.verticalOuterInset * 2 + ThemedMenuMetrics.rowHeight * minimumVisibleRows
    }

    /// `whenClipped` is given the clamped height and answers with the one to use, which is how
    /// a panel that cannot show every row ends on half a row instead of on a clean edge. It is
    /// passed in rather than read from the entries so this stays plain geometry a test can call;
    /// `ThemedMenuMetrics.clippedHeight(for:atMost:)` is what every caller hands it.
    public static func frame(
        anchor: NSRect,
        desiredSize: NSSize,
        in bounds: NSRect,
        flipped: Bool,
        gap: CGFloat = ThemedMenuLayout.gap,
        whenClipped: (CGFloat) -> CGFloat = { $0 }
    ) -> NSRect {
        let width = min(desiredSize.width, max(0, bounds.width - screenInset * 2))
        let x = min(
            max(anchor.minX, bounds.minX + screenInset),
            max(bounds.minX + screenInset, bounds.maxX - screenInset - width)
        )

        let roomBefore: CGFloat
        let roomAfter: CGFloat
        if flipped {
            roomBefore = anchor.minY - bounds.minY - gap - screenInset
            roomAfter = bounds.maxY - anchor.maxY - gap - screenInset
        } else {
            roomBefore = bounds.maxY - anchor.maxY - gap - screenInset
            roomAfter = anchor.minY - bounds.minY - gap - screenInset
        }

        let opensAfter = roomAfter >= min(desiredSize.height, maximumHeight(in: bounds))
            || roomAfter >= roomBefore
        let available = max(0, opensAfter ? roomAfter : roomBefore)
        // The side is chosen against the clamped height, then the peek is taken out of it:
        // shortening a panel never changes which side it had room on.
        let ceiling = min(desiredSize.height, maximumHeight(in: bounds))
        // Neither side of the control can hold a readable list, so the panel stops clearing the
        // control and lies over it instead — every row the window can show, rather than the
        // sliver the gap below the control left. See `minimumUsefulHeight`.
        let overlapsAnchor = min(ceiling, available) < min(ceiling, minimumUsefulHeight)
        let clamped = overlapsAnchor
            ? min(ceiling, max(0, bounds.height - screenInset * 2))
            : min(ceiling, available)
        let height = clamped < desiredSize.height ? whenClipped(clamped) : clamped

        var y: CGFloat
        if flipped {
            y = opensAfter ? anchor.maxY + gap : anchor.minY - gap - height
        } else {
            y = opensAfter ? anchor.minY - gap - height : anchor.maxY + gap
        }
        if overlapsAnchor {
            // Slid back inside the window from wherever the control put it, so the panel keeps
            // the edge it was opened from while staying whole.
            y = min(
                max(y, bounds.minY + screenInset),
                max(bounds.minY + screenInset, bounds.maxY - screenInset - height)
            )
        }
        return NSRect(x: x, y: y, width: width, height: height)
    }

    /// How far a submenu tucks under its parent panel's edge. Panels that merely touched read
    /// as two unrelated windows; the platform's own submenus overlap for the same reason.
    public static var submenuOverlap: CGFloat {
        switch ThemedMenuMetrics.appearance {
        case .windows98: return 5
        case .automatic: return gap
        default: return 2
        }
    }

    /// Where a submenu panel lands: beside its parent panel, its first row level with the row
    /// that opened it. To the right until there is no room, then mirrored to the left; clamped
    /// vertically the way the root panel is.
    ///
    /// `firstRowInset` is the panel's own padding above its first row
    /// (`ThemedMenuMetrics.outerInset`), passed in so this stays plain geometry a test can call.
    public static func submenuFrame(
        parentPanel: NSRect,
        rowFrame: NSRect,
        desiredSize: NSSize,
        in bounds: NSRect,
        flipped: Bool,
        firstRowInset: CGFloat,
        whenClipped: (CGFloat) -> CGFloat = { $0 }
    ) -> NSRect {
        let width = min(desiredSize.width, maximumWidth, max(0, bounds.width - screenInset * 2))
        var x = parentPanel.maxX - submenuOverlap
        if x + width > bounds.maxX - screenInset {
            x = parentPanel.minX - width + submenuOverlap
        }
        x = min(max(x, bounds.minX + screenInset), bounds.maxX - screenInset - width)

        let clamped = min(
            desiredSize.height,
            maximumHeight(in: bounds),
            max(0, bounds.height - screenInset * 2)
        )
        let height = clamped < desiredSize.height ? whenClipped(clamped) : clamped
        let y: CGFloat
        if flipped {
            y = min(
                max(rowFrame.minY - firstRowInset, bounds.minY + screenInset),
                bounds.maxY - screenInset - height
            )
        } else {
            let top = min(
                max(rowFrame.maxY + firstRowInset, bounds.minY + screenInset + height),
                bounds.maxY - screenInset
            )
            y = top - height
        }
        return NSRect(x: x, y: y, width: width, height: height)
    }
}

// MARK: - Session

@MainActor
private final class ThemedMenuSession: NSObject {

    /// Weak because a transient menu must not keep a recycled source row alive. The session's
    /// source is weak for the same reason; this is the rest of the source-to-root chain.
    private final class WeakPresentationObserver {
        weak var view: NSView?

        init(_ view: NSView) {
            self.view = view
        }
    }

    /// The sessions currently up — how `ThemedMenuPresenter.isMenuOpen(in:)` answers for a
    /// window, and the session's **owner** while its menu is on screen. Strong on purpose:
    /// nothing else is obliged to retain a session — the overlay's callbacks hold it weakly,
    /// and the token `present` returns is optional to keep. When the roster was weak, a call
    /// site that dropped that token (the composer's clock) had its session deallocate under a
    /// menu that had just opened, which stranded the overlay across the whole window with every
    /// dismissal callback dead — no click, no Escape, nothing; the window read as hung.
    /// Dropped in `finish`, which every exit path funnels through exactly once, so ownership
    /// ends where the session does rather than where its exit animation does. The presenter
    /// closes a window's current session before adding its replacement; keeping the roster as
    /// sessions still lets the dismiss-and-open handoff complete synchronously inside one click.
    static let open = NSHashTable<ThemedMenuSession>(options: .strongMemory)

    private weak var source: NSView?
    fileprivate weak var window: NSWindow?
    private let presentationObservers: [WeakPresentationObserver]
    private let overlay: ThemedMenuOverlayView
    private let onChoose: (Int, ThemedMenuItem) -> Void
    private let onDismiss: () -> Void
    private weak var previousInitialFirstResponder: NSView?
    private var focusRunLoopObserver: CFRunLoopObserver?
    private var keyEventMonitor: Any?
    private var heldPressMonitor: Any?
    /// Where the press that opened this menu went down, in window coordinates — what a release
    /// is measured against to tell a sweep from a click. Nil for a menu no press opened.
    private var pressOrigin: NSPoint?
    private var isClosed = false

    init(
        presentation: ThemedMenuPresentation,
        source: NSView,
        anchor: ThemedMenuAnchor,
        root: NSView,
        window: NSWindow,
        selectedEntryIndex: Int?,
        onChoose: @escaping (Int, ThemedMenuItem) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.source = source
        self.window = window
        presentationObservers = Self.presentationObservers(from: source)
        self.onChoose = onChoose
        self.onDismiss = onDismiss

        let menuWidth = ThemedMenuMetrics.width(
            for: presentation.entries,
            minimum: presentation.minimumWidth,
            selectedEntryIndex: selectedEntryIndex
        )
        let menuHeight = ThemedMenuMetrics.height(for: presentation.entries)
        let anchorRect: NSRect
        let gap: CGFloat
        switch anchor {
        case .control:
            anchorRect = source.convert(source.bounds, to: root)
            gap = ThemedMenuLayout.gap
        case .pointer(let windowPoint):
            anchorRect = NSRect(origin: root.convert(windowPoint, from: nil), size: .zero)
            // No standoff: the gap exists so a dropdown clears the button it belongs to, and
            // the pointer has no edge to clear. Held off it, the panel would read as opening
            // near the click rather than at it.
            gap = 0
        }
        let menuFrame = ThemedMenuLayout.frame(
            anchor: anchorRect,
            desiredSize: NSSize(width: menuWidth, height: menuHeight),
            in: root.bounds,
            flipped: root.isFlipped,
            gap: gap,
            whenClipped: {
                ThemedMenuMetrics.clippedHeight(for: presentation.entries, atMost: $0)
            }
        )
        overlay = ThemedMenuOverlayView(
            frame: root.bounds,
            menuFrame: menuFrame,
            entries: presentation.entries,
            selectedEntryIndex: selectedEntryIndex
        )

        super.init()

        Self.open.add(self)
        notifyPresentationObservers(isPresented: true)
        overlay.menuSource = source
        overlay.onDismiss = { [weak self] in self?.closeFromUser() }
        overlay.onChoose = { [weak self] index, item in self?.choose(index: index, item: item) }
        overlay.onPressBegan = { [weak self] event in self?.pressBeganOnMenu(event) }
        overlay.autoresizingMask = [.width, .height]
        root.addSubview(overlay, positioned: .above, relativeTo: nil)
        // The overlay covers the window's content, so everything the pointer could reach under
        // it — the split view's seams offering to drag a pane, the composer's editor offering
        // its I-beam, every chip lighting as hovered — belongs to something a click can no
        // longer land on. See `CoveredWindowPointer`.
        CoveredWindowPointer.claim(overlay, covering: window, cursor: .arrow)
        // The surface is constructed before the overlay joins the source's view tree. A
        // window-local appearance (the gallery's Light/Dark preview) may therefore differ from
        // the app appearance under which its layer-backed fill first resolved. Re-resolve once
        // attached so menu fill, rows, and text all use the source window's appearance.
        AppThemeRefresh.repaint(overlay)
        // AppKit may apply `initialFirstResponder` after attachment. Point that deferred choice
        // at the modal menu itself instead of racing it with an arbitrarily delayed main-queue
        // callback; a busy app can have more than one run-loop turn of work already queued.
        previousInitialFirstResponder = window.initialFirstResponder
        window.initialFirstResponder = overlay
        window.makeFirstResponder(overlay)
        overlay.animateIn()
        installFocusRunLoopObserver()
        installKeyEventMonitor()
        installHeldPressMonitor(opening: NSApp.currentEvent)

        // `willClose` joined the list when the roster became the session's owner: a session
        // that outlived a closing window would otherwise sit in the roster holding its dead
        // overlay, because nothing else ends a session whose window simply left.
        for name in [
            NSWindow.didResignKeyNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didResizeNotification,
            NSWindow.willCloseNotification
        ] {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowChanged),
                name: name,
                object: window
            )
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// The source plus each presentation-aware container around it, captured before the overlay
    /// changes hit testing or a list gets a chance to recycle the row.
    private static func presentationObservers(from source: NSView) -> [WeakPresentationObserver] {
        var observers: [WeakPresentationObserver] = []
        var candidate: NSView? = source
        while let view = candidate {
            if view is any ThemedMenuPresentationObserving {
                observers.append(WeakPresentationObserver(view))
            }
            candidate = view.superview
        }
        return observers
    }

    private func notifyPresentationObservers(isPresented: Bool) {
        for observer in presentationObservers {
            (observer.view as? any ThemedMenuPresentationObserving)?
                .themedMenuPresentationDidChange(isPresented: isPresented)
        }
    }

    /// A dropdown is modal keyboard UI for as long as it is open. AppKit can apply a window's
    /// deferred initial responder after attachment, and any main-queue backlog makes a one-shot
    /// async reclaim arrive arbitrarily late. `beforeWaiting` alone is insufficient: a busy app
    /// can keep dispatching sources without reaching an idle boundary at all. Enforce the
    /// invariant both before source dispatch and before an eventual wait, so the next user event
    /// and every idle interval begin with the open overlay owning Escape and arrows.
    private func installFocusRunLoopObserver() {
        let activities = CFRunLoopActivity.beforeSources.rawValue
            | CFRunLoopActivity.beforeWaiting.rawValue
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault,
            activities,
            true,
            0
        ) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, !self.isClosed, let window = self.window,
                      window.firstResponder !== self.overlay else { return }
                window.makeFirstResponder(self.overlay)
            }
        }
        focusRunLoopObserver = observer
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    private func removeFocusRunLoopObserver() {
        guard let focusRunLoopObserver else { return }
        CFRunLoopRemoveObserver(CFRunLoopGetMain(), focusRunLoopObserver, .commonModes)
        self.focusRunLoopObserver = nil
    }

    /// AppKit's first-responder bookkeeping is not the menu's event boundary. A field editor,
    /// deferred initial responder, or another control can temporarily take focus while the
    /// overlay is up; a native menu still owns Escape, arrows, Return, and type-to-select in
    /// that state. Route key events from this window through the open overlay before ordinary
    /// responder dispatch, while the focus observer keeps the visible keyboard focus honest.
    private func installKeyEventMonitor() {
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self, weak window] event in
            guard let self, !self.isClosed, event.window === window else { return event }
            self.overlay.keyDown(with: event)
            return nil
        }
    }

    private func removeKeyEventMonitor() {
        guard let keyEventMonitor else { return }
        NSEvent.removeMonitor(keyEventMonitor)
        self.keyEventMonitor = nil
    }

    /// The press that opened this menu, for as long as it is held.
    ///
    /// Press-drag-release — hold the button down, sweep to a row, let go — is the other half of
    /// how every platform menu is used, and it belongs to the menu rather than to whatever
    /// opened it. It used to be the opener's job: two controls forwarded their `mouseDragged`
    /// and `mouseUp` here and the rest of the app did not, so the gesture worked on a pop-up and
    /// on an account chip and nowhere else. A secondary-click menu could never have joined them
    /// — nothing owns the right button between its press and its release, and the view that saw
    /// `rightMouseDown` is not asked again.
    ///
    /// The monitor watches only the button already down when the menu opened, so a menu opened
    /// from the keyboard, from accessibility, or on a click's *release* tracks nothing; it passes
    /// every event on, because the press still belongs to the control underneath as well.
    ///
    /// `opening` is also how a *later* press joins: see `pressBeganOnMenu`.
    private func installHeldPressMonitor(opening: NSEvent?) {
        guard let matching = ThemedMenuPresenter.heldPressMask(
            opening: opening,
            pressedButtons: NSEvent.pressedMouseButtons
        ) else { return }
        pressOrigin = opening.map(windowPoint(of:))
        heldPressMonitor = NSEvent.addLocalMonitorForEvents(matching: matching) {
            [weak self] event in
            guard let self, !self.isClosed else { return event }
            switch event.type {
            case .leftMouseUp, .rightMouseUp:
                self.dragEnded(event)
            default:
                self.dragUpdated(event)
            }
            return event
        }
    }

    private func removeHeldPressMonitor() {
        guard let heldPressMonitor else { return }
        NSEvent.removeMonitor(heldPressMonitor)
        self.heldPressMonitor = nil
    }

    /// A press that goes down **on the open menu** is the same gesture, started later.
    ///
    /// A menu is browsed two ways and a platform menu answers both: hold the press that opened it
    /// and sweep, or let that click go and press again anywhere on the panel. Only the first was
    /// tracked here, because tracking began from the opening event and ended at its release — so
    /// after a plain click-to-open, a press on a row lit nothing as it swept and chose nothing
    /// where it was let go. The row that took the press owned the whole gesture: its own
    /// `mouseUp` fires only inside its own bounds, so a release one row further down was silently
    /// nothing at all.
    ///
    /// Tracking is per gesture, not per menu: an existing held press keeps its own origin, so the
    /// row press AppKit reports *inside* a sweep that is already being tracked changes nothing.
    private func pressBeganOnMenu(_ event: NSEvent) {
        guard !isClosed, heldPressMonitor == nil else { return }
        installHeldPressMonitor(opening: event)
    }

    /// An event's location in the menu's own window.
    ///
    /// A drag keeps reporting through the window its press began in, which is this one — but a
    /// release that lands outside every window of the app carries no window at all and states
    /// itself on screen instead. Reading `locationInWindow` raw would then measure a screen
    /// point against a window-relative panel, and let a release far outside the menu land on a
    /// row.
    private func windowPoint(of event: NSEvent) -> NSPoint {
        guard let window else { return event.locationInWindow }
        guard let eventWindow = event.window else {
            return window.convertPoint(fromScreen: event.locationInWindow)
        }
        guard eventWindow !== window else { return event.locationInWindow }
        return window.convertPoint(
            fromScreen: eventWindow.convertPoint(toScreen: event.locationInWindow)
        )
    }

    @objc private func windowChanged() {
        close()
    }

    private func choose(index: Int, item: ThemedMenuItem) {
        guard !isClosed else { return }
        finish(exit: .confirm(index))
        onChoose(index, item)
    }

    /// Programmatic dismissal — the window changed under the menu, or the source is leaving.
    /// Instant, because the anchor the animation would play against is already gone.
    func close() {
        finish(exit: .instant)
    }

    func dragUpdated(_ event: NSEvent) {
        guard !isClosed else { return }
        overlay.pointerHighlight(atWindowPoint: windowPoint(of: event))
    }

    /// The held press ends. The menu answers first and the source only for a release that missed
    /// it: a context menu is presented from the view it was invoked on — the terminal, a file
    /// tree, a diff — and opens *over* it, so asking the source first would read every release on
    /// a row as a release back on the control and choose nothing.
    func dragEnded(_ event: NSEvent) {
        guard !isClosed else { return }
        let point = windowPoint(of: event)
        // This press is spent either way; what follows is a fresh gesture the overlay answers.
        let origin = pressOrigin
        pressOrigin = nil
        removeHeldPressMonitor()

        // Let go where it went down: a click, not a sweep, and the menu stays up to be browsed.
        if let origin,
           hypot(point.x - origin.x, point.y - origin.y)
               <= ThemedMenuMotion.stickyPressDistance {
            return
        }

        switch overlay.dragTarget(atWindowPoint: point) {
        case .row(let index, let item):
            choose(index: index, item: item)
        case .surface:
            break
        case .outside:
            if let source, source.bounds.contains(source.convert(point, from: nil)) {
                // Released back on the control: the plain click-to-open. The menu stays for
                // browsing, which is the other half of how platform menus track a press.
                return
            }
            closeFromUser()
        }
    }

    /// The user let the menu go without choosing: Escape, or a click outside it.
    private func closeFromUser() {
        finish(exit: .fade)
    }

    /// Everything observable ends here, synchronously — observers, first responder, the
    /// accessibility tree, hit testing, `onDismiss`. Only pixels outlive this call: an
    /// animated exit fades what is already, by contract, gone.
    private func finish(exit: ThemedMenuExit) {
        guard !isClosed else { return }
        isClosed = true
        // The roster may be this session's only owner (see `open`), so hold one more
        // reference across the teardown: `remove` freeing the session mid-`finish` would be a
        // use-after-free dressed as a menu closing. The removal still comes first, because
        // `onDismiss` runs inside this call and may ask `isMenuOpen(in:)` about the window.
        withExtendedLifetime(self) {
            Self.open.remove(self)
            removeFocusRunLoopObserver()
            removeKeyEventMonitor()
            removeHeldPressMonitor()
            NotificationCenter.default.removeObserver(self)
            if let window, window.initialFirstResponder === overlay {
                window.initialFirstResponder = previousInitialFirstResponder
            }
            if let window, window.firstResponder === overlay, let source {
                window.makeFirstResponder(source)
            }
            notifyPresentationObservers(isPresented: false)
            overlay.tearDown(exit: exit)
            // After the teardown and ahead of the exit animation: the pixels that outlive this
            // call take no clicks — `tearDown` has already stopped the overlay answering hit
            // tests — so the window under them is the pointer's again, cursor and hover
            // included. The arrivals the overlay held back are delivered here, and a control they
            // reach may ask whether it is still covered; asked before the teardown, it would have
            // been told yes.
            CoveredWindowPointer.release(overlay)
            onDismiss()
        }
    }
}

/// How a closing menu leaves the screen. Every path has already ended the session; this only
/// names the pixels' exit.
public enum ThemedMenuExit {
    case instant
    case fade
    /// The classic confirmation blink: the chosen row flickers once, then the panel fades.
    case confirm(Int)
}

// MARK: - Overlay

private final class ThemedMenuOverlayView: ThemedControl {

    var onChoose: ((Int, ThemedMenuItem) -> Void)?
    var onDismiss: (() -> Void)?
    /// A press went down on a panel — a row, or the panel's own ground between them. The session
    /// tracks it as the gesture it is, rather than leaving the pressed row to answer alone.
    var onPressBegan: ((NSEvent) -> Void)?

    /// The control whose menu this overlay carries, so the dismissing-click handoff can tell a
    /// sibling (open its menu) from the source itself (a toggle, which only closes).
    weak var menuSource: NSView?

    /// The sibling the dismissing press was handed to, kept so the rest of that press — its
    /// drag and release — follows it there.
    private weak var handoffTarget: NSView?

    /// One open panel: the root dropdown at depth zero, or a submenu hanging off `parentRow`
    /// in the column before it. The chain is a stack — a column closes with everything deeper
    /// than it — and the deepest column is the one the keyboard speaks to.
    private struct MenuColumn {
        /// A plain chassis under the surface carrying the elevation shadow. Separate on
        /// purpose: the surface's own layer belongs to `applySurface`, whose theme glow clears
        /// and rewrites layer shadow state on every repaint — a shadow set there would not
        /// survive the first theme refresh. It is also what the appear animation scales, so
        /// the shadow arrives with the panel instead of sitting full-strength under a panel
        /// still growing.
        let host: NSView
        let surface: ThemedMenuSurfaceView
        /// The row in the previous column this panel hangs off; nil only at the root.
        weak var parentRow: ThemedMenuRowView?
        var highlightedIndex: Int?
    }

    private var columns: [MenuColumn] = []
    private var isTearingDown = false

    /// The row whose choice is closing the menu, kept for the confirmation blink — an index
    /// alone cannot say *which panel's* row it names once submenus exist.
    private weak var chosenRow: ThemedMenuRowView?

    // Hover-driven submenu pacing. Timed rather than immediate, because a pointer sweeping
    // down a column crosses every parent row on the way past; the delays are stated and
    // justified on `ThemedMenuMotion`.
    private var submenuOpenTimer: Timer?
    private var submenuCloseTimer: Timer?
    private var travelTimer: Timer?
    /// Where the pointer last was, in overlay coordinates — fed by `mouseMoved`, read by the
    /// safe-travel corridor and the close-grace check.
    private var lastPointerPoint: NSPoint?
    /// Where the pointer stood, in window coordinates, when a panel last scrolled under it.
    /// Scrolling delivers `mouseEntered` to whichever row slides under a stationary pointer —
    /// the list's motion, not the hand's — and a highlight that walks the menu while the user
    /// scrolls it is answering a question nobody asked. While this is set, rows may not take
    /// the highlight from hover; the pointer buys it back by actually moving.
    private var scrollFreezePoint: NSPoint?
    /// A pointer highlight held back while the pointer travels toward an open submenu,
    /// applied the moment the travel visibly stops being travel.
    private var pendingTravelHighlight: (column: Int, entry: Int)?
    /// Where the corridor starts: the pointer's position when it left the open parent row.
    private var travelApex: NSPoint?
    private var travelDeadline: TimeInterval = 0
    private var pointerTrackingArea: NSTrackingArea?

    /// What has been typed since the menu opened. Letters filter: matching rows keep their
    /// ink, the rest dim, and the highlight lands on the first match — the menu keeps its
    /// shape rather than reflowing under the pointer on every keystroke. The filter belongs
    /// to the deepest open panel, and opening or closing one resets it.
    private var filterQuery = "" {
        didSet {
            guard filterQuery != oldValue, !isTearingDown,
                  let column = columns.last else { return }
            column.surface.applyFilter(filterQuery)
            let indices = activeIndices
            if let highlighted = column.highlightedIndex, indices.contains(highlighted) {
                return
            }
            setHighlight(columnIndex: columns.count - 1, entryIndex: indices.first)
        }
    }

    /// The rows arrow keys and Return may land on — the deepest panel's enabled rows,
    /// narrowed to the matches while a filter is active.
    private var activeIndices: [Int] {
        columns.last?.surface.selectableIndices(matching: filterQuery) ?? []
    }

    init(
        frame: NSRect,
        menuFrame: NSRect,
        entries: [ThemedMenuEntry],
        selectedEntryIndex: Int?
    ) {
        super.init(frame: frame)

        setAccessibilityElement(false)
        addColumn(
            entries: entries,
            frame: menuFrame,
            parentRow: nil,
            selectedEntryIndex: selectedEntryIndex
        )

        let root = columns[0].surface
        let initial = root.selectableIndices.contains(selectedEntryIndex ?? -1)
            ? selectedEntryIndex
            : root.selectableIndices.first
        setHighlight(columnIndex: 0, entryIndex: initial)
    }

    /// Builds one panel — chassis, shadow, surface — and stacks it. The closures capture the
    /// column's index, which is stable for the surface's lifetime: columns close strictly from
    /// the deep end, so a surviving surface never changes position.
    @discardableResult
    private func addColumn(
        entries: [ThemedMenuEntry],
        frame: NSRect,
        parentRow: ThemedMenuRowView?,
        selectedEntryIndex: Int?
    ) -> Int {
        let surface = ThemedMenuSurfaceView(
            frame: NSRect(origin: .zero, size: frame.size),
            entries: entries,
            selectedEntryIndex: selectedEntryIndex
        )
        let host = NSView()
        host.frame = frame
        host.wantsLayer = true
        host.layer?.masksToBounds = false
        // A fixed neutral on purpose — the same exception the icon backplates carry. A shadow
        // exists to separate the panel from whatever the theme drew behind it, and every
        // themed colour follows that ground.
        host.applyLayerShadow(NSColor.black)
        host.layer?.shadowOpacity = ThemedMenuMotion.shadowOpacity
        host.layer?.shadowRadius = ThemedMenuMotion.shadowRadius
        host.layer?.shadowOffset = .zero
        addSubview(host)
        surface.autoresizingMask = [.width, .height]
        host.addSubview(surface)
        // The surface resolved its layer fill before joining a window; re-resolve under the
        // window it actually landed in — the same correction the session makes for the root.
        AppThemeRefresh.repaint(host)

        let index = columns.count
        surface.onChoose = { [weak self] entryIndex, item in
            self?.rowChosen(columnIndex: index, entryIndex: entryIndex, item: item)
        }
        surface.onHighlight = { [weak self] entryIndex in
            self?.pointerHighlighted(columnIndex: index, entryIndex: entryIndex)
        }
        surface.onPressBegan = { [weak self] event in self?.onPressBegan?(event) }
        // A submenu is anchored to where its parent row was at open; a parent that scrolls
        // under it would leave the panel beside the wrong row, so scrolling closes deeper.
        surface.onScrolled = { [weak self] in
            self?.columnDidScroll(deeperThan: index)
        }
        columns.append(MenuColumn(
            host: host,
            surface: surface,
            parentRow: parentRow,
            highlightedIndex: nil
        ))
        return index
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }
    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityPerformPress() -> Bool {
        onDismiss?()
        return true
    }

    /// The overlay watches raw pointer motion as well as the rows' own hover, because the
    /// safe-travel corridor is a claim about *movement* — where the pointer is heading — and
    /// a row's enter/exit can only say where it is.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea {
            removeTrackingArea(pointerTrackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        pointerTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        lastPointerPoint = convert(event.locationInWindow, from: nil)
        if let freeze = scrollFreezePoint,
           hypot(event.locationInWindow.x - freeze.x, event.locationInWindow.y - freeze.y)
               > ThemedMenuMotion.scrollHoverTolerance {
            // The pointer moved for real after a scroll. Crossing into the row now under it
            // fires no fresh `mouseEntered` — that row has believed itself hovered since the
            // scroll delivered its enter — so the landing is re-answered from position.
            scrollFreezePoint = nil
            pointerHighlight(atWindowPoint: event.locationInWindow)
        }
        resolveTravel()
    }

    /// A panel scrolled: its rows moved, the pointer did not. The freeze keeps hover from
    /// claiming the highlight until the pointer visibly moves, the armed hover-open dies
    /// because the row it was resting on is no longer where the rest happened, and deeper
    /// panels close because the row they hang off has slid away from under them. The freeze
    /// point is read at the scroll rather than from `lastPointerPoint`: a pointer that has
    /// not moved since the menu opened has produced no `mouseMoved` to remember.
    private func columnDidScroll(deeperThan index: Int) {
        if let window {
            scrollFreezePoint = window.mouseLocationOutsideOfEventStream
        }
        submenuOpenTimer?.invalidate()
        closeColumns(from: index + 1)
    }

    /// A closing menu takes no more events. Hit testing alone does not cover tracking areas,
    /// which is why the row handlers also check `isTearingDown` before acting.
    override func hitTest(_ point: NSPoint) -> NSView? {
        isTearingDown ? nil : super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        // A press that landed on a panel is a press on the *menu*: its inset, a separator, the
        // strip the filter opens. Only a press that missed every panel is the click outside one
        // that lets it go. Rows answer their own press and report it themselves; everything else
        // inside a panel reaches here through the responder chain, and used to be read as the
        // dismissing click — a menu closing from a point the pointer was inside.
        let point = convert(event.locationInWindow, from: nil)
        if columns.contains(where: { $0.host.frame.contains(point) }) {
            onPressBegan?(event)
            return
        }

        let window = self.window
        let source = menuSource
        onDismiss?()

        // The dismissing click is swallowed, as `NSMenu` swallows it — unless it landed on a
        // sibling that opens a menu of its own. Hit testing is not what drives hover, so that
        // sibling kept its hover invitation under this overlay the whole time; a control that
        // invites the click must honour it. The teardown above has already taken this overlay
        // out of hit testing, so the window's tree resolves to what the user was aiming at,
        // and the press is handed to it as if no menu had been open. A click back on the
        // control that opened *this* menu stays a plain toggle-close, and a click anywhere
        // else keeps the platform's swallow — letting a menu go by clicking the terminal
        // must not also type into it.
        guard let window,
              let target = Self.menuOpener(in: window, at: event.locationInWindow),
              target !== source
        else { return }
        handoffTarget = target
        target.mouseDown(with: event)
    }

    // The press that dismissed this menu may still be held while AppKit keeps routing its drag
    // and release here, the mouse-down view. Forwarded to the control the press was handed to,
    // so press-drag-release keeps choosing on the menu it opened — the same forwarding that
    // control does for a press that began on it.
    override func mouseDragged(with event: NSEvent) {
        handoffTarget?.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        handoffTarget?.mouseUp(with: event)
    }

    /// The menu-opening control under a window point, or nil where the swallow should stand.
    /// Resolved by walking up from the deepest hit, because the pixel under a click on a chip
    /// is usually its label.
    private static func menuOpener(in window: NSWindow, at windowPoint: NSPoint) -> NSView? {
        guard let root = window.contentView else { return nil }
        let point = root.superview?.convert(windowPoint, from: nil) ?? windowPoint
        var view = root.hitTest(point)
        while let current = view {
            if let opener = current as? ThemedMenuOpening {
                return opener.opensMenuOnPress ? opener : nil
            }
            view = current.superview
        }
        return nil
    }

    // MARK: - Motion

    /// The dropdown materialises: a quick fade with a subtle grow from centre. Decorative
    /// only — the model values are already final, so nothing here can be left half-arrived.
    func animateIn() {
        guard let host = columns.first?.host else { return }
        Self.animateAppear(host)
    }

    /// One arrival for every panel, so a submenu materialises exactly as its root did.
    private static func animateAppear(_ host: NSView) {
        let duration = Design.Motion.appear
        // AppKit does not advance offscreen window animations. Apart from doing work nobody can
        // see, attaching one here leaves test and preview windows holding animation machinery
        // whose completion can never be delivered.
        guard duration > 0, host.window?.isVisible == true, let layer = host.layer else { return }

        // Composed about the layer's visual centre whatever its anchor point, so the maths
        // holds under AppKit's own layer geometry rather than assuming it.
        let anchor = layer.anchorPoint
        let centre = CGPoint(
            x: (0.5 - anchor.x) * host.bounds.width,
            y: (0.5 - anchor.y) * host.bounds.height
        )
        var from = CATransform3DIdentity
        from = CATransform3DTranslate(from, centre.x, centre.y, 0)
        from = CATransform3DScale(from, ThemedMenuMotion.appearScale, ThemedMenuMotion.appearScale, 1)
        from = CATransform3DTranslate(from, -centre.x, -centre.y, 0)

        let grow = CABasicAnimation(keyPath: "transform")
        grow.fromValue = NSValue(caTransform3D: from)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = Design.Motion.appear
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(group, forKey: ThemedMenuMotion.appearAnimationKey)
    }

    /// Ends the overlay's participation in the window now, and lets the pixels leave by
    /// `exit`. Synchronous whatever the exit: accessibility stops being a menu, events stop
    /// landing, and only the fade is deferred — captured strongly, so removal does not
    /// depend on the session outliving it.
    func tearDown(exit: ThemedMenuExit) {
        guard !isTearingDown else { return }
        isTearingDown = true
        cancelSubmenuTimers()
        for column in columns {
            column.surface.retireFromAccessibility()
        }

        let duration = Design.Motion.vanish
        // An invisible window has no display cycle to advance an AppKit animation. Waiting for
        // that completion retains a blocking animation worker indefinitely; a gallery that opens
        // many hidden menus can exhaust the process's dispatch-thread allowance and starve
        // unrelated asynchronous work. There are no pixels to preserve offscreen, so finish now.
        let canAnimate = duration > 0 && window?.isVisible == true
        let fadeOut: @MainActor @Sendable () -> Void = {
            Self.fadeOut(self, duration: duration) { [weak self] in
                self?.removeFromSuperview()
            }
        }

        switch exit {
        case .instant:
            removeFromSuperview()
        case .fade where !canAnimate, .confirm where !canAnimate:
            removeFromSuperview()
        case .fade:
            fadeOut()
        case .confirm(let index):
            let beat = Design.Motion.confirmBeat
            // The chosen row wherever it lives; the root index is the fallback for a menu
            // that answered without the overlay seeing which row did it.
            let row = chosenRow ?? columns.first?.surface.row(at: index)
            guard beat > 0, let row else {
                fadeOut()
                return
            }
            row.isKeyboardHighlighted = false
            DispatchQueue.main.asyncAfter(deadline: .now() + beat) {
                row.isKeyboardHighlighted = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + beat * 2, execute: fadeOut)
        }
    }

    /// Fades pixels without AppKit's blocking `NSAnimation` worker.
    ///
    /// `animator().alphaValue` is implemented by AppKit as a blocking animation dispatched to
    /// a worker thread. If the window closes after that worker starts, its display cycle stops
    /// and the worker never receives completion. A gallery closing many preview windows then
    /// parks one dispatch thread per menu until the process reaches its soft thread limit and
    /// unrelated async tests cannot run. Core Animation owns the pixels here, while the main
    /// queue owns the lifetime; the removal therefore happens after the stated beat whether the
    /// view is still onscreen or not.
    private static func fadeOut(
        _ view: NSView,
        duration: TimeInterval,
        completion: @escaping @MainActor @Sendable () -> Void
    ) {
        guard duration > 0, view.window?.isVisible == true, let layer = view.layer else {
            completion()
            return
        }

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = layer.presentation()?.opacity ?? layer.opacity
        fade.toValue = 0
        fade.duration = Design.Motion.vanish
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = 0
        CATransaction.commit()
        layer.add(fade, forKey: ThemedMenuMotion.vanishAnimationKey)

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            layer.removeAnimation(forKey: ThemedMenuMotion.vanishAnimationKey)
            completion()
        }
    }

    private func cancelSubmenuTimers() {
        submenuOpenTimer?.invalidate()
        submenuCloseTimer?.invalidate()
        travelTimer?.invalidate()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:
            escape()
        case 123:
            closeDeepestFromKeyboard()
        case 124:
            openSubmenuFromKeyboard()
        case 125:
            moveHighlight(by: 1)
        case 126:
            moveHighlight(by: -1)
        case 36:
            chooseHighlighted()
        case 51:
            if filterQuery.isEmpty {
                super.keyDown(with: event)
            } else {
                filterQuery.removeLast()
            }
        case 49:
            // Space chooses, as it always has — unless a filter is being typed, where it is
            // an ordinary character ("new work…").
            if filterQuery.isEmpty {
                chooseHighlighted()
            } else {
                filterQuery += " "
            }
        default:
            if let character = filterCharacter(from: event) {
                filterQuery += character
            } else if event.charactersIgnoringModifiers == "\u{1b}" {
                escape()
            } else if event.charactersIgnoringModifiers == "\r" {
                chooseHighlighted()
            } else {
                super.keyDown(with: event)
            }
        }
    }

    /// Escape backs out one layer at a time: first the filter, then the menu — clearing a
    /// half-typed query should not cost the menu too.
    private func escape() {
        if filterQuery.isEmpty {
            onDismiss?()
        } else {
            filterQuery = ""
        }
    }

    /// A key that belongs in the filter: one visible character, unchorded. Arrows and other
    /// function keys arrive as private-use scalars and stay navigation.
    private func filterCharacter(from event: NSEvent) -> String? {
        guard event.modifierFlags.isDisjoint(with: [.command, .control, .function]),
              let characters = event.charactersIgnoringModifiers,
              characters.count == 1,
              let scalar = characters.unicodeScalars.first,
              !CharacterSet.controlCharacters.contains(scalar),
              !(0xF700...0xF8FF).contains(Int(scalar.value))
        else { return nil }
        return characters
    }

    // MARK: - Press-Drag-Release Tracking

    /// Lands the highlight on the row under a window point — the press-drag browse, and the
    /// re-landing after a scroll freeze ends, both of which know a position rather than a row.
    /// Either caller *is* the pointer moving, so whatever freeze was standing is over.
    func pointerHighlight(atWindowPoint point: NSPoint) {
        guard !isTearingDown else { return }
        scrollFreezePoint = nil
        for (index, column) in columns.enumerated().reversed() {
            if let row = column.surface.row(underWindowPoint: point), row.item.isEnabled {
                pointerHighlighted(columnIndex: index, entryIndex: row.entryIndex)
                return
            }
        }
    }

    func dragTarget(atWindowPoint point: NSPoint) -> ThemedMenuDragTarget {
        guard !isTearingDown else { return .outside }
        for (index, column) in columns.enumerated().reversed() {
            if let row = column.surface.row(underWindowPoint: point), row.item.isEnabled {
                // Releasing on a parent row opens what it holds — the press stays a browse,
                // exactly as it does on the platform's own menus.
                if row.item.submenu != nil {
                    openSubmenu(columnIndex: index, entryIndex: row.entryIndex, highlightFirst: false)
                    return .surface
                }
                chosenRow = row
                return .row(row.entryIndex, row.item)
            }
            let inSurface = column.surface.bounds.contains(
                column.surface.convert(point, from: nil)
            )
            if inSurface { return .surface }
        }
        return .outside
    }

    override func performPrimaryAction() -> Bool {
        chooseHighlighted()
    }

    private func setHighlight(columnIndex: Int, entryIndex: Int?, scrollIntoView: Bool = true) {
        // Tracking areas keep firing while the closed menu fades — hit testing does not
        // silence them — and a highlight moving on a menu that has already answered reads
        // as the menu still being open.
        guard !isTearingDown, columns.indices.contains(columnIndex) else { return }
        columns[columnIndex].highlightedIndex = entryIndex
        columns[columnIndex].surface.highlight(entryIndex, scrollIntoView: scrollIntoView)
        if let row = columns[columnIndex].surface.row(at: entryIndex) {
            NSAccessibility.post(element: row, notification: .focusedUIElementChanged)
        }
    }

    private func moveHighlight(by delta: Int) {
        let indices = activeIndices
        guard !indices.isEmpty else { return }
        let columnIndex = columns.count - 1
        guard let highlighted = columns[columnIndex].highlightedIndex,
              let position = indices.firstIndex(of: highlighted)
        else {
            setHighlight(
                columnIndex: columnIndex,
                entryIndex: delta > 0 ? indices.first : indices.last
            )
            return
        }
        let next = min(max(position + delta, 0), indices.count - 1)
        setHighlight(columnIndex: columnIndex, entryIndex: indices[next])
    }

    @discardableResult
    private func chooseHighlighted() -> Bool {
        let columnIndex = columns.count - 1
        guard columnIndex >= 0,
              let highlighted = columns[columnIndex].highlightedIndex,
              let row = columns[columnIndex].surface.row(at: highlighted)
        else { return false }
        if row.item.isEnabled, row.item.submenu != nil {
            openSubmenu(columnIndex: columnIndex, entryIndex: highlighted, highlightFirst: true)
            return true
        }
        return row.performPrimaryAction()
    }

    // MARK: - Submenus

    /// A row was activated — release, click, Return through the row, or accessibility press.
    /// A parent row's activation is "open"; everything else is the menu's answer.
    private func rowChosen(columnIndex: Int, entryIndex: Int, item: ThemedMenuItem) {
        guard !isTearingDown else { return }
        if item.submenu != nil {
            openSubmenu(columnIndex: columnIndex, entryIndex: entryIndex, highlightFirst: true)
            return
        }
        if columns.indices.contains(columnIndex) {
            chosenRow = columns[columnIndex].surface.row(at: entryIndex)
        }
        onChoose?(entryIndex, item)
    }

    /// Opens `entryIndex`'s submenu beside its panel, closing anything deeper first.
    private func openSubmenu(columnIndex: Int, entryIndex: Int, highlightFirst: Bool) {
        guard !isTearingDown,
              columns.indices.contains(columnIndex),
              let row = columns[columnIndex].surface.row(at: entryIndex),
              row.item.isEnabled,
              let entries = row.item.submenu,
              entries.contains(where: \.isItem)
        else { return }

        if columnIndex + 1 < columns.count {
            if columns[columnIndex + 1].parentRow === row {
                if highlightFirst {
                    setHighlight(
                        columnIndex: columnIndex + 1,
                        entryIndex: columns[columnIndex + 1].surface.selectableIndices.first
                    )
                }
                return
            }
            closeColumns(from: columnIndex + 1, exit: .instant)
        }

        if !filterQuery.isEmpty { filterQuery = "" }
        submenuOpenTimer?.invalidate()

        let size = NSSize(
            width: ThemedMenuMetrics.width(for: entries, minimum: 0),
            height: ThemedMenuMetrics.height(for: entries)
        )
        let frame = ThemedMenuLayout.submenuFrame(
            parentPanel: columns[columnIndex].host.frame,
            rowFrame: row.convert(row.bounds, to: self),
            desiredSize: size,
            in: bounds,
            flipped: isFlipped,
            firstRowInset: ThemedMenuMetrics.verticalOuterInset,
            whenClipped: { ThemedMenuMetrics.clippedHeight(for: entries, atMost: $0) }
        )
        let index = addColumn(
            entries: entries,
            frame: frame,
            parentRow: row,
            selectedEntryIndex: nil
        )
        row.submenuDidOpen(columns[index].surface)
        Self.animateAppear(columns[index].host)
        if highlightFirst {
            setHighlight(
                columnIndex: index,
                entryIndex: columns[index].surface.selectableIndices.first
            )
        }
    }

    /// Closes column `index` and everything deeper. `exit` names only the pixels' leave —
    /// the model is out of `columns` synchronously either way.
    private func closeColumns(from index: Int, exit: ThemedMenuExit = .fade) {
        guard index >= 1, index < columns.count else { return }
        cancelSubmenuTimers()
        pendingTravelHighlight = nil
        travelApex = nil

        let closing = Array(columns[index...])
        columns.removeSubrange(index...)
        if !filterQuery.isEmpty { filterQuery = "" }

        for column in closing {
            column.parentRow?.submenuDidClose()
            column.surface.retireFromAccessibility()
            let host = column.host
            let duration = Design.Motion.vanish
            if case .instant = exit {
                host.removeFromSuperview()
            } else if duration <= 0 || window?.isVisible != true {
                host.removeFromSuperview()
            } else {
                Self.fadeOut(host, duration: duration) {
                    host.removeFromSuperview()
                }
            }
        }
    }

    /// Right arrow: the highlighted parent row opens, with its first row lit — keyboard
    /// travel always says where it landed.
    /// Right arrow: reach into the highlighted row.
    ///
    /// On a row that opens a submenu that means the submenu, which is what the key has always
    /// done here and what the platform's own menus do. On a row that opens nothing and carries a
    /// trailing accessory it means the accessory — the key was inert on such a row, and the
    /// alternative was leaving a hover-revealed control with no key at all. It cannot be Space or
    /// Return: both choose the row, which is precisely the commitment an accessory exists to
    /// avoid.
    private func openSubmenuFromKeyboard() {
        let columnIndex = columns.count - 1
        guard columnIndex >= 0,
              let highlighted = columns[columnIndex].highlightedIndex
        else { return }
        if let row = columns[columnIndex].surface.row(at: highlighted),
           row.item.submenu == nil,
           row.performAccessory() {
            return
        }
        openSubmenu(columnIndex: columnIndex, entryIndex: highlighted, highlightFirst: true)
    }

    /// Left arrow: one level back, the parent row keeping the highlight — the platform's
    /// submenu contract, and deliberately not what Escape does (Escape lets the whole menu go).
    private func closeDeepestFromKeyboard() {
        guard columns.count > 1 else { return }
        let parentRow = columns[columns.count - 1].parentRow
        closeColumns(from: columns.count - 1)
        if let parentRow {
            setHighlight(columnIndex: columns.count - 1, entryIndex: parentRow.entryIndex)
        }
    }

    // MARK: - Pointer Choreography

    /// A row lit under the pointer. Everything time-based about submenus funnels through
    /// here: opening after a rest, granting an open panel its grace, and holding a highlight
    /// back while the pointer is visibly on its way into the panel it already opened.
    private func pointerHighlighted(columnIndex: Int, entryIndex: Int) {
        guard !isTearingDown, columns.indices.contains(columnIndex) else { return }
        // A row lit by the list scrolling under a still pointer is not a landing. The freeze
        // ends only in `mouseMoved`, which re-answers the landing itself — so a suppressed
        // enter is never the last word on where the pointer is.
        guard scrollFreezePoint == nil else { return }
        // Every landing restates its own claim: whichever close was pending, the pointer has
        // just said something newer.
        submenuCloseTimer?.invalidate()

        let childRowIndex = columnIndex + 1 < columns.count
            ? columns[columnIndex + 1].parentRow?.entryIndex
            : nil

        if let childRowIndex, entryIndex != childRowIndex {
            if isPointerTravelling(toward: columnIndex + 1) {
                // A deliberate diagonal into the open panel: the rows it crosses on the way
                // do not steal it. The timer is the stall deadline — a pointer parked in the
                // corridor produces no further moves to re-answer on.
                pendingTravelHighlight = (columnIndex, entryIndex)
                travelApex = travelApex ?? lastPointerPoint
                travelDeadline = CACurrentMediaTime() + ThemedMenuMotion.safeTravelStall
                travelTimer?.invalidate()
                travelTimer = Timer.scheduledTimer(
                    withTimeInterval: ThemedMenuMotion.safeTravelStall,
                    repeats: false
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.resolveTravel() }
                }
                return
            }
            scheduleClose(from: columnIndex + 1)
        }

        applyPointerHighlight(columnIndex: columnIndex, entryIndex: entryIndex)
    }

    private func applyPointerHighlight(columnIndex: Int, entryIndex: Int) {
        pendingTravelHighlight = nil
        travelApex = nil
        // No scroll-into-view: a pointer highlight names a row already under the pointer, and
        // nudging a half-visible row fully in moves the list under a hand that did not ask —
        // during a wheel gesture it visibly fights the wheel.
        setHighlight(columnIndex: columnIndex, entryIndex: entryIndex, scrollIntoView: false)
        scheduleOpenIfParent(columnIndex: columnIndex, entryIndex: entryIndex)
    }

    /// Arms the hover-open for a parent row, unless its panel is already the open one.
    private func scheduleOpenIfParent(columnIndex: Int, entryIndex: Int) {
        submenuOpenTimer?.invalidate()
        guard columns.indices.contains(columnIndex),
              let row = columns[columnIndex].surface.row(at: entryIndex),
              row.item.isEnabled,
              row.item.submenu?.contains(where: \.isItem) == true
        else { return }
        if columnIndex + 1 < columns.count, columns[columnIndex + 1].parentRow === row {
            return
        }
        submenuOpenTimer = Timer.scheduledTimer(
            withTimeInterval: ThemedMenuMotion.submenuOpenDelay,
            repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isTearingDown,
                      self.columns.indices.contains(columnIndex),
                      self.columns[columnIndex].highlightedIndex == entryIndex
                else { return }
                self.openSubmenu(
                    columnIndex: columnIndex,
                    entryIndex: entryIndex,
                    highlightFirst: false
                )
            }
        }
    }

    /// Grants an open chain its grace before closing — the recovery window for an overshoot.
    private func scheduleClose(from index: Int) {
        submenuCloseTimer?.invalidate()
        guard index < columns.count else { return }
        submenuCloseTimer = Timer.scheduledTimer(
            withTimeInterval: ThemedMenuMotion.submenuCloseGrace,
            repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.closeIfStillAway(from: index) }
        }
    }

    /// The grace ran out — unless the pointer made it into the chain, or back onto the row
    /// that opened it, while the timer ran.
    private func closeIfStillAway(from index: Int) {
        guard !isTearingDown, index < columns.count else { return }
        if let point = lastPointerPoint {
            if columns[index...].contains(where: { $0.host.frame.contains(point) }) { return }
            if let parentRow = columns[index].parentRow,
               parentRow.bounds.contains(parentRow.convert(point, from: self)) { return }
        }
        closeColumns(from: index)
    }

    /// Re-answers a held-back highlight as the pointer keeps moving: arriving in the panel
    /// drops it, leaving the corridor (or stalling in it) lands it.
    private func resolveTravel() {
        guard !isTearingDown, let pending = pendingTravelHighlight else { return }
        guard pending.column + 1 < columns.count else {
            pendingTravelHighlight = nil
            travelApex = nil
            return
        }
        if let point = lastPointerPoint,
           columns[(pending.column + 1)...].contains(where: { $0.host.frame.contains(point) }) {
            // Arrived: the panel keeps its place and the crossed rows keep nothing.
            pendingTravelHighlight = nil
            travelApex = nil
            return
        }
        if isPointerTravelling(toward: pending.column + 1) { return }
        pendingTravelHighlight = nil
        travelApex = nil
        scheduleClose(from: pending.column + 1)
        applyPointerHighlight(columnIndex: pending.column, entryIndex: pending.entry)
    }

    /// Whether the pointer is inside the corridor from where it left the open row to the
    /// open panel's near edge — the platform menus' safe triangle.
    private func isPointerTravelling(toward childIndex: Int) -> Bool {
        guard columns.indices.contains(childIndex), let point = lastPointerPoint else {
            return false
        }
        let childFrame = columns[childIndex].host.frame
        // Panels overlap by design, so a row under the seam can fire hover while the pointer
        // is visually on the child panel: that is arrival, not a landing on the row.
        if childFrame.contains(point) { return true }
        if travelApex != nil, CACurrentMediaTime() >= travelDeadline { return false }
        let apex = travelApex ?? point
        return Self.point(point, inTriangleFrom: apex, toEdgeOf: childFrame)
    }

    /// Point-in-triangle from `apex` to the vertical edge of `frame` facing it.
    private static func point(
        _ point: NSPoint,
        inTriangleFrom apex: NSPoint,
        toEdgeOf frame: NSRect
    ) -> Bool {
        let edgeX = apex.x <= frame.midX ? frame.minX : frame.maxX
        let b = NSPoint(x: edgeX, y: frame.minY)
        let c = NSPoint(x: edgeX, y: frame.maxY)
        func sign(_ p1: NSPoint, _ p2: NSPoint, _ p3: NSPoint) -> CGFloat {
            (p1.x - p3.x) * (p2.y - p3.y) - (p2.x - p3.x) * (p1.y - p3.y)
        }
        let d1 = sign(point, apex, b)
        let d2 = sign(point, b, c)
        let d3 = sign(point, c, apex)
        let hasNegative = d1 < 0 || d2 < 0 || d3 < 0
        let hasPositive = d1 > 0 || d2 > 0 || d3 > 0
        return !(hasNegative && hasPositive)
    }
}

// MARK: - Surface and Scrolling

/// The dropdown's column geometry. Internal rather than file-private so the columns can be
/// pinned by a test: a preview hosted in a row and a title drawn in one have to start at the
/// same place, and that is an arithmetic claim rather than something a render shows.
@MainActor
public enum ThemedMenuMetrics {
    /// Menus have their own authored anatomy. A chooser and the menu it opens are related, but
    /// Platinum's paired-arrow field does not imply its menu frame or row rhythm, and three
    /// workstation families all use a down-arrow popup while drawing different menus.
    public static var appearance: AppTheme.Material.MenuAppearance {
        AppThemePalette.current.material.menuAppearance
    }

    public static var usesClassicGrammar: Bool {
        appearance.isHistorical
    }

    /// Between the panel's edge and its rows, so a highlighted row's capsule floats inside
    /// the panel instead of grazing its border.
    public static var outerInset: CGFloat {
        switch appearance {
        case .platinum: return 1
        case .automatic: return Design.Spacing.small
        default: return 2
        }
    }

    /// The same, at the panel's two **ends**, where its corner is.
    ///
    /// A menu is a rounded panel whose rows are a scroll view's, and neither clips the other: the
    /// panel's corner lives on a layer that must keep its halo, and the rows are drawn inside a
    /// frame that was inset by the same 6pt at the ends as at the sides. Under a broad corner
    /// those 6pt are *outside* the silhouette — Botanical's 40pt corner has not curved past them
    /// until 19pt down — so a highlighted first or last row drew its fill past the panel's own
    /// border. Reported from a render as the inner fill protruding through the outer edge.
    ///
    /// So the rows start where the corner has finished. Every theme whose corner is at or under
    /// the margin keeps `outerInset` exactly, which is all of them but Botanical (19) and
    /// Claymorphism (14).
    public static var verticalOuterInset: CGFloat {
        let margin = outerInset
        let reach = Design.Radius.edgeReach(of: Design.Radius.panel, clearing: margin)
        return max(margin, reach.rounded(.up))
    }
    public static var rowHeight: CGFloat {
        switch appearance {
        case .platinum: return 19
        case .windows98: return 21
        case .automatic: return 28
        default: return 18
        }
    }
    /// Taller than the ink it holds, and deliberately so: a title and its subtitle are drawn as
    /// one centred block, so everything above this beyond that block becomes the gap to the row
    /// stacked against it. At 42 the two gaps came out ~18pt within a pair against ~24pt between
    /// them and the pairs did not read as pairs; 46 buys a little over 2:1, which is the point at
    /// which proximity does the grouping on its own — no rules, no alternating fill, both of
    /// which would have fought the hover pill this row draws at full bleed.
    /// Raised from 31 for the classic grammars once `subtitleGap` opened the pair: at 31 the two
    /// lines already filled all but 2.5pt of the slot, so the gap *between* two rows was narrower
    /// than the gap inside one and the column read as evenly spaced single lines rather than as
    /// pairs — the same fault 46 was chosen to avoid on the modern side.
    public static var subtitleRowHeight: CGFloat { usesClassicGrammar ? 36 : 46 }

    /// Between a title and the subtitle under it.
    ///
    /// It used to be nothing at all, on the argument that a line box already carries the font's
    /// own leading. That holds for the modern face and fails for the classic ones, whose line
    /// boxes are drawn tight around the glyphs: the two lines touched, and a name with its
    /// reading immediately beneath read as one wrapped sentence rather than as a heading and its
    /// detail. Small enough that the pair still groups by proximity against the row's own margins.
    public static var subtitleGap: CGFloat { Design.Spacing.hairline }
    /// How far a row's fill sits inside its own slot, so two *adjacent* filled rows are parted
    /// by a hairline rather than meeting.
    ///
    /// Rows are stacked edge to edge, and a fill drawn at the row's full height therefore shares
    /// an edge with the row above it. One filled row never showed this; two adjacent ones did —
    /// the two capsules fused into a single pinched blob, with their corner radii reading as a
    /// dent in one shape instead of the gap between two. A menu still gets there whenever a
    /// parent row holds the menu path while the pointer is on the row directly under it, during
    /// the grace its submenu is given to close.
    ///
    /// Half a hairline each side, so the gap the pair opens is the whole one. Same arithmetic,
    /// and the same 1pt, as the sidebar's `hoverHighlightInsetY`.
    public static var fillInset: CGFloat {
        usesClassicGrammar ? 0 : Design.Spacing.hairline / 2
    }
    /// A separator's slot. Sized so the gap it opens between two rows' text reads as the
    /// ordinary inter-row rhythm plus the rule — at the old 9pt the rule crowded whichever
    /// row's fill it sat against and the spacing read as unequal.
    public static var separatorHeight: CGFloat {
        appearance == .platinum ? 2 : (usesClassicGrammar ? 9 : 13)
    }
    /// The strip across the top echoing what has been typed while the menu is open.
    public static var filterHeaderHeight: CGFloat { usesClassicGrammar ? 18 : 22 }
    /// How far a filtered-out row's ink drops. Dimmed rather than hidden, so the menu keeps
    /// its shape while the user types and nothing moves under the pointer.
    public static let filteredOutDimming: CGFloat = 0.4
    /// A row that cannot be chosen at all.
    public static let disabledDimming: CGFloat = 0.45
    /// The wash a *disabled* row shows under the pointer — feedback that the hover was
    /// seen, well short of the fill that says "choosable".
    public static let disabledHoverWash: CGFloat = 0.4
    /// A row's own leading and trailing padding — also where the checkmark sits, which was
    /// previously drawn 4pt from the row's edge and read as pinned to the panel's side.
    public static var contentInset: CGFloat {
        appearance == .windows98 ? 5 : (usesClassicGrammar ? 4 : Design.Spacing.medium)
    }
    public static var checkSize: CGFloat { usesClassicGrammar ? 8 : 10 }
    /// The checkmark column: glyph plus the gap to whatever follows it.
    public static var leadingSlot: CGFloat {
        checkSize + (usesClassicGrammar ? 3 : Design.Spacing.small)
    }
    /// A row's leading mark — the **slot**, which caps the artwork rather than sizing it.
    ///
    /// It was 14, and that was a cap below what a symbol beside a label already renders at: SF
    /// configured at `Design.Symbol.control` comes out around 14–15pt, so most glyphs were being
    /// shrunk a little past their configuration, which thins the stroke off the weight the
    /// optical size chose and off the pixel grid with it. One icon in a menu of words absorbs
    /// that; a whole column of them does not, and the column is what these menus now have.
    /// `Design.Size.tabIconSlot` is the same slot every other mark-that-names-something in the
    /// chrome sits in.
    public static var imageSize: CGFloat { Design.Size.tabIconSlot }
    public static var imageSlot: CGFloat {
        imageSize + (usesClassicGrammar ? 3 : Design.Spacing.small)
    }
    /// A live preview's column. The orb is the widest thing that goes in it and states its own
    /// 20pt footprint, so the slot is that plus the gap to whatever follows — the same shape as
    /// the image column one size up, rather than a second guess at it.
    public static var previewSize: CGFloat { usesClassicGrammar ? 16 : 20 }
    public static var previewSlot: CGFloat {
        previewSize + (usesClassicGrammar ? 3 : Design.Spacing.tight)
    }

    /// The chevron marking a row that opens a submenu, and the column it sits in — trailing,
    /// where the platform's own submenu arrow lives.
    public static var submenuChevronSize: CGFloat {
        appearance == .windows98 ? 6 : (usesClassicGrammar ? 7 : 8)
    }
    public static var submenuTrailingInset: CGFloat {
        appearance == .windows98 ? 4 : contentInset
    }
    public static var submenuChevronSlot: CGFloat {
        submenuChevronSize + (usesClassicGrammar ? 4 : Design.Spacing.small)
    }

    /// The hover-revealed action's glyph, and the column it sits in — the outermost trailing one,
    /// outside the submenu chevron, because it is the only thing on a row that is *pressed* and a
    /// press wants the edge rather than a slot between two others.
    ///
    /// Smaller than a row's leading mark (`imageSize`): that column names what a row is and is
    /// read down the menu as a column, while this one is a control on a single row and is drawn
    /// only where the pointer already is.
    public static var accessorySize: CGFloat { usesClassicGrammar ? 11 : 13 }
    public static var accessorySlot: CGFloat {
        accessorySize + (usesClassicGrammar ? 4 : Design.Spacing.small)
    }
    /// How far past its glyph the press still lands. A 13pt symbol is a 13pt target, which is
    /// under half of what a pointer is aimed with; the padding is invisible and the difference
    /// between a control and a dare. It never reaches past the glyph's own column, so the row
    /// beside it keeps every pixel a press on the *row* can land on.
    public static var accessoryHitPadding: CGFloat { Design.Spacing.tight }
    /// What a press takes off the accessory's ink — the same answer `ThemedButton` gives a press,
    /// an alpha step rather than a second surface. A plate was drawn here first and was invisible:
    /// the row under it is *already* filled with `controlHover`, because the accessory only ever
    /// appears on the row the pointer or the highlight is on, so the press painted the hover fill
    /// over itself. Ink is the only channel this glyph has left, and it is enough.
    public static let accessoryPressedDimming: CGFloat = 0.55

    /// Reserved on the image column's terms — only when some row in this menu carries one — and
    /// then on **every** row of it. A slot that appeared with the pointer would reflow the title
    /// underneath it, so the width is spent whether or not the row draws anything in it.
    public static func hasAccessoryColumn(_ entries: [ThemedMenuEntry]) -> Bool {
        entries.contains { entry in
            guard case .item(let item) = entry else { return false }
            return item.accessory != nil
        }
    }

    public static var titleFont: NSFont {
        if appearance == .platinum {
            return Design.Typography.control(weight: .bold)
        }
        let font = usesClassicGrammar
            ? Design.Typography.controlRegular()
            : Design.Typography.control()
        guard appearance == .windows98 else { return font }

        // The shell's nominal eight-point menu face was rasterised at the 96-dpi logical
        // scale, while AppKit's point maps directly to a backing pixel in this 1x evidence
        // fixture. The 10/9 correction turns the theme's authored 9.6pt control role into the
        // measured 10.67px GDI raster without bypassing either the user's text-size preference
        // or the resolved MS Sans Serif/W95FA fallback family.
        return NSFont(
            descriptor: font.fontDescriptor,
            size: font.pointSize * 10 / 9
        ) ?? font
    }

    /// Classic GDI placed the menu face one device pixel below AppKit's centred line box.
    /// Keep this on the anatomy axis: a custom theme choosing Win98 menus inherits the same
    /// baseline, while a different menu family under the Win98 palette does not.
    public static var titleBaselineOffset: CGFloat {
        appearance == .windows98 ? -1 : 0
    }

    /// Win32 seats a 16px menu bitmap one device pixel above AppKit's geometric centre.
    public static var imageBaselineOffset: CGFloat {
        appearance == .windows98 ? 1 : 0
    }

    public static var panelFill: NSColor {
        usesClassicGrammar ? Design.Surface.controlResting : Design.Surface.elevated
    }

    public static var panelHasGlow: Bool { appearance == .automatic }

    /// The image column is reserved only when some item actually carries an image. Reserving
    /// it always left an 18pt hole between checkmark and title in every icon-less menu.
    public static func hasImageColumn(_ entries: [ThemedMenuEntry]) -> Bool {
        entries.contains { entry in
            guard case .item(let item) = entry else { return false }
            return item.image != nil
        }
    }

    /// Reserved on the image column's terms: only when some row actually opens a submenu, so a
    /// menu of plain actions keeps its trailing edge tight against the longest title.
    public static func hasSubmenuColumn(_ entries: [ThemedMenuEntry]) -> Bool {
        entries.contains { entry in
            guard case .item(let item) = entry else { return false }
            return item.submenu != nil
        }
    }

    /// Reserved on the same terms as the image column, and only for a preview that sits *beside*
    /// a title — one placed in the title's own slot occupies a column that already exists.
    public static func hasPreviewColumn(_ entries: [ThemedMenuEntry]) -> Bool {
        entries.contains { entry in
            guard case .item(let item) = entry else { return false }
            return item.preview?.placement == .leading
        }
    }

    // MARK: - Metric Columns

    /// The font every metric column is drawn and measured in. Tabular by role: a column of
    /// proportional digits is only accidentally a column, and `27%` over `81%` misaligning by
    /// the width of a `2` is the whole reason the numbers left the subtitle.
    public static var metricFont: NSFont {
        usesClassicGrammar ? titleFont : Design.Typography.numericDetail()
    }

    /// The bar between a column's name and its value. Wide enough that two readings differing
    /// by ten points differ visibly — the 14pt meter under `AccountMarkImage` could only ever
    /// carry a hue, which the value's own tint already said.
    public static var metricBarWidth: CGFloat { usesClassicGrammar ? 22 : 28 }

    /// The air around the rule between the columns and the trailing detail. Wider than the gap
    /// between two columns, because what it parts is a change of *kind* rather than the next
    /// window: readings and the countdown are not the same sort of fact, and at an equal gap
    /// `99%` and `7d · 5d 3h` ran together as one line of numbers.
    public static var metricDividerGap: CGFloat { Design.Spacing.inset }
    public static var metricDividerWidth: CGFloat { Design.Radius.border }
    /// Thick enough to hold a status hue at this size without becoming a second row of content.
    public static var metricBarHeight: CGFloat { Design.Spacing.tight - 1 }
    /// Inside a column: name, bar, value.
    public static var metricInnerGap: CGFloat { Design.Spacing.tight }
    /// Between one column and the next, and between the last one and the trailing detail. Wider
    /// than the inner gap, so a column reads as one group rather than as three loose runs.
    public static var metricColumnGap: CGFloat { Design.Spacing.medium }
    /// Below this a fill is shorter than its own cap and draws as a dot at the track's head.
    public static let metricMinimumFraction = 0.02
    /// How much of its ink an empty track keeps — of `tertiary` normally, and of a classic
    /// selection band's own label ink over a band, where an unrelated grey cannot be measured
    /// against the band's solid fill.
    public static let metricTrackOpacity: CGFloat = 0.45

    /// A 440-point menu cannot carry a provider-sized union of metric columns. Three preserves
    /// the common account pair plus one additional window while leaving a readable title slot.
    /// Callers keep omitted values in the row's bounded subtitle/tooltip projection.
    public static let maximumMetricColumns = 3

    /// The columns this menu reserves, in first-seen order.
    ///
    /// A union across every row rather than per row: a plan metering one window and a plan
    /// metering two must put their shared `7d` reading in the same place, which is exactly the
    /// comparison that a per-row layout destroys. The empty cell that leaves on the shorter
    /// plan's row is not a hole — it says that plan has no window there.
    public static func metricColumns(_ entries: [ThemedMenuEntry]) -> [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        for entry in entries {
            guard case .item(let item) = entry else { continue }
            for metric in item.metrics where seen.insert(metric.label).inserted {
                ordered.append(metric.label)
                if ordered.count == maximumMetricColumns { return ordered }
            }
        }
        return ordered
    }

    /// One width for every column, measured from the widest name and the widest value anywhere
    /// in the menu. Equal columns rather than each sized to its own content, because unequal
    /// ones put the second column's bar at a different offset on rows whose first column is
    /// absent — and a bar that moves sideways between rows cannot be compared by length.
    public static func metricColumnWidth(_ entries: [ThemedMenuEntry]) -> CGFloat {
        let admitted = Set(metricColumns(entries))
        let all = entries.flatMap { entry -> [ThemedMenuMetric] in
            guard case .item(let item) = entry else { return [] }
            return item.metrics.filter { admitted.contains($0.label) }
        }
        guard !all.isEmpty else { return 0 }

        let font = metricFont
        let label = all.map { ceil($0.label.size(withAttributes: [.font: font]).width) }.max() ?? 0
        let value = all.map { ceil($0.value.size(withAttributes: [.font: font]).width) }.max() ?? 0
        return label + metricInnerGap + metricBarWidth + metricInnerGap + value
    }

    /// The trailing detail's own column, measured from the longest one present.
    public static func trailingDetailWidth(_ entries: [ThemedMenuEntry]) -> CGFloat {
        entries.compactMap { entry -> CGFloat? in
            guard case .item(let item) = entry,
                  let detail = item.trailingDetail,
                  !detail.isEmpty else { return nil }
            return ceil(detail.size(withAttributes: [.font: metricFont]).width)
        }.max() ?? 0
    }

    /// Everything the columns take out of a row's width, including the gaps between them.
    ///
    /// Reserved off the *title's* width rather than added to the panel's, once the panel is at
    /// its cap. That inversion is the point: today's rows overflow, and the segment that loses
    /// its characters is the countdown — `7d resets in 5d 1…`, a sentence claiming to be
    /// complete. A name is the one thing on this row a reader can still recognise from its
    /// first half, so the name is what gives way and the numbers never do.
    public static func metricReservation(_ entries: [ThemedMenuEntry]) -> CGFloat {
        let columns = metricColumns(entries)
        let columnWidth = metricColumnWidth(entries)
        let detail = trailingDetailWidth(entries)
        var total: CGFloat = 0
        if !columns.isEmpty {
            total += CGFloat(columns.count) * columnWidth
                + CGFloat(columns.count - 1) * metricColumnGap
        }
        if detail > 0 {
            total += (total > 0 ? metricDividerGap * 2 + metricDividerWidth : 0) + detail
        }
        return total > 0 ? total + metricColumnGap : 0
    }

    /// Where a row's **first line** sits inside a slot of `height`, measured from the slot's
    /// bottom edge.
    ///
    /// Everything on that line is placed against it — the checkmark, the mark, the title and its
    /// qualifier, the metric columns, the trailing detail, the submenu chevron. Each of those was
    /// centred on the row instead, which is right for a single-line row and wrong for every row
    /// beside one: a title with a subtitle is placed as a centred *block*, so its line sits above
    /// the row's middle while the mark next to it sank to between the two lines, and a
    /// neighbouring row with no subtitle put its title where this row's ink is not.
    ///
    /// `reservesSubtitleLine` is the *run's* answer, not the row's, which is what keeps a row
    /// without a subtitle on its neighbours' line rather than in the middle of its own slot.
    public static func firstLineCenter(inRowOf height: CGFloat, reservesSubtitleLine: Bool) -> CGFloat {
        guard reservesSubtitleLine else { return height / 2 }
        let subtitleHeight = Design.Typography.lineHeight(of: Design.Typography.detail())
        return height / 2 + (subtitleGap + subtitleHeight) / 2
    }

    /// A section head is a *label*, not a quiet row: `caption` is the app's semibold 11pt
    /// heading role, which is what keeps it from reading as a disabled choice in a menu whose
    /// rows are 13pt.
    public static var headerFont: NSFont {
        usesClassicGrammar ? titleFont : Design.Typography.caption()
    }

    /// A section head's slot: its line, plus the air that makes it belong to what follows it
    /// rather than sitting between two groups equally.
    public static var headerHeight: CGFloat { usesClassicGrammar ? 20 : 30 }
    /// How much of that slot is above the line. More above than below, so the header reads as
    /// attached to the rows under it — the same proximity argument `subtitleRowHeight` makes
    /// for a title and its subtitle.
    public static var headerTopInset: CGFloat { usesClassicGrammar ? 8 : 14 }

    public static var shortcutGap: CGFloat { usesClassicGrammar ? 8 : Design.Spacing.large }

    public static let amigaCommandCapWidth: CGFloat = 13
    public static let amigaCommandCapGap: CGFloat = 2

    /// The exact visible spelling for a chord under this menu grammar.
    ///
    /// Windows and Workbench keep their authored command-key forms for the ordinary ⌘ chord;
    /// every other chord uses the platform glyph spelling so additional modifiers are never
    /// hidden or guessed from one bare key.
    public static func shortcutText(_ shortcut: KeyboardShortcut) -> String {
        if appearance == .windows98, shortcut.modifiers == .command {
            return "Ctrl+" + KeyboardShortcut.keyDisplay(shortcut.key)
        }
        return shortcut.displayString
    }

    public static func usesAmigaCommandCap(_ shortcut: KeyboardShortcut) -> Bool {
        appearance == .amiga && shortcut.modifiers == .command
    }

    /// One shared trailing column, measured from the widest complete chord. Workbench draws its
    /// ordinary command modifier as artwork rather than a font character, so the fixed key cap
    /// participates in the same measurement as the following Topaz key.
    public static func shortcutColumnWidth(_ entries: [ThemedMenuEntry]) -> CGFloat {
        entries.compactMap { entry -> CGFloat? in
            guard case .item(let item) = entry,
                  let shortcut = item.resolvedShortcut else { return nil }
            if usesAmigaCommandCap(shortcut) {
                let key = KeyboardShortcut.keyDisplay(shortcut.key)
                let keyWidth = ceil(key.size(withAttributes: [.font: titleFont]).width)
                return amigaCommandCapWidth + amigaCommandCapGap + keyWidth
            }
            return ceil(shortcutText(shortcut).size(withAttributes: [.font: titleFont]).width)
        }.max() ?? 0
    }

    /// How a panel's rows carry their marks, which is the one thing that decides where every
    /// title in it begins.
    ///
    /// The old answer was "always leave room for a checkmark", and it cost twice. An
    /// icon-less menu of plain actions — which is most of them — began every title 16pt inside
    /// the panel behind a gutter nothing was ever drawn in, which is the difference between a
    /// column of names and a column of names that looks like it lost its icons. And it made
    /// icons unaffordable: added behind a gutter that was always reserved, a glyph and its
    /// title started 48pt in and the panel grew to hold a column of air.
    ///
    /// So a mark column is reserved only where something is going in it, and a check and an
    /// icon **share** that column — which is what Win32 has always done, and what the row
    /// drawing already assumed by putting the check at `contentInset`. Only a menu where one
    /// row carries *both* needs two, and one exists: Open in marks the preferred app in a list
    /// where every row wears that app's own icon.
    public enum CheckColumn {
        /// No row in this panel is marked.
        case none
        /// Marks and icons share one leading column, because no row has both.
        case shared
        /// A column of its own, before the icons — some row carries a mark *and* an icon.
        case separate
    }

    /// What this panel's marks need, before the appearance has its say.
    ///
    /// A row is marked by its own `isSelected` or by the index the presenter opened on; the rows
    /// are built to treat those identically, so the measurement has to as well — a menu whose
    /// only mark came from the presenter measured itself without one and drew the check into
    /// the first title.
    public static func checkColumn(
        _ entries: [ThemedMenuEntry],
        selectedEntryIndex: Int? = nil
    ) -> CheckColumn {
        var marked = false
        for (index, entry) in entries.enumerated() {
            guard let item = entry.item else { continue }
            guard item.isSelected || index == selectedEntryIndex else { continue }
            if item.image != nil { return .separate }
            marked = true
        }
        return marked ? .shared : .none
    }

    /// The same answer under the anatomy the current theme authors.
    ///
    /// The historical families do not negotiate this. Platinum and Workbench draw independent
    /// mark and icon columns whether or not either is occupied — an icon-less System 7 Help
    /// menu still starts its titles after the mark column — and Win32 draws exactly one, which
    /// a row fills with its check *or* its bitmap. Both are part of the anatomy those
    /// reconstructions are measured against, so only the modern menu asks the entries.
    public static func resolved(_ column: CheckColumn) -> CheckColumn {
        switch appearance {
        case .platinum, .amiga: return .separate
        case .windows98: return .shared
        default: return column
        }
    }

    /// Where a row's leading mark begins — its icon, or its check where the two share a column.
    public static func markInset(checkColumn: CheckColumn) -> CGFloat {
        contentInset + (resolved(checkColumn) == .separate ? leadingSlot : 0)
    }

    /// The leading mark column's width: the icon's slot where the panel has icons, else the
    /// mark's own, else nothing at all.
    public static func markWidth(checkColumn: CheckColumn, hasImageColumn: Bool) -> CGFloat {
        if hasImageColumn { return imageSlot }
        return resolved(checkColumn) == .shared ? leadingSlot : 0
    }

    /// Where a row's content begins, per column, so a *drawn* title and a *hosted* preview land
    /// in the same place. A preview replaces the text rather than joining it, and a column of
    /// names that shifted sideways when one of them animated would read as a layout bug in the
    /// menu rather than as the transition it is demonstrating.
    public static func previewInset(checkColumn: CheckColumn, hasImageColumn: Bool) -> CGFloat {
        markInset(checkColumn: checkColumn)
            + markWidth(checkColumn: checkColumn, hasImageColumn: hasImageColumn)
    }

    public static func titleInset(
        checkColumn: CheckColumn,
        hasImageColumn: Bool,
        hasPreviewColumn: Bool
    ) -> CGFloat {
        let previewColumn = hasPreviewColumn ? previewSlot : 0
        if appearance == .windows98 {
            // One column, and the preview shares it rather than following it — the native
            // cascade has a single leading slot whatever goes in it.
            return contentInset + max(
                markWidth(checkColumn: checkColumn, hasImageColumn: hasImageColumn),
                previewColumn
            )
        }
        return previewInset(checkColumn: checkColumn, hasImageColumn: hasImageColumn)
            + previewColumn
    }

    /// Every entry's height, in one pass over the whole menu.
    ///
    /// **A row's height is not its own business.** Asked entry by entry, a row with a second
    /// line is 46 and one without is 28 — and a group of logins where three carry a scoped
    /// window and two do not then has two rhythms stacked directly on top of each other, which
    /// reads as a spacing defect rather than as rows that happen to differ. It is the same
    /// argument `subtitleRowHeight` already makes one level down: proximity does the grouping,
    /// and proximity cannot do it if the gaps are not equal.
    ///
    /// So the unit is a **run** — consecutive rows, delimited by separators and section heads —
    /// and every row in a run takes the tallest kind in that run. The delimiters are what keep
    /// this from flattening the whole app's menus into one tall rhythm: the project menu's two
    /// actions sit after a separator, so they stay short while the projects above them keep the
    /// height their paths need. A change of height across a rule or a heading is explained by
    /// the rule or the heading; a change of height between two adjacent rows is not.
    public static func heights(for entries: [ThemedMenuEntry]) -> [CGFloat] {
        var heights = [CGFloat](repeating: 0, count: entries.count)
        var run: [Int] = []

        func closeRun() {
            guard !run.isEmpty else { return }
            let tall = run.contains { index in
                entries[index].item?.subtitle?.isEmpty == false
            }
            for index in run { heights[index] = tall ? subtitleRowHeight : rowHeight }
            run.removeAll()
        }

        for (index, entry) in entries.enumerated() {
            switch entry {
            case .separator:
                closeRun()
                heights[index] = separatorHeight
            case .header:
                closeRun()
                heights[index] = headerHeight
            case .item:
                run.append(index)
            }
        }
        closeRun()
        return heights
    }

    public static func height(for entries: [ThemedMenuEntry]) -> CGFloat {
        heights(for: entries).reduce(verticalOuterInset * 2, +)
    }

    /// The height to settle on when a panel cannot show every row: the tallest one within
    /// `limit` that cuts a row across the middle.
    ///
    /// A clamped menu is free to land on a row boundary, and one that does looks like the whole
    /// menu. The session row's menu grew past `ThemedMenuLayout.maximumHeight` and ended on a
    /// clean edge, so Copy Session ID and Delete Session were simply not there as far as the
    /// screen was concerned — the scroller only appears while the pointer is inside the panel,
    /// which is too late to tell someone the list continues. Half a row is the signal that
    /// reads before anything is touched, and it costs nothing but the half row.
    ///
    /// Only items are cut. A separator sliced down its middle reads as a stray rule against the
    /// panel's edge rather than as a row with more below it, so one is carried whole into the
    /// hidden part and the item above it does the peeking.
    public static func clippedHeight(for entries: [ThemedMenuEntry], atMost limit: CGFloat) -> CGFloat {
        let budget = limit - verticalOuterInset * 2
        var consumed: CGFloat = 0
        var peeked: CGFloat?

        for (entry, height) in zip(entries, heights(for: entries)) {
            if case .item = entry {
                let candidate = consumed + height / 2
                guard candidate <= budget else { break }
                peeked = candidate
            }
            consumed += height
        }

        // Nothing fits even half a row — a panel shortened to that would say less than the
        // clamped one does. Keep the limit and let the scroller carry it.
        guard let peeked else { return limit }
        return peeked + verticalOuterInset * 2
    }

    /// `selectedEntryIndex` participates because it is one of the two ways a row is marked, and
    /// the panel's width has to reserve the same columns the rows will draw in. Measured without
    /// it, a menu whose only mark comes from the presenter drew its check into the title.
    public static func width(
        for entries: [ThemedMenuEntry],
        minimum: CGFloat,
        selectedEntryIndex: Int? = nil
    ) -> CGFloat {
        let text = entries.compactMap { entry -> CGFloat? in
            guard case .item(let item) = entry else { return nil }
            let title = ceil(titleLine(of: item).size(
                withAttributes: [.font: titleFont]
            ).width)
            let subtitle = ceil((item.subtitle ?? "").size(
                withAttributes: [.font: Design.Typography.detail()]
            ).width)
            return max(title, subtitle)
        }.max() ?? 0

        let imageColumn = hasImageColumn(entries) ? imageSlot : 0
        let previewColumn = hasPreviewColumn(entries) ? previewSlot : 0
        let chevronColumn = hasSubmenuColumn(entries) ? submenuChevronSlot : 0
        let accessoryColumn = hasAccessoryColumn(entries) ? accessorySlot : 0
        let shortcutColumn = shortcutColumnWidth(entries)
        let marks = checkColumn(entries, selectedEntryIndex: selectedEntryIndex)
        let markColumn = markWidth(checkColumn: marks, hasImageColumn: imageColumn > 0)
        let ownCheckColumn = resolved(marks) == .separate ? leadingSlot : 0
        let leadingColumns = appearance == .windows98
            ? max(markColumn, previewColumn)
            : ownCheckColumn + markColumn + previewColumn
        let content = outerInset * 2 + contentInset * 2
            + leadingColumns + text + chevronColumn + accessoryColumn
            + metricReservation(entries)
            + (shortcutColumn > 0 ? shortcutGap + shortcutColumn : 0)
        return min(max(minimum, content), ThemedMenuLayout.maximumWidth)
    }

    /// The title as it is drawn: the name, and the qualifier that shares its line.
    public static func titleLine(of item: ThemedMenuItem) -> String {
        guard let detail = item.titleDetail, !detail.isEmpty else { return item.title }
        return item.title + titleDetailGap + detail
    }

    /// Between a title and the qualifier after it. Wider than a word space, so the pair reads as
    /// a name and its footnote rather than as a two-word name.
    public static let titleDetailGap = "   "
}

/// How the menu moves. File-local because no other surface animates this way yet; a second
/// one promotes these to `Design`.
@MainActor
public enum ThemedMenuMotion {
    public static let appearScale: CGFloat = 0.97
    public static let appearAnimationKey = "threading.menu.appear"
    public static let vanishAnimationKey = "threading.menu.vanish"
    /// A classic menu is separated by its raised frame. A diffuse shadow is a modern floating-
    /// card cue and makes the two-pixel submenu overlap look like an accidental gap.
    public static var shadowOpacity: Float { ThemedMenuMetrics.usesClassicGrammar ? 0 : 0.28 }
    public static var shadowRadius: CGFloat { ThemedMenuMetrics.usesClassicGrammar ? 0 : 16 }

    /// How long the pointer rests on a parent row before its submenu opens. Short enough to
    /// feel attached to the hover, long enough that sweeping down a menu does not fan panels
    /// out of every parent row on the way past.
    public static let submenuOpenDelay: TimeInterval = 0.16
    /// How long an open submenu survives the pointer leaving its row for a sibling. This is
    /// the recovery window for an overshoot; the safe-travel corridor below covers the
    /// deliberate diagonal.
    public static let submenuCloseGrace: TimeInterval = 0.28
    /// How long a pointer may sit still inside the safe-travel corridor before the row it is
    /// actually on wins. Without a deadline, parking the pointer between panels would pin the
    /// menu to a highlight it has visibly left.
    public static let safeTravelStall: TimeInterval = 0.35
    /// How far the pointer must actually travel, after a panel has scrolled under it, before
    /// hover may claim the highlight again. Scrolling hands `mouseEntered` to whichever row
    /// slides under a stationary pointer; the tolerance is hysteresis for a physical mouse
    /// nudged while its wheel turns, not an allowance for deliberate movement.
    public static let scrollHoverTolerance: CGFloat = 4
    /// How far the held press must have travelled from where it opened the menu before its
    /// release is read as a choice rather than as a click.
    ///
    /// A secondary-click menu opens *at* the pointer, so the row nearest the press point sits
    /// under it from the first frame: without this, the ordinary right-click — press, release
    /// without moving — would choose whatever the panel happened to place there. The platform's
    /// sticky menu is the same rule, and the same number does for a hand that shifts a point or
    /// two between the press and the release.
    public static let stickyPressDistance: CGFloat = 4
}

private final class ThemedMenuSurfaceView: NSView, ThemedComponent {

    var onChoose: ((Int, ThemedMenuItem) -> Void)?
    var onHighlight: ((Int) -> Void)?
    /// The panel scrolled under its rows — what tells an open submenu its anchor moved.
    var onScrolled: (() -> Void)?
    /// A press landed on this panel, on a row or on the ground between them.
    var onPressBegan: ((NSEvent) -> Void)?

    let selectableIndices: [Int]

    private let scrollView = ThemedScrollView()
    private let document: ThemedMenuDocumentView
    private let rows: [Int: ThemedMenuRowView]
    private var isRetiredFromAccessibility = false
    /// Echoes what has been typed, in the strip the filter opens across the panel's top —
    /// without it, typing visibly does nothing until a row happens to dim.
    private let filterLabel = NSTextField(labelWithString: "")

    init(
        frame: NSRect,
        entries: [ThemedMenuEntry],
        selectedEntryIndex: Int?
    ) {
        var madeRows: [Int: ThemedMenuRowView] = [:]
        var views: [NSView] = []
        var selectable: [Int] = []
        let checkColumn = ThemedMenuMetrics.checkColumn(
            entries,
            selectedEntryIndex: selectedEntryIndex
        )
        let hasImageColumn = ThemedMenuMetrics.hasImageColumn(entries)
        let hasPreviewColumn = ThemedMenuMetrics.hasPreviewColumn(entries)
        let hasSubmenuColumn = ThemedMenuMetrics.hasSubmenuColumn(entries)
        let hasAccessoryColumn = ThemedMenuMetrics.hasAccessoryColumn(entries)
        let shortcutColumnWidth = ThemedMenuMetrics.shortcutColumnWidth(entries)
        let metricColumns = ThemedMenuMetrics.metricColumns(entries)
        let metricColumnWidth = ThemedMenuMetrics.metricColumnWidth(entries)
        let trailingDetailWidth = ThemedMenuMetrics.trailingDetailWidth(entries)
        let entryHeights = ThemedMenuMetrics.heights(for: entries)

        for (index, entry) in entries.enumerated() {
            switch entry {
            case .separator:
                views.append(ThemedMenuSeparatorView())
            case .header(let title):
                views.append(ThemedMenuHeaderView(title: title))
            case .item(let item):
                let row = ThemedMenuRowView(
                    entryIndex: index,
                    item: item,
                    isSelected: item.isSelected || index == selectedEntryIndex,
                    checkColumn: checkColumn,
                    hasImageColumn: hasImageColumn,
                    hasPreviewColumn: hasPreviewColumn,
                    hasSubmenuColumn: hasSubmenuColumn,
                    hasAccessoryColumn: hasAccessoryColumn,
                    shortcutColumnWidth: shortcutColumnWidth,
                    preferredHeight: entryHeights[index],
                    metricColumns: metricColumns,
                    metricColumnWidth: metricColumnWidth,
                    trailingDetailWidth: trailingDetailWidth
                )
                madeRows[index] = row
                views.append(row)
                if item.isEnabled { selectable.append(index) }
            }
        }

        rows = madeRows
        selectableIndices = selectable
        document = ThemedMenuDocumentView(views: views, heights: entryHeights)
        super.init(frame: frame)

        let paintsIndexedFrame = [
            AppTheme.Material.MenuAppearance.windows98,
            .platinum,
        ].contains(ThemedMenuMetrics.appearance)
        applySurface(
            fill: ThemedMenuMetrics.panelFill,
            radius: .panel,
            // The two indexed classic frames are painted below. Leaving the generic layer
            // border/bevel in place antialiases Windows' square four-tone edge and repaints
            // Platinum's measured black/#222 containment rule with the theme border.
            border: paintsIndexedFrame ? nil : Design.Surface.border,
            glow: ThemedMenuMetrics.panelHasGlow,
            bevel: paintsIndexedFrame ? .none : .automatic
        )

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller =
            document.naturalHeight > frame.height - ThemedMenuMetrics.verticalOuterInset * 2
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.documentView = document
        addSubview(scrollView)

        filterLabel.applyFont(.detail())
        filterLabel.textColor = Design.Text.secondary
        filterLabel.lineBreakMode = .byTruncatingHead
        filterLabel.isHidden = true
        addSubview(filterLabel)

        for row in rows.values {
            row.onChoose = { [weak self] index, item in self?.onChoose?(index, item) }
            row.onHighlight = { [weak self] index in self?.onHighlight?(index) }
            row.onPressBegan = { [weak self] event in self?.onPressBegan?(event) }
        }
        // Scrolling moves every row under any submenu anchored to one of them; the overlay
        // listens and closes what no longer lines up.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(contentScrolled),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
    }

    @objc private func contentScrolled() {
        onScrolled?()
    }

    /// Ends the semantic menu synchronously while its already-drawn pixels finish fading.
    /// `setAccessibilityRole(nil)` is not a removal operation in AppKit: it restores the
    /// receiver's inferred/default role, which leaves this surface reporting `.menu`. Mark the
    /// whole subtree hidden and non-element, and have the role getter return nil once retired so
    /// direct inspection cannot mistake the visual afterimage for a live menu.
    func retireFromAccessibility() {
        isRetiredFromAccessibility = true
        setAccessibilityHidden(true)
        setAccessibilityElement(false)
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        isRetiredFromAccessibility ? nil : .menu
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        switch ThemedMenuMetrics.appearance {
        case .windows98:
            ThemedMenuPanelArtwork.drawWindows98Frame(in: bounds)
        case .platinum:
            ThemedMenuPanelArtwork.drawPlatinumFrame(in: bounds)
        default:
            break
        }
    }

    override func layout() {
        super.layout()
        // Wider at the ends than at the sides under a broad corner — see `verticalOuterInset`.
        let inset = ThemedMenuMetrics.outerInset
        var content = bounds.insetBy(dx: inset, dy: ThemedMenuMetrics.verticalOuterInset)
        if ThemedMenuMetrics.appearance == .platinum {
            // The menu's one-pixel hard shadow is outside the bordered panel on the trailing
            // edge. A symmetric inset gave the document that shadow column and separators
            // painted across the black containment rule at x = width - 2.
            content.size.width = max(0, content.width - 1)
        }
        if !filterLabel.isHidden {
            let header = ThemedMenuMetrics.filterHeaderHeight
            let labelHeight = ceil(filterLabel.font?.boundingRectForFont.height ?? header)
            filterLabel.frame = NSRect(
                x: content.minX + ThemedMenuMetrics.contentInset,
                y: content.maxY - header + (header - labelHeight) / 2,
                width: max(0, content.width - ThemedMenuMetrics.contentInset * 2),
                height: labelHeight
            )
            content.size.height -= header
        }
        scrollView.frame = content
        document.frame = NSRect(
            x: 0,
            y: 0,
            width: scrollView.contentSize.width,
            height: max(document.naturalHeight, scrollView.contentSize.height)
        )
        document.needsLayout = true
    }

    func highlight(_ index: Int?, scrollIntoView: Bool = true) {
        for (entryIndex, row) in rows {
            row.isKeyboardHighlighted = entryIndex == index
        }
        if scrollIntoView, let row = row(at: index) {
            row.scrollToVisible(row.bounds)
        }
    }

    func row(at index: Int?) -> ThemedMenuRowView? {
        index.flatMap { rows[$0] }
    }

    /// The row under a point given in window coordinates — the press-drag-release lookup.
    /// Per-row conversion, so a scrolled document answers correctly.
    func row(underWindowPoint point: NSPoint) -> ThemedMenuRowView? {
        rows.values.first { row in
            row.bounds.contains(row.convert(point, from: nil))
        }
    }

    // MARK: - Filtering

    func applyFilter(_ query: String) {
        for row in rows.values {
            row.isFilteredOut = !query.isEmpty && !Self.matches(row.item, query)
        }
        filterLabel.stringValue = L10n.format("Filter: %@", query)
        filterLabel.isHidden = query.isEmpty
        needsLayout = true
    }

    func selectableIndices(matching query: String) -> [Int] {
        guard !query.isEmpty else { return selectableIndices }
        return selectableIndices.filter { index in
            guard let row = rows[index] else { return false }
            return Self.matches(row.item, query)
        }
    }

    private static func matches(_ item: ThemedMenuItem, _ query: String) -> Bool {
        item.title.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}

/// A render-only entrance to the same surface `ThemedMenuPresenter` puts on screen.
///
/// Historical conformance needs to give the production menu an exact source-sized frame and
/// state without inventing a second HTML/CSS or test painter. Keeping the seam beside the
/// private surface means the archive exercises the live rows, separators, selection, type,
/// bevel, and scrolling implementation while ordinary callers still enter through the presenter.
@MainActor
public enum ThemedMenuReferenceFixture {
    public static func make(
        entries: [ThemedMenuEntry],
        size: NSSize,
        selectedEntryIndex: Int? = nil,
        highlightedEntryIndex: Int? = nil,
        onChoose: ((Int) -> Void)? = nil
    ) -> NSView {
        let surface = ThemedMenuSurfaceView(
            frame: NSRect(origin: .zero, size: size),
            entries: entries,
            selectedEntryIndex: selectedEntryIndex
        )
        if let onChoose {
            surface.onChoose = { index, _ in onChoose(index) }
        }
        surface.highlight(highlightedEntryIndex, scrollIntoView: false)
        surface.layoutSubtreeIfNeeded()
        surface.needsDisplay = true
        return surface
    }

    /// Where an entry's trailing accessory answers a press, in the made surface's own
    /// coordinates.
    ///
    /// Asked of the row rather than recomputed from `ThemedMenuMetrics` at the call site: a test
    /// that derives the target itself is a second implementation of the layout it is checking,
    /// and it passes when both copies are wrong in the same way.
    /// `view` may be the surface itself or anything containing one — a presented menu wraps it in
    /// an overlay and a panel chassis, and a test should not have to know that shape to aim at a
    /// control. The rect comes back in `view`'s own coordinates either way.
    public static func accessoryHitRect(in view: NSView, entryIndex: Int) -> NSRect? {
        guard let surface = surface(in: view),
              let row = surface.row(at: entryIndex),
              row.item.accessory != nil
        else { return nil }
        return row.convert(row.accessoryHitRect, to: view)
    }

    /// The two states only a pointer produces: the accessory lit under it, and held down.
    ///
    /// A render fixture builds a window nobody sees and moves no mouse, so without this the two
    /// states that exist *because* of the pointer would be the two nobody ever looks at. It sets
    /// what the tracking area and the press set and nothing else, so what it draws is what a
    /// press draws — the routing that decides *whether* a press lands on the accessory is left to
    /// the ordinary event path, where a behaviour test drives it.
    public static func setAccessoryPointerState(
        in view: NSView,
        entryIndex: Int,
        hovering: Bool,
        pressed: Bool
    ) {
        guard let row = surface(in: view)?.row(at: entryIndex) else { return }
        row.setAccessoryPointerState(hovering: hovering, pressed: pressed)
    }

    /// The first menu panel in a subtree, so a caller can hand over whichever view it happens to
    /// hold — the surface a fixture made, or the overlay a presenter added to a window.
    private static func surface(in view: NSView) -> ThemedMenuSurfaceView? {
        if let surface = view as? ThemedMenuSurfaceView { return surface }
        for subview in view.subviews {
            if let found = surface(in: subview) { return found }
        }
        return nil
    }

    /// A clipped source-sized view of a live submenu cascade. The production presenter owns
    /// placement on screen; this seam keeps the same two menu surfaces while letting the
    /// evidence archive compare the few overlapping edge pixels retained by a historical crop.
    public static func makeCascade(
        entries: [ThemedMenuEntry],
        size: NSSize,
        highlightedEntryIndex: Int,
        childEntries: [ThemedMenuEntry],
        childSize: NSSize,
        childOriginFromTopLeft: NSPoint,
        childHighlightedEntryIndex: Int? = nil
    ) -> NSView {
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        let parent = ThemedMenuSurfaceView(
            frame: container.bounds,
            entries: entries,
            selectedEntryIndex: nil
        )
        parent.highlight(highlightedEntryIndex, scrollIntoView: false)
        container.addSubview(parent)

        let child = ThemedMenuSurfaceView(
            frame: NSRect(
                x: childOriginFromTopLeft.x,
                y: size.height - childOriginFromTopLeft.y - childSize.height,
                width: childSize.width,
                height: childSize.height
            ),
            entries: childEntries,
            selectedEntryIndex: nil
        )
        child.highlight(childHighlightedEntryIndex, scrollIntoView: false)
        container.addSubview(child)
        container.layoutSubtreeIfNeeded()
        parent.needsDisplay = true
        child.needsDisplay = true
        return container
    }
}

private final class ThemedMenuDocumentView: NSView {

    let naturalHeight: CGFloat
    private let views: [NSView]
    private let viewHeights: [CGFloat]

    override var isFlipped: Bool { true }

    /// `heights` comes from `ThemedMenuMetrics.heights(for:)`, the same call that sized the
    /// panel. It used to be re-derived here from each view's class — a row's own
    /// `preferredHeight`, and `separatorHeight` for anything else — which is fine while every
    /// non-row *is* a separator and silently wrong the moment one is not: a section head was
    /// laid out in a 13pt slot while the panel had been sized for its 30, so the head drew
    /// against the row above it and the difference pooled at the panel's bottom edge.
    init(views: [NSView], heights: [CGFloat]) {
        self.views = views
        if ThemedMenuMetrics.appearance == .platinum, views.count > 1 {
            // The official Help-menu crop exposes the actual edge rhythm: the first and last
            // item slots are 18px, interior item slots 20px, and etched separators 2px. The
            // outer slots meet the frame's inner highlight/shadow, so treating every row as a
            // uniform 19px moved the first separator down while coincidentally leaving the
            // second one correct.
            viewHeights = views.enumerated().map { index, view in
                guard view is ThemedMenuRowView else {
                    return ThemedMenuMetrics.separatorHeight
                }
                return index == 0 || index == views.count - 1 ? 18 : 20
            }
        } else {
            viewHeights = heights
        }
        naturalHeight = viewHeights.reduce(0, +)
        super.init(frame: .zero)
        for view in views { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        var y: CGFloat = 0
        for (view, height) in zip(views, viewHeights) {
            view.frame = NSRect(x: 0, y: y, width: bounds.width, height: height)
            y += height
        }
    }
}

/// A section head: the name of the group under it, choosing nothing.
///
/// Drawn rather than hosted for the same reason the rows are — the panel places its children by
/// frame — and read as a heading by accessibility so a screen reader announces the group before
/// its logins instead of leaving them an undifferentiated run of names.
private final class ThemedMenuHeaderView: NSView, ThemedComponent {

    private let title: String

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        // The rows' own text column, so the head sits over the names it introduces rather than
        // over the checkmark gutter in front of them.
        let font = ThemedMenuMetrics.headerFont
        let height = Design.Typography.lineHeight(of: font)
        (title as NSString).draw(
            in: NSRect(
                x: ThemedMenuMetrics.contentInset,
                y: bounds.maxY - ThemedMenuMetrics.headerTopInset - height / 2
                    - ThemedMenuMetrics.titleBaselineOffset,
                width: max(0, bounds.width - ThemedMenuMetrics.contentInset * 2),
                height: height
            ),
            withAttributes: [
                .font: font,
                .foregroundColor: Design.Text.tertiary,
                .paragraphStyle: {
                    let style = NSMutableParagraphStyle()
                    style.lineBreakMode = .byTruncatingTail
                    return style
                }()
            ]
        )
    }
}

private final class ThemedMenuSeparatorView: NSView, ThemedComponent {
    override func draw(_ dirtyRect: NSRect) {
        if ThemedMenuMetrics.appearance == .platinum {
            let isFlipped = NSGraphicsContext.current?.isFlipped ?? false
            let shadowY = isFlipped ? bounds.minY : bounds.maxY - 1
            let highlightY = isFlipped ? bounds.minY + 1 : bounds.maxY - 2
            NSColor(srgbRed: 136 / 255, green: 136 / 255, blue: 136 / 255, alpha: 1)
                .setFill()
            NSRect(x: bounds.minX, y: shadowY, width: bounds.width, height: 1).fill()
            Design.Surface.bevelHighlight.setFill()
            NSRect(x: bounds.minX, y: highlightY, width: bounds.width, height: 1).fill()
            return
        }
        // Inset to the rows' own content padding, so the rule reads as part of the column
        // of text it divides rather than a wall-to-wall strut.
        let rect = NSRect(
            x: ThemedMenuMetrics.contentInset,
            y: bounds.midY - Design.Radius.border / 2,
            width: max(0, bounds.width - ThemedMenuMetrics.contentInset * 2),
            height: Design.Radius.border
        )
        if ThemedMenuMetrics.usesClassicGrammar {
            // Win32's separator is an etched pair: BTNSHADOW followed by BTNHIGHLIGHT. A single
            // translucent divider reads like a modern list rule against the flat button face.
            Design.Surface.bevelShadow.setFill()
            rect.fill()
            Design.Surface.bevelHighlight.setFill()
            rect.offsetBy(dx: 0, dy: 1).fill()
        } else {
            Design.Surface.divider.setFill()
            rect.fill()
        }
    }
}

/// Indexed panel edges retained from the official Platinum Help-menu figure. The same reason
/// the native scrollbars keep measured symbolic rows applies here: a generic raised bevel puts
/// white on the outside top/left, while a Platinum menu has a black containment rule, one inner
/// highlight/shadow pair, and a one-pixel hard drop shadow at the bottom/right.
@MainActor
private enum ThemedMenuPanelArtwork {
    /// The Win32 popup frame is four indexed one-pixel rails, not the app's ordinary two-line
    /// raised control bevel. In visual order it is BUTTONLIGHT, BTN HIGHLIGHT, BTN SHADOW,
    /// black; the final black bottom/right rail is also the menu's hard one-pixel shadow.
    ///
    /// `outerLight` remains palette-derived so a custom theme that deliberately reuses the
    /// Windows menu anatomy can recolour the face without inheriting a stray literal gray.
    static func drawWindows98Frame(in rect: NSRect) {
        guard rect.width >= 4, rect.height >= 4 else { return }
        let isFlipped = NSGraphicsContext.current?.isFlipped ?? false
        func visualRect(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> NSRect {
            NSRect(
                x: rect.minX + x,
                y: isFlipped
                    ? rect.minY + y
                    : rect.maxY - y - height,
                width: width,
                height: height
            )
        }
        func fill(_ color: NSColor, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) {
            color.setFill()
            visualRect(x: x, y: y, width: width, height: height).fill()
        }

        let width = floor(rect.width)
        let height = floor(rect.height)
        let face = ThemedMenuMetrics.panelFill
        let highlight = Design.Surface.bevelHighlight
        let shadow = Design.Surface.bevelShadow
        // BUTTONLIGHT is the quantized #DF step over the stock #C0 face. A half-channel bias
        // keeps CoreGraphics' round-to-nearest conversion on that indexed value at 1x.
        let outerLight = face.blended(withFraction: 30.5 / 63, of: highlight) ?? highlight

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.shouldAntialias = false
        fill(face, 0, 0, width, height)
        fill(outerLight, 0, 0, width, 1)
        fill(outerLight, 0, 1, 1, height - 2)
        fill(highlight, 1, 1, width - 2, 1)
        fill(highlight, 1, 2, 1, height - 4)
        fill(shadow, width - 2, 2, 1, height - 3)
        fill(shadow, 1, height - 2, width - 2, 1)
        fill(.black, width - 1, 1, 1, height - 1)
        fill(.black, 0, height - 1, width, 1)
        NSGraphicsContext.restoreGraphicsState()
    }

    static func drawPlatinumFrame(in rect: NSRect) {
        guard rect.width >= 4, rect.height >= 4 else { return }
        let isFlipped = NSGraphicsContext.current?.isFlipped ?? false
        func visualRect(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> NSRect {
            NSRect(
                x: rect.minX + x,
                y: isFlipped
                    ? rect.minY + y
                    : rect.maxY - y - height,
                width: width,
                height: height
            )
        }
        func fill(_ color: NSColor, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) {
            color.setFill()
            visualRect(x: x, y: y, width: width, height: height).fill()
        }

        let width = floor(rect.width)
        let height = floor(rect.height)
        // The source pixel is literal black. `label` is semantic elsewhere, but a user-edited
        // role must not recolour historical menu hardware after `.platinum` has selected it.
        let ink = NSColor.black
        let face = ThemedMenuMetrics.panelFill
        let innerShadow = NSColor(
            srgbRed: 153 / 255, green: 153 / 255, blue: 153 / 255, alpha: 1
        )
        let hardShadow = NSColor(
            srgbRed: 34 / 255, green: 34 / 255, blue: 34 / 255, alpha: 1
        )

        fill(.white, 0, 0, width, height)
        fill(hardShadow, 2, height - 1, width - 2, 1)
        fill(hardShadow, width - 1, 2, 1, height - 2)
        fill(ink, 0, 0, width, 1)
        fill(ink, 0, 0, 1, height - 1)
        fill(ink, width - 2, 0, 1, height - 1)
        fill(ink, 0, height - 2, width - 1, 1)
        fill(face, 1, 1, width - 3, height - 3)
        fill(Design.Surface.bevelHighlight, 1, 1, width - 4, 1)
        fill(Design.Surface.bevelHighlight, 1, 1, 1, height - 3)
        fill(innerShadow, width - 3, 2, 1, height - 4)
        fill(innerShadow, 2, height - 3, width - 4, 1)
    }
}

// MARK: - Row

private final class ThemedMenuRowView: ThemedControl {

    let entryIndex: Int
    let item: ThemedMenuItem
    let preferredHeight: CGFloat

    var onChoose: ((Int, ThemedMenuItem) -> Void)?
    var onHighlight: ((Int) -> Void)?
    /// Reported before the row decides anything of its own, and reported by a disabled row too:
    /// a sweep that begins on an unavailable row still chooses the enabled one it ends on.
    var onPressBegan: ((NSEvent) -> Void)?
    var isKeyboardHighlighted = false {
        didSet {
            guard isKeyboardHighlighted != oldValue else { return }
            needsDisplay = true
            reportHighlight(isKeyboardHighlighted)
        }
    }
    /// The row does not match what is being typed. It dims rather than hides, so the menu
    /// keeps its shape while the filter narrows.
    var isFilteredOut = false {
        didSet {
            needsDisplay = true
            applyPreviewInk()
        }
    }

    private let selected: Bool
    /// How *the menu* carries its marks — not whether this row is marked. A column belongs to
    /// the panel, so an unmarked row in a menu of markable ones still starts after it.
    private let checkColumn: ThemedMenuMetrics.CheckColumn
    private let hasImageColumn: Bool
    private let hasPreviewColumn: Bool
    private let hasSubmenuColumn: Bool
    /// Again the *menu's* answer rather than this row's: a row with no accessory in a menu that
    /// has them still starts its trailing columns after the slot, or the titles either side of it
    /// would end at two different places.
    private let hasAccessoryColumn: Bool
    private let shortcutColumnWidth: CGFloat
    /// The menu's shared column plan, so this row puts its `7d` where every other row puts its
    /// `7d` — including the rows that have no `7d` and leave the cell empty.
    private let metricColumns: [String]
    private let metricColumnWidth: CGFloat
    private let trailingDetailWidth: CGFloat
    /// Whether this row's *run* keeps a second line — not whether this row fills it. See
    /// `firstLineCenterY`.
    private let reservesSubtitleLine: Bool
    private var pressed = false { didSet { needsDisplay = true } }
    /// The pointer is on a row that cannot be chosen. It answers with a wash far fainter
    /// than the hover fill — feedback that the hover was seen, not an invitation.
    private var isDisabledHover = false { didSet { needsDisplay = true } }

    /// The pointer is on the accessory in particular, rather than merely on the row carrying it.
    /// A revealed control that does not answer its own hover is a picture of a button.
    private var isAccessoryHovered = false {
        didSet {
            guard isAccessoryHovered != oldValue else { return }
            needsDisplay = true
            updateToolTip()
        }
    }
    /// A press that began on the accessory. Held separately from `pressed` because the two mean
    /// opposite things on release: this one runs the accessory and leaves the menu standing,
    /// while `pressed` chooses the row and closes it.
    private var accessoryPressed = false { didSet { needsDisplay = true } }
    /// A second area over the accessory's own rectangle. `ThemedControl` owns the row's, and the
    /// row's cannot answer this question: the pointer moving from a title onto the glyph beside
    /// it crosses nothing the row can see.
    private var accessoryTrackingArea: NSTrackingArea?

    /// The open panel this row fathered, while it is open. It keeps the row drawing the
    /// menu-path highlight — the parent stays lit wherever the pointer is in its chain, as
    /// the platform's own menus stay lit — and it is what accessibility descends into.
    private(set) weak var openSubmenuSurface: NSView?

    /// A preview in the title's slot is the row's name, so the row draws no text of its own.
    private var drawsTitle: Bool { item.preview?.placement != .title }

    /// The axis **everything on a row's first line** is placed on: the checkmark, the mark, the
    /// title and its qualifier, the metric columns, the trailing detail, the submenu chevron.
    ///
    /// Each of those used to be centred on the row instead, which is right for a single-line row
    /// and wrong for every row beside one. A title with a subtitle is placed as a centred *block*,
    /// so its own line sits above the row's middle — while the mark next to it, centred on the
    /// row, sank to between the two lines, and a neighbouring row with no subtitle put its title
    /// where this row's ink is not. Down a column of logins that reads as rows nudged out of
    /// alignment at random, which is exactly what it looked like.
    ///
    /// So the line is computed from the slot the *run* reserves rather than from what this row
    /// happens to carry: a row with no subtitle in a run that has them keeps its title on its
    /// neighbours' line and leaves the second line empty, the way a table leaves a cell empty.
    private var firstLineCenterY: CGFloat {
        ThemedMenuMetrics.firstLineCenter(
            inRowOf: bounds.height,
            reservesSubtitleLine: reservesSubtitleLine
        )
    }

    init(
        entryIndex: Int,
        item: ThemedMenuItem,
        isSelected: Bool,
        checkColumn: ThemedMenuMetrics.CheckColumn,
        hasImageColumn: Bool,
        hasPreviewColumn: Bool,
        hasSubmenuColumn: Bool,
        hasAccessoryColumn: Bool = false,
        shortcutColumnWidth: CGFloat,
        /// The menu's, not the row's: `ThemedMenuMetrics.heights(for:)` decides it from the run
        /// this row sits in, so neighbours stacked against each other keep one rhythm.
        preferredHeight: CGFloat,
        metricColumns: [String] = [],
        metricColumnWidth: CGFloat = 0,
        trailingDetailWidth: CGFloat = 0
    ) {
        self.entryIndex = entryIndex
        self.item = item
        selected = isSelected
        self.checkColumn = checkColumn
        self.hasImageColumn = hasImageColumn
        self.hasPreviewColumn = hasPreviewColumn
        self.hasSubmenuColumn = hasSubmenuColumn
        self.hasAccessoryColumn = hasAccessoryColumn
        self.shortcutColumnWidth = shortcutColumnWidth
        self.metricColumns = metricColumns
        self.metricColumnWidth = metricColumnWidth
        self.trailingDetailWidth = trailingDetailWidth
        self.preferredHeight = preferredHeight
        reservesSubtitleLine = preferredHeight >= ThemedMenuMetrics.subtitleRowHeight
        super.init(frame: .zero)
        updateToolTip()
        installPreview()
    }

    /// What the row says when the pointer rests on it.
    ///
    /// Explicit help wins because it explains the consequence the visible title cannot. Without
    /// it, the whole reading wins over the subtitle alone: once the numbers are columns and a
    /// drawn bar, a tooltip carrying only the leftover line would name less than the row shows.
    /// On the accessory it becomes the accessory's own name instead — a glyph that appeared under
    /// the pointer has no other way to say what it does, and while the pointer is on it the row's
    /// reading is not the question being asked.
    private func updateToolTip() {
        if isAccessoryHovered, let accessory = item.accessory {
            toolTip = accessory.title
            return
        }
        if let help = item.help, !help.isEmpty {
            toolTip = help
        } else {
            toolTip = item.metrics.isEmpty && item.trailingDetail == nil
                ? item.subtitle
                : item.spokenSummary
        }
    }

    // MARK: - Submenu

    func submenuDidOpen(_ surface: NSView) {
        openSubmenuSurface = surface
        surface.setAccessibilityParent(self)
        needsDisplay = true
    }

    func submenuDidClose() {
        guard openSubmenuSurface != nil else { return }
        openSubmenuSurface = nil
        needsDisplay = true
    }

    // MARK: - Preview

    /// Places the caller's live view in the column its placement names.
    ///
    /// Constraints rather than a frame set in `layout()`: the view arrives from the design
    /// system with an Auto Layout interior of its own — the orb pinned inside its tint wrapper,
    /// the morphing label inside its clip — and a row that reached in to set frames would be
    /// laying out somebody else's subtree. The row is frame-placed by the document view, which
    /// is what lets constraints from its own edges resolve.
    private func installPreview() {
        guard let preview = item.preview else { return }

        preview.view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(preview.view)

        switch preview.placement {
        case .leading:
            // Own every constraint at the row, including the two single-item size constraints.
            // `activate` would otherwise install those two on the caller-owned preview itself.
            // Motion previews are intentionally reused when the menu reopens; a 16pt classic
            // row followed by a 20pt modern row would then leave both required sizes attached to
            // the orb. Removing the old row must remove the whole placement model with it.
            addConstraints([
                preview.view.leadingAnchor.constraint(
                    equalTo: leadingAnchor,
                    constant: ThemedMenuMetrics.previewInset(
                        checkColumn: checkColumn,
                        hasImageColumn: hasImageColumn
                    )
                ),
                preview.view.centerYAnchor.constraint(equalTo: centerYAnchor),
                preview.view.widthAnchor.constraint(
                    equalToConstant: ThemedMenuMetrics.previewSize
                ),
                preview.view.heightAnchor.constraint(
                    equalToConstant: ThemedMenuMetrics.previewSize
                )
            ])
        case .title:
            // Pinned to both edges of the title column rather than sized to its text: a label
            // whose width followed the name it is morphing *into* would resize under its own
            // animation, and the transition would read as the row twitching.
            let trailing = preview.view.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -ThemedMenuMetrics.contentInset
            )
            // The document owns the row's frame. While AppKit first attaches its zero-width
            // document view, the temporary autoresizing-mask width must be allowed to win;
            // once the document lays out, this equality becomes satisfiable and resumes its
            // ordinary job. Making the row itself constraint-driven loses that manual frame.
            trailing.priority = NSLayoutConstraint.Priority(999)
            NSLayoutConstraint.activate([
                preview.view.leadingAnchor.constraint(
                    equalTo: leadingAnchor,
                    constant: ThemedMenuMetrics.titleInset(
                        checkColumn: checkColumn,
                        hasImageColumn: hasImageColumn,
                        hasPreviewColumn: hasPreviewColumn
                    )
                ),
                trailing,
                preview.view.centerYAnchor.constraint(equalTo: centerYAnchor)
            ])
        }

        applyPreviewInk()
    }

    /// The dimming a drawn row applies to its text, applied to a hosted view instead — a
    /// disabled or filtered-out row cannot be dimmed by the alpha in `draw(_:)` if its name is
    /// a subview.
    private func applyPreviewInk() {
        guard let preview = item.preview else { return }
        preview.view.alphaValue = contentAlpha
    }

    /// A closing menu takes its previews with it. Nothing else reports the end of a highlight
    /// when the overlay is torn down — the surface deliberately stops moving the highlight once
    /// it is closing — so this is what stops a demonstration the user has walked away from.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil, isKeyboardHighlighted {
            isKeyboardHighlighted = false
        }
        if newWindow == nil {
            // Detachment produces no pointer exit, and a retained row must not come back holding
            // a lit accessory or a half-finished press. `ThemedControl` says the same about the
            // row's own hover.
            isAccessoryHovered = false
            accessoryPressed = false
        }
    }

    /// Reports to the preview, unless this row no longer speaks for it.
    ///
    /// A preview is a view the caller owns and the row borrows, and a dropdown reopened while the
    /// previous panel is still fading hands the same view to a *new* row. The old row's teardown
    /// would then cancel a demonstration the new row had already started, leaving the menu
    /// looking as though the feature had stopped working.
    private func reportHighlight(_ isHighlighted: Bool) {
        guard let preview = item.preview, preview.view.superview === self else { return }
        preview.highlightChanged?(isHighlighted)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { false }

    /// A row's hover is the menu's highlight, so it is reported rather than drawn — and for a row
    /// that cannot be chosen it is the faint wash instead.
    override func hoverDidChange() {
        super.hoverDidChange()
        guard item.isEnabled else {
            isDisabledHover = isHovered
            return
        }
        if isHovered { onHighlight?(entryIndex) }
    }

    override func mouseDown(with event: NSEvent) {
        // Reported first and unconditionally, exactly as before: the held-press tracking this
        // arms belongs to the menu, and a press that turns out to be an audition is still a
        // press the menu has to know about.
        onPressBegan?(event)
        guard item.isEnabled else { return }
        if hitsAccessory(event) {
            accessoryPressed = true
            return
        }
        pressed = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard item.isEnabled else { return }
        // A drag off the glyph disarms the audition rather than promoting it to a choice. A
        // press that began on a control and ended somewhere else does nothing, which is what
        // every button on the platform does and is the escape hatch from a mispress.
        if accessoryPressed {
            accessoryPressed = hitsAccessory(event)
            return
        }
        pressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        if accessoryPressed {
            accessoryPressed = false
            if hitsAccessory(event) {
                performAccessory()
            }
            // Never falls through to the choice. The menu is still standing and the setting is
            // still whatever it was, which is the entire contract of an audition.
            return
        }
        guard pressed else { return }
        pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            _ = performPrimaryAction()
        }
    }

    override func performPrimaryAction() -> Bool {
        guard item.isEnabled else { return false }
        onChoose?(entryIndex, item)
        return true
    }

    // MARK: - Accessory

    /// The glyph's own rectangle, on the row's first line like everything else trailing.
    private var accessoryRect: NSRect {
        NSRect(
            x: bounds.maxX - ThemedMenuMetrics.contentInset - ThemedMenuMetrics.accessorySize,
            y: firstLineCenterY - ThemedMenuMetrics.accessorySize / 2,
            width: ThemedMenuMetrics.accessorySize,
            height: ThemedMenuMetrics.accessorySize
        )
    }

    /// What a press has to land in, which is larger than what is drawn — and clamped to the row,
    /// so padding a small glyph never quietly claims part of the row above or below it.
    var accessoryHitRect: NSRect {
        accessoryRect
            .insetBy(
                dx: -ThemedMenuMetrics.accessoryHitPadding,
                dy: -ThemedMenuMetrics.accessoryHitPadding
            )
            .intersection(bounds)
    }

    private func hitsAccessory(_ event: NSEvent) -> Bool {
        guard item.accessory != nil else { return false }
        return accessoryHitRect.contains(convert(event.locationInWindow, from: nil))
    }

    /// The pointer's two states, for the fixture that has no pointer. See
    /// `ThemedMenuReferenceFixture.setAccessoryPointerState`.
    func setAccessoryPointerState(hovering: Bool, pressed: Bool) {
        isAccessoryHovered = hovering
        accessoryPressed = pressed
    }

    /// Runs the accessory. The one entry point, so the pointer, the right arrow and VoiceOver
    /// cannot end up doing three slightly different things.
    @discardableResult
    func performAccessory() -> Bool {
        guard item.isEnabled, let accessory = item.accessory else { return false }
        accessory.action()
        return true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let accessoryTrackingArea {
            removeTrackingArea(accessoryTrackingArea)
            self.accessoryTrackingArea = nil
        }
        guard item.accessory != nil else {
            isAccessoryHovered = false
            return
        }

        // An explicit rectangle rather than `.inVisibleRect`, which would snap the area to the
        // whole visible row and answer for the title as well as the glyph.
        let area = NSTrackingArea(
            rect: accessoryHitRect,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self
        )
        addTrackingArea(area)
        accessoryTrackingArea = area

        // Tracking is rebuilt exactly when this row's geometry changed — a scroll, a resize —
        // which is the one moment a hover can have gone stale with the pointer never moving.
        // `ThemedControl` does this for the row; the sub-rect is ours to answer for.
        if isAccessoryHovered, !accessoryHitRect.contains(
            convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
        ) {
            isAccessoryHovered = false
        }
    }

    /// Both areas report here, and only one of them is the row's.
    ///
    /// Passing an accessory crossing to `super` would be the bug this split exists to avoid: the
    /// pointer moving from the title onto the glyph beside it exits nothing, but the second area's
    /// *entry* would set the row's hover a second time and its exit — fired while the pointer is
    /// still well inside the row — would clear it, so a row would go dark as the pointer arrived
    /// at the control it was reaching for.
    override func mouseEntered(with event: NSEvent) {
        if event.trackingArea === accessoryTrackingArea {
            isAccessoryHovered = true
            return
        }
        super.mouseEntered(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        if event.trackingArea === accessoryTrackingArea {
            isAccessoryHovered = false
            accessoryPressed = false
            return
        }
        // Leaving the row leaves everything on it. The sub-area fires its own exit for an
        // ordinary crossing, but not when the row is removed from under a still pointer.
        isAccessoryHovered = false
        accessoryPressed = false
        super.mouseExited(with: event)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .menuItem }
    /// The whole row, not its name. A login whose readings are columns and a drawn bar says
    /// nothing at all to VoiceOver if only its title is announced — and "identifiable without
    /// colour alone" is not met by a bar whose severity is a hue.
    override func accessibilityTitle() -> String? { item.spokenSummary }
    override func accessibilityHelp() -> String? {
        guard let help = item.help, !help.isEmpty else { return nil }
        return help
    }
    override func accessibilityValue() -> Any? { selected }
    override func isAccessibilityEnabled() -> Bool { item.isEnabled }
    override func accessibilityPerformPress() -> Bool { performPrimaryAction() }

    /// "Show menu" is honest only on a row that has one; pressing a parent row opens it, so
    /// the two actions meet in the same place.
    override func accessibilityPerformShowMenu() -> Bool {
        guard item.submenu != nil else { return false }
        return performPrimaryAction()
    }

    /// A menu item is a leaf whatever it is drawn from — a hosted preview is how this row
    /// shows its own title, not a second thing to navigate to — with one exception: the
    /// submenu it has opened is its child, exactly as the platform models an item's menu.
    override func accessibilityChildren() -> [Any]? {
        openSubmenuSurface.map { [$0] } ?? []
    }

    /// The accessory, offered as an action on the row rather than as an element inside it.
    ///
    /// This is what keeps the rule above true. A second focusable thing in a menu item would put
    /// an element between a menu and its items where the platform models none, and every consumer
    /// that walks a menu expecting rows would find one row wearing a button. An action is the
    /// platform's own answer for "this element can do a second thing", it is announced with the
    /// row rather than found by hunting inside it, and it reaches exactly the same code the
    /// pointer does.
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard item.isEnabled, let accessory = item.accessory else { return nil }
        return [
            NSAccessibilityCustomAction(name: accessory.title) { [weak self] in
                self?.performAccessory() ?? false
            }
        ]
    }

    // MARK: - Drawing

    /// How strongly the row states its content: full, dimmed for a row that cannot be chosen,
    /// dimmed again for one the filter has excluded. Read by `draw(_:)` for the text it inks
    /// and by `applyPreviewInk` for the text it hosts, so the two cannot disagree.
    private var contentAlpha: CGFloat {
        var alpha = item.isEnabled ? 1 : ThemedMenuMetrics.disabledDimming
        if isFilteredOut {
            alpha *= ThemedMenuMetrics.filteredOutDimming
        }
        return alpha
    }

    /// A text role at `contentAlpha`, **scaling** the role's own alpha rather than replacing it.
    ///
    /// `withAlphaComponent` sets alpha outright, so calling it with the 1 an ordinary enabled row
    /// reports did not leave the colour alone — it overwrote whatever transparency the role
    /// carried. Every label tier below `label` is defined *as* an alpha: `tertiaryLabel` is the
    /// label colour at 0.45 in a styled theme and `NSColor.tertiaryLabelColor` at roughly 0.26
    /// under the system one. Both arrived at the drawing call as fully opaque, so a menu's
    /// subtitle was painted in exactly the title's black and the pair had only 1pt of size and
    /// one weight step between them. That is most of why a subtitle row read as two titles.
    ///
    /// Multiplying also keeps a *dimmed* row dimmer than an enabled one, which replacing did not:
    /// at `disabledDimming` the old call pushed a 0.26 subtitle up to 0.45.
    private func ink(_ base: NSColor, _ alpha: CGFloat) -> NSColor {
        guard alpha < 1 else { return base }
        guard let resolved = base.usingColorSpace(.sRGB) else {
            return base.withAlphaComponent(alpha)
        }
        return resolved.withAlphaComponent(resolved.alphaComponent * alpha)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Every fill takes the same silhouette: one shape, drawn at two strengths. The inset
        // is what keeps a filled row off the one stacked against it.
        let fillRect: NSRect
        if ThemedMenuMetrics.appearance == .windows98 {
            // The native band starts one pixel inside the document's leading/top edge. Its
            // trailing/bottom edges remain flush, producing the measured 20px band in a 21px
            // row rather than a modern symmetrically inset capsule.
            fillRect = NSRect(
                x: bounds.minX + 1,
                y: bounds.minY,
                width: max(0, bounds.width - 2),
                height: max(0, bounds.height - 1)
            )
        } else {
            fillRect = bounds.insetBy(dx: 0, dy: ThemedMenuMetrics.fillInset)
        }

        // **A checked row is not a filled row.** The check states what is on; the fill states
        // where the pointer or the keyboard is, and only one row can be that at a time. Painting
        // both meant a menu of toggles came up three-quarters filled before it had been touched —
        // and the role it filled with, `selection`, is the ground behind selected *text*: at
        // Win98's solid navy or the System theme's accent it read as three highlighted rows
        // fighting the one the pointer was actually on.
        //
        // The open-submenu fill is the menu path: the parent stays lit while the pointer is
        // anywhere in the chain it opened, which is what keeps a three-panel menu readable.
        let isHighlighted = isKeyboardHighlighted || pressed || openSubmenuSurface != nil
        let selection = isHighlighted && ThemedMenuMetrics.usesClassicGrammar
            ? SelectionSurface.stated(over: ThemedMenuMetrics.panelFill)
            : nil
        if let selection {
            // A Win32 menu highlight is a flat COLOR_HIGHLIGHT band, not another raised
            // pushbutton. `bevel: .none` is load-bearing under hard-relief materials.
            ThemedSurface.draw(
                fillRect,
                fill: selection.fill,
                radius: 0,
                bevel: .none
            )
        } else if isHighlighted {
            ThemedSurface.draw(
                fillRect,
                fill: Design.Surface.controlHover,
                // Fitted, like every other row-shaped fill in the window — a sidebar row's hover
                // and a list row's selection both take this. The unfitted token is a corner the
                // theme states for a control of *any* size: Botanical's is 24, which on a 26pt
                // row is wider than the row is tall, and the fill came out as a taper.
                radius: Design.Radius.control(fitting: fillRect.size)
            )
        } else if isDisabledHover {
            // Resolve, then multiply — `withAlphaComponent` replaces the alpha outright,
            // and the hover fill is already translucent by design.
            let hover = Design.Surface.controlHover
            let resolved = hover.usingColorSpace(.sRGB) ?? hover
            ThemedSurface.draw(
                fillRect,
                fill: resolved.withAlphaComponent(
                    resolved.alphaComponent * ThemedMenuMetrics.disabledHoverWash
                ),
                radius: Design.Radius.control(fitting: fillRect.size)
            )
        }

        let alpha = contentAlpha
        let selectionLabel = selection != nil && ThemedMenuMetrics.appearance == .windows98
            ? Design.Surface.bevelHighlight
            : selection?.ink.label
        let label = ink(selectionLabel ?? Design.Text.label, alpha)
        // `secondary` rather than `tertiary`, deliberately. A subtitle here is not decoration —
        // it is the sentence that says what a permission mode will *do* — and rendered against
        // these titles `tertiary` read as disabled rather than as support. The separation the
        // pair was missing comes from `ink` no longer flattening this role to opaque black, and
        // from the rhythm, not from taking the copy down another tier.
        let secondary = ink(selection?.ink.secondary ?? Design.Text.secondary, alpha)
        // What a row's leading mark is drawn in. The historical grammars keep theirs at full
        // ink: a Win32 menu bitmap and a Platinum icon are artwork at the label's weight, and
        // dimming them would be a modern idea applied to a reconstruction.
        let glyph = ThemedMenuMetrics.usesClassicGrammar ? label : secondary

        let lineY = firstLineCenterY

        if selected {
            drawCheckMark(
                in: NSRect(
                    x: ThemedMenuMetrics.contentInset,
                    y: lineY - ThemedMenuMetrics.checkSize / 2,
                    width: ThemedMenuMetrics.checkSize,
                    height: ThemedMenuMetrics.checkSize
                ),
                color: label
            )
        }

        if hasImageColumn, let image = item.image {
            let imageRect = NSRect(
                x: ThemedMenuMetrics.markInset(checkColumn: checkColumn),
                y: lineY - ThemedMenuMetrics.imageSize / 2
                    + ThemedMenuMetrics.imageBaselineOffset,
                width: ThemedMenuMetrics.imageSize,
                height: ThemedMenuMetrics.imageSize
            )
            // **A row's mark is quieter than its name.** A menu whose glyphs are inked as loudly
            // as the words doubles the number of things competing for the first glance, and the
            // words are what is being chosen between. `secondary` is also what keeps a column of
            // icons reading as a column rather than as a second column of content. Non-template
            // artwork — an app's own icon, an account's mark — ignores the tint and keeps its
            // colours, which is right: those *are* content.
            draw(image, in: imageRect, tint: glyph)
        }

        // The accessory owns the outermost trailing column, so a chevron steps inward by its
        // slot — measured off the menu's answer, not this row's, or a chevron would sit at two
        // different x positions down one panel.
        let accessoryColumn = hasAccessoryColumn ? ThemedMenuMetrics.accessorySlot : 0

        if item.submenu != nil {
            drawChevron(
                in: NSRect(
                    x: bounds.maxX - ThemedMenuMetrics.submenuTrailingInset
                        - ThemedMenuMetrics.submenuChevronSize - accessoryColumn,
                    y: lineY - ThemedMenuMetrics.submenuChevronSize / 2,
                    width: ThemedMenuMetrics.submenuChevronSize,
                    height: ThemedMenuMetrics.submenuChevronSize
                ),
                color: label
            )
        }

        drawAccessory(label: label, secondary: secondary)

        guard drawsTitle else { return }

        let x = ThemedMenuMetrics.titleInset(
            checkColumn: checkColumn,
            hasImageColumn: hasImageColumn,
            hasPreviewColumn: hasPreviewColumn
        )
        let titleFont = ThemedMenuMetrics.titleFont
        // The **line box**, not `boundingRectForFont`. That rect carries the family's glyph
        // extremes, `draw(in:)` sets its line down from the rect's top, and the difference is
        // dead air above the words: under SF the two heights all but coincide and this read as
        // centred, while under Platinum — whose Charcoal falls back to Geneva, 24.4pt of
        // bounding rect around a 16pt line — every title sat 4pt above the checkmark and the
        // icon in its own row, which are placed against `midY`. It also disagreed with a
        // *hosted* preview in the title column, which is centred by constraint.
        let titleHeight = Design.Typography.lineHeight(of: titleFont)
        let subtitleFont = Design.Typography.detail()
        let subtitleHeight = Design.Typography.lineHeight(of: subtitleFont)
        let hasSubtitle = item.subtitle?.isEmpty == false
        // The two lines are placed as **one block, centred** — not each against `midY`
        // separately, which is what this did before. Independently, they sat 4pt apart inside a
        // row whose neighbours it touches edge to edge, so the gap to the *next row's* title came
        // out barely wider than the gap to a title's own subtitle: ~18pt against ~24pt. At that
        // ratio proximity states nothing and the menu reads as one evenly stacked column of
        // alternating weights rather than as pairs.
        //
        // The block's top line is `firstLineCenterY`, which every other part of the row is placed
        // against too — so the title, the mark beside it and the columns across from it share one
        // axis, and a row without a subtitle keeps its title on that same axis instead of sliding
        // down to the middle of its slot.
        let titleY = lineY - titleHeight / 2 + ThemedMenuMetrics.titleBaselineOffset
        let subtitleY = titleY - ThemedMenuMetrics.subtitleGap - subtitleHeight
        // Everything reserved at the trailing edge before the readings begin: the chevron column
        // and the accessory column, each present only if some row in this menu carries one.
        let trailingColumns = (hasSubmenuColumn ? ThemedMenuMetrics.submenuChevronSlot : 0)
            + accessoryColumn
        let shortcutReservation = shortcutColumnWidth > 0
            ? ThemedMenuMetrics.shortcutGap + shortcutColumnWidth
            : 0
        // Drawn before the title, because what it returns is how much room the title has left.
        // The columns are fixed and the name is elastic — the inversion of the line this
        // replaced, where the name set the numbers' positions and the countdown lost its digits.
        let metricReservation = drawMetricColumns(
            trailingEdge: bounds.maxX - ThemedMenuMetrics.contentInset - trailingColumns
                - shortcutReservation,
            centeredOn: titleY + titleHeight / 2,
            selection: selection,
            alpha: alpha,
            secondary: secondary
        )
        let textWidth = max(
            0,
            bounds.maxX - ThemedMenuMetrics.contentInset - trailingColumns
                - shortcutReservation - metricReservation - x
        )
        // Win98's GDI text, Platinum's QuickDraw menu face, and Workbench's Topaz menu strike
        // are indexed bitmaps. Letting CoreGraphics smooth a fallback produces the right
        // outline under a gray veil, but does not reproduce the source pixels. Keep this
        // deliberately narrower than the whole theme so ordinary prose remains readable.
        let drawsIndexedText = ThemedMenuMetrics.appearance == .windows98
            || ThemedMenuMetrics.appearance == .platinum
            || ThemedMenuMetrics.appearance == .amiga
        if drawsIndexedText {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.shouldAntialias = false
            NSGraphicsContext.current?.cgContext.setShouldAntialias(false)
            NSGraphicsContext.current?.cgContext.setAllowsAntialiasing(false)
            NSGraphicsContext.current?.cgContext.setShouldSmoothFonts(false)
            NSGraphicsContext.current?.cgContext.setAllowsFontSmoothing(false)
        }
        let drewPlatinumBitmap = ThemedMenuMetrics.appearance == .platinum
            && DesignSettings.current.chromeFontFamily == nil
            && titleFont.familyName?.caseInsensitiveCompare("Charcoal") != .orderedSame
            && !hasSubtitle
            // The bitmap strike draws one ink. A title carrying a quieter qualifier after it is
            // two, and drawing it here would silently drop the qualifier rather than tone it.
            && item.titleDetail?.isEmpty != false
            && PlatinumBitmapFont.draw(
                item.title,
                penX: x + 1,
                baselineFromTop: PlatinumBitmapFont.centeredBaseline(
                    in: bounds,
                    offset: -1
                ) ?? 0,
                in: bounds,
                ink: label
            )
        // An ellipsis rather than a hard clip when the panel's width cap wins: a menu is
        // entitled to cut a line short — `ThemedMenuLayout.maximumWidth` exists — but a row
        // sliced mid-word reads as a rendering fault, and `7d resets in` with the number gone
        // is a sentence claiming to be complete. The mark is what says the line continues.
        let truncating = NSMutableParagraphStyle()
        truncating.lineBreakMode = .byTruncatingTail
        if !drewPlatinumBitmap {
            let titleLine = NSMutableAttributedString(string: item.title, attributes: [
                .font: titleFont, .foregroundColor: label, .paragraphStyle: truncating
            ])
            if let detail = item.titleDetail, !detail.isEmpty {
                // Quieter than the name and in the same line box: it identifies the row without
                // competing with what the row is called. A classic band flattens it to the
                // band's own label ink for the reason every other tone does.
                titleLine.append(NSAttributedString(
                    string: ThemedMenuMetrics.titleDetailGap + detail,
                    attributes: [
                        .font: titleFont,
                        .foregroundColor: selection == nil
                            ? ink(Design.Text.tertiary, alpha)
                            : label,
                        .paragraphStyle: truncating
                    ]
                ))
            }
            titleLine.draw(
                in: NSRect(x: x, y: titleY, width: textWidth, height: titleHeight)
            )
        }

        if let shortcut = item.resolvedShortcut, shortcutColumnWidth > 0 {
            let shortcutX = bounds.maxX - ThemedMenuMetrics.contentInset - trailingColumns
                - shortcutColumnWidth
            drawShortcut(
                shortcut,
                in: NSRect(
                    x: shortcutX,
                    y: lineY - titleHeight / 2 + ThemedMenuMetrics.titleBaselineOffset,
                    width: shortcutColumnWidth,
                    height: titleHeight
                ),
                font: titleFont,
                color: label
            )
        }

        if let subtitle = item.subtitle, !subtitle.isEmpty {
            let line = NSMutableAttributedString()
            // Toned runs are resolved to colours *here*, per draw, so a theme switch under an
            // open menu re-inks the next frame — the same reason the row reads `Design` roles
            // instead of caching them. A classic selection band flattens every run to the
            // band's own subtitle ink: that authored pair is the only ink measured against the
            // band's solid fill, and a status hue or a quaternary grey over Win98 navy is
            // exactly the unmeasured contrast the pair exists to prevent. The tint is a
            // second signal, never the only one — the numbers say the same thing in any ink.
            let runs = selection == nil ? item.subtitleSegments : nil
            for segment in runs ?? [ThemedMenuSubtitleSegment(subtitle)] {
                let tone: NSColor
                switch segment.tone {
                case .standard: tone = secondary
                case .muted: tone = ink(Design.Text.tertiary, alpha)
                case .warning: tone = ink(Design.Status.warning, alpha)
                case .critical: tone = ink(Design.Status.negative, alpha)
                }
                line.append(NSAttributedString(string: segment.text, attributes: [
                    .font: subtitleFont, .foregroundColor: tone, .paragraphStyle: truncating
                ]))
            }
            line.draw(
                in: NSRect(
                    x: x,
                    y: subtitleY,
                    width: textWidth,
                    height: subtitleHeight
                )
            )
        }
        if drawsIndexedText {
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// Draws this row's readings into the menu's shared columns, and returns what they took out
    /// of the row's width.
    ///
    /// Laid out from the trailing edge inward — trailing detail first, then the columns
    /// right-to-left — so the whole block is anchored to the panel's edge and lands in the same
    /// place on every row whatever its name is. A cell whose column this row has no reading for
    /// is left empty rather than closed up: closing it would slide the remaining readings under
    /// a different heading, which is the one thing a column must never do.
    private func drawMetricColumns(
        trailingEdge: CGFloat,
        centeredOn centerY: CGFloat,
        selection: SelectionSurface?,
        alpha: CGFloat,
        secondary: NSColor
    ) -> CGFloat {
        guard !metricColumns.isEmpty || trailingDetailWidth > 0 else { return 0 }

        let font = ThemedMenuMetrics.metricFont
        let height = Design.Typography.lineHeight(of: font)
        let y = centerY - height / 2 + ThemedMenuMetrics.titleBaselineOffset
        // A band flattens every tone to its own authored ink, text and bar alike: a status hue
        // over a solid classic selection is exactly the unmeasured contrast the pair prevents.
        let banded = selection?.ink.label
        let muted = banded ?? ink(Design.Text.tertiary, alpha)

        func toned(_ tone: ThemedMenuSubtitleSegment.Tone) -> NSColor {
            if let banded { return banded }
            switch tone {
            case .standard: return secondary
            case .muted: return muted
            case .warning: return ink(Design.Status.warning, alpha)
            case .critical: return ink(Design.Status.negative, alpha)
            }
        }

        var cursor = trailingEdge
        if trailingDetailWidth > 0 {
            if let detail = item.trailingDetail, !detail.isEmpty {
                draw(
                    detail,
                    rightAlignedIn: NSRect(
                        x: cursor - trailingDetailWidth,
                        y: y,
                        width: trailingDetailWidth,
                        height: height
                    ),
                    font: font,
                    color: muted
                )
            }
            cursor -= trailingDetailWidth
            if metricColumns.isEmpty {
                cursor -= ThemedMenuMetrics.metricColumnGap
            } else {
                // A rule, not more air. The countdown is a different kind of fact from the
                // readings — not the next window — and at the gap that parts two columns it
                // joined them: `99%` and `7d · 5d 3h` read as one run of numbers.
                //
                // The *space* it sits in belongs to the menu's column plan, so the cursor steps
                // over it on every row and the columns to its left stay aligned. The *ink* is
                // this row's: a row with nothing on both sides of it — a runtime with no login —
                // otherwise drew a rule standing alone in an empty row.
                let x = (cursor - ThemedMenuMetrics.metricDividerGap
                    - ThemedMenuMetrics.metricDividerWidth).rounded()
                if !item.metrics.isEmpty, item.trailingDetail?.isEmpty == false {
                    (banded?.withAlphaComponent(ThemedMenuMetrics.metricTrackOpacity)
                        ?? ink(Design.Surface.divider, alpha)).setFill()
                    NSRect(
                        x: x,
                        y: centerY - height / 2,
                        width: ThemedMenuMetrics.metricDividerWidth,
                        height: height
                    ).fill()
                }
                cursor = x - ThemedMenuMetrics.metricDividerGap
            }
        }

        // Right-to-left over the reversed plan, so column order on screen stays left-to-right.
        for label in metricColumns.reversed() {
            let originX = cursor - metricColumnWidth
            defer { cursor = originX - ThemedMenuMetrics.metricColumnGap }
            guard let metric = item.metrics.first(where: { $0.label == label }) else { continue }

            (metric.label as NSString).draw(
                in: NSRect(x: originX, y: y, width: metricColumnWidth, height: height),
                withAttributes: [.font: font, .foregroundColor: muted]
            )

            let labelWidth = ceil(metric.label.size(withAttributes: [.font: font]).width)
            let barX = originX + labelWidth + ThemedMenuMetrics.metricInnerGap
            drawMetricBar(
                metric,
                in: NSRect(
                    x: barX,
                    y: centerY - ThemedMenuMetrics.metricBarHeight / 2,
                    width: ThemedMenuMetrics.metricBarWidth,
                    height: ThemedMenuMetrics.metricBarHeight
                ),
                fill: banded ?? metricBarFill(metric.tone, alpha: alpha),
                // `tertiary`, not `quaternary`. The fainter role is right for a ring drawn
                // *around* a glyph and wrong here: at 3pt on an elevated panel it disappeared,
                // and a fill with no visible track behind it reads as a coloured dash floating
                // in the row rather than as a part of a whole — which is the one thing a bar
                // says that the number beside it does not.
                track: banded?.withAlphaComponent(
                    ThemedMenuMetrics.metricTrackOpacity
                ) ?? ink(Design.Text.tertiary, alpha * ThemedMenuMetrics.metricTrackOpacity)
            )

            let valueX = barX + ThemedMenuMetrics.metricBarWidth
                + ThemedMenuMetrics.metricInnerGap
            draw(
                metric.value,
                rightAlignedIn: NSRect(
                    x: valueX,
                    y: y,
                    width: max(0, originX + metricColumnWidth - valueX),
                    height: height
                ),
                font: font,
                color: toned(metric.tone)
            )
        }

        return trailingEdge - cursor
    }

    /// A calm bar is the same ink as the number beside it, not the accent.
    ///
    /// The accent was tried first and is what the standalone `UsageBarView` uses, but in a menu
    /// it is wrong twice over. It breaks the rule the *values* already keep — calm is the absence
    /// of a signal, not a third colour — so a row would have said "nothing to see" in text and
    /// painted a saturated blue rod beside it. And the accent in this surface is already spoken
    /// for by the selection, so six of them down a menu argue with the one row the pointer is on.
    /// Neutral until it matters leaves the two orange and red bars as the only colour in the
    /// panel, which is the entire reason for drawing lengths at all.
    private func metricBarFill(
        _ tone: ThemedMenuSubtitleSegment.Tone,
        alpha: CGFloat
    ) -> NSColor {
        switch tone {
        case .standard, .muted: return ink(Design.Text.secondary, alpha)
        case .warning: return ink(Design.Status.warning, alpha)
        case .critical: return ink(Design.Status.negative, alpha)
        }
    }

    private func drawMetricBar(
        _ metric: ThemedMenuMetric,
        in rect: NSRect,
        fill: NSColor,
        track: NSColor
    ) {
        let radius = ThemedMenuMetrics.usesClassicGrammar ? 0 : rect.height / 2
        // The full track is always drawn, so a window with no readable number still reads as a
        // window rather than as a column this row forgot.
        track.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()

        guard let fraction = metric.fraction else { return }
        // Below the floor the fill is shorter than its own cap and draws as a dot at the track's
        // head; the floor is the honest picture of "barely touched". Same rule, same reason, as
        // `AccountMarkImage`'s meter.
        let visible = max(ThemedMenuMetrics.metricMinimumFraction, min(fraction, 1))
        fill.setFill()
        NSBezierPath(
            roundedRect: NSRect(
                x: rect.minX,
                y: rect.minY,
                width: max(rect.height, rect.width * CGFloat(visible)),
                height: rect.height
            ),
            xRadius: radius,
            yRadius: radius
        ).fill()
    }

    private func draw(
        _ text: String,
        rightAlignedIn rect: NSRect,
        font: NSFont,
        color: NSColor
    ) {
        let style = NSMutableParagraphStyle()
        style.alignment = .right
        style.lineBreakMode = .byClipping
        (text as NSString).draw(
            in: rect,
            withAttributes: [
                .font: font, .foregroundColor: color, .paragraphStyle: style
            ]
        )
    }

    /// The trailing accessory, drawn only where the row is current — under the pointer, or under
    /// the keyboard highlight so the right arrow is offering something visible.
    ///
    /// Three states, and the step between each is **ink only**: `secondary` where the row is
    /// merely current, `label` with the pointer on the glyph, and `label` dimmed while it is held
    /// down. That is the rule `ChipView` keeps, for the same reason — anything that changes a
    /// control's size or weight under the pointer moves the row while it is being aimed at — and
    /// the dim is the answer `ThemedButton` gives a press.
    ///
    /// A plate behind the glyph was drawn here first and was invisible: this only ever appears on
    /// a row that is already filled with `controlHover`, so the press painted the hover fill over
    /// itself. The render is what said so.
    ///
    /// Both inks arrive resolved, including the flattening a classic selection band does to
    /// everything drawn over it, so this cannot state a colour the rest of the row disagrees with.
    private func drawAccessory(label: NSColor, secondary: NSColor) {
        guard item.isEnabled,
              let accessory = item.accessory,
              // The pointer being on the glyph is the pointer being on the row; the third term
              // only matters to a fixture that sets one without the other.
              isKeyboardHighlighted || isHovered || isAccessoryHovered,
              let image = ThemedMenuIcon.accessorySymbol(accessory.symbolName)
        else { return }

        var tint = isAccessoryHovered || accessoryPressed ? label : secondary
        if accessoryPressed {
            // Resolve, then multiply: `withAlphaComponent` replaces an alpha outright, and every
            // label tier below `label` is defined *as* one.
            let resolved = tint.usingColorSpace(.sRGB) ?? tint
            tint = resolved.withAlphaComponent(
                resolved.alphaComponent * ThemedMenuMetrics.accessoryPressedDimming
            )
        }
        draw(image, in: accessoryRect, tint: tint)
    }

    private func drawShortcut(
        _ shortcut: KeyboardShortcut,
        in rect: NSRect,
        font: NSFont,
        color: NSColor
    ) {
        if ThemedMenuMetrics.usesAmigaCommandCap(shortcut) {
            // The Workbench manual does not spell "Amiga" in this column: it uses the black
            // Amiga-key cap followed by one Topaz character. Keep the cap as indexed geometry
            // so it remains exact even when the user's font override lacks a logo glyph.
            let key = KeyboardShortcut.keyDisplay(shortcut.key)
            let keyWidth = ceil(key.size(withAttributes: [.font: font]).width)
            let contentWidth = ThemedMenuMetrics.amigaCommandCapWidth
                + ThemedMenuMetrics.amigaCommandCapGap + keyWidth
            let cap = NSRect(
                x: rect.maxX - contentWidth,
                y: rect.midY - ThemedMenuMetrics.amigaCommandCapWidth / 2,
                width: ThemedMenuMetrics.amigaCommandCapWidth,
                height: ThemedMenuMetrics.amigaCommandCapWidth
            ).integral
            color.setFill()
            cap.fill()
            let capInk = ThemedMenuMetrics.panelFill
            ("A" as NSString).draw(
                in: NSRect(x: cap.minX + 2, y: cap.minY, width: 10, height: 13),
                withAttributes: [.font: font, .foregroundColor: capInk]
            )
            (key as NSString).draw(
                in: NSRect(x: cap.maxX + 2, y: rect.minY, width: rect.maxX - cap.maxX - 2, height: rect.height),
                withAttributes: [.font: font, .foregroundColor: color]
            )
            return
        }

        draw(
            ThemedMenuMetrics.shortcutText(shortcut),
            rightAlignedIn: rect,
            font: font,
            color: color
        )
    }

    private func draw(_ image: NSImage, in rect: NSRect, tint: NSColor) {
        TemplateImageDrawing.draw(image, in: rect, tint: tint)
    }

    private func drawCheckMark(in rect: NSRect, color: NSColor) {
        if ThemedMenuMetrics.usesClassicGrammar {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.shouldAntialias = false
            let path = NSBezierPath()
            path.move(to: NSPoint(x: rect.minX, y: rect.midY))
            path.line(to: NSPoint(x: rect.minX + rect.width * 0.36, y: rect.minY + 1))
            path.line(to: NSPoint(x: rect.maxX, y: rect.maxY - 1))
            path.lineWidth = 1.5
            path.lineCapStyle = .square
            path.lineJoinStyle = .miter
            color.setStroke()
            path.stroke()
            NSGraphicsContext.restoreGraphicsState()
            return
        }
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX, y: rect.midY))
        path.line(to: NSPoint(x: rect.minX + rect.width * 0.38, y: rect.minY))
        path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
        path.lineWidth = 1.5
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        color.setStroke()
        path.stroke()
    }

    /// The submenu chevron: `›`, drawn with the checkmark's own stroke so the two glyph
    /// columns read as one hand. Symmetric about the row's midline, so flip cannot skew it.
    private func drawChevron(in rect: NSRect, color: NSColor) {
        if ThemedMenuMetrics.usesClassicGrammar {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.shouldAntialias = false
            let triangle = NSBezierPath()
            triangle.move(to: NSPoint(x: rect.minX + 1, y: rect.minY))
            triangle.line(to: NSPoint(x: rect.maxX - 1, y: rect.midY))
            triangle.line(to: NSPoint(x: rect.minX + 1, y: rect.maxY))
            triangle.close()
            color.setFill()
            triangle.fill()
            NSGraphicsContext.restoreGraphicsState()
            return
        }
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX + rect.width * 0.3, y: rect.minY))
        path.line(to: NSPoint(x: rect.maxX - rect.width * 0.2, y: rect.midY))
        path.line(to: NSPoint(x: rect.minX + rect.width * 0.3, y: rect.maxY))
        path.lineWidth = 1.5
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        color.setStroke()
        path.stroke()
    }
}

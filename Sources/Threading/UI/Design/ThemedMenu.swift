import AppKit

/// A choice offered by a themed menu control.
///
/// Feature code describes meaning and state; `ThemedMenuPresenter` draws the complete dropdown
/// from app roles. Keeping presentation details out of this type means both `ChipView` and
/// `ThemedPopUp` share one visual and behavioral contract.
struct ThemedMenuItem {
    let title: String
    var subtitle: String?
    var image: NSImage?
    var preview: ThemedMenuPreview?
    var representedValue: Any?
    var isSelected: Bool
    var isEnabled: Bool
    var onChoose: (() -> Void)?
    /// Entries this item opens beside itself. A row carrying these draws a chevron and opens on
    /// hover, on ⌘-less right-arrow, and on press; choosing anywhere in the chain closes the
    /// whole menu. An item is a parent *or* an action — when both are set the action wins the
    /// press and only the arrow and hover reach the submenu, which reads as a defect, so don't.
    var submenu: [ThemedMenuEntry]?

    init(
        title: String,
        subtitle: String? = nil,
        image: NSImage? = nil,
        preview: ThemedMenuPreview? = nil,
        representedValue: Any? = nil,
        isSelected: Bool = false,
        isEnabled: Bool = true,
        onChoose: (() -> Void)? = nil,
        submenu: [ThemedMenuEntry]? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.image = image
        self.preview = preview
        self.representedValue = representedValue
        self.isSelected = isSelected
        self.isEnabled = isEnabled
        self.onChoose = onChoose
        self.submenu = submenu
    }
}

/// A live view standing in for a choice, so a menu of animations can be watched rather than
/// read one selection at a time.
///
/// An image would not do: what these rows are choosing between *is* movement, and a still of an
/// animation says only that there is one. The view is the caller's, made once and handed over,
/// which is also what keeps a preview honest — the working indicator's row draws the same
/// `WorkingOrbView` the conversation status draws, and a name transition's row the same
/// `MorphingTitleLabel` the sidebar morphs, rather than a second rendering of either.
struct ThemedMenuPreview {

    enum Placement {
        /// A fixed slot before the title, which still draws beside it.
        case leading
        /// The title's own place. The row draws no title of its own, because the preview *is*
        /// the name — which is the only way a text transition can be shown at all.
        case title
    }

    let placement: Placement
    let view: NSView

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
    var highlightChanged: ((Bool) -> Void)?
}

enum ThemedMenuEntry {
    case item(ThemedMenuItem)
    case separator
}

/// The semantic payload handed to menu-presentation test seams.
struct ThemedMenuPresentation {
    let entries: [ThemedMenuEntry]
    let minimumWidth: CGFloat
}

// MARK: - Presentation

/// Where an open menu hangs from.
///
/// A dropdown belongs to the control that opened it and lines up under that control's edge. A
/// menu opened by a secondary click belongs to the *pointer*: anchoring one to its whole view
/// instead puts it in the same place wherever inside the view the click landed, which reads as
/// the menu ignoring the click that asked for it.
enum ThemedMenuAnchor {
    /// Under — or over, where there is no room — the control that opened it, aligned to its
    /// leading edge.
    case control
    /// One corner on a point given in window coordinates: the secondary-click idiom.
    case pointer(NSPoint)
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
/// The returned object is an opaque retention token. A control holds it for as long as the menu
/// is open and releases it from `onDismiss`; callers never depend on the implementation class.
@MainActor
enum ThemedMenuPresenter {

    @discardableResult
    static func present(
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

    static func dismiss(_ token: AnyObject?) {
        (token as? ThemedMenuSession)?.close()
    }

    /// Whether a dropdown is up in `window` right now.
    ///
    /// A dropdown is a view rather than a window, so nothing about the window itself says one
    /// is open — and `ThemedPopover`, which would draw over it, has to ask. Counted per open
    /// session rather than read off the view tree, so a menu still fading out is already gone.
    static func isMenuOpen(in window: NSWindow) -> Bool {
        ThemedMenuSession.open.allObjects.contains { $0.window === window }
    }

    /// The press-drag-release idiom: the button went down on the source control and is still
    /// down while the pointer moves over the open menu. The source forwards its drag here so
    /// rows highlight under the pointer, exactly as a held `NSMenu` tracks.
    static func dragUpdated(_ token: AnyObject?, event: NSEvent) {
        (token as? ThemedMenuSession)?.dragUpdated(event)
    }

    /// The held press ends. Over an enabled row it chooses; back over the source it goes
    /// sticky (the ordinary click-then-browse open); anywhere else it lets the menu go.
    static func dragEnded(_ token: AnyObject?, event: NSEvent) {
        (token as? ThemedMenuSession)?.dragEnded(event)
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
protocol ThemedMenuOpening: NSView {
    /// Whether a press would open this control's menu right now — enabled, and for controls
    /// that carry both gestures, configured to present one.
    var opensMenuOnPress: Bool { get }
}

// Gathered here rather than spread across the adopters: who may take the handoff is the
// presenter's contract, and one place states the whole roster.
extension ChipView: ThemedMenuOpening {
    var opensMenuOnPress: Bool { isEnabled }
}

extension ThemedPopUp: ThemedMenuOpening {
    var opensMenuOnPress: Bool { isEnabled }
}

extension ThemedIconButton: ThemedMenuOpening {
    var opensMenuOnPress: Bool { presentsMenu && isEnabled }
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
    var item: ThemedMenuItem? {
        if case .item(let item) = self { return item }
        return nil
    }

    var isItem: Bool { item != nil }
}

// MARK: - Geometry

enum ThemedMenuLayout {
    static let gap: CGFloat = Design.Spacing.tight
    static let screenInset: CGFloat = Design.Spacing.small
    /// The tallest panel a window may carry — a share of the window rather than a flat number.
    /// The cap was a flat 360, set when the longest menu was half its eventual size; by the
    /// time the session row's menu had grown, it overflowed that cap in every ordinarily sized
    /// window, which made scrolling the *normal* state and put Delete Session below the fold
    /// on every right-click. A menu's ceiling is the window it serves: a tall window shows the
    /// whole list, and the floor keeps a cramped window exactly where the flat cap left it.
    static let maximumHeightRatio: CGFloat = 0.75
    static let maximumHeightFloor: CGFloat = 360
    static let maximumWidth: CGFloat = 440

    static func maximumHeight(in bounds: NSRect) -> CGFloat {
        max(maximumHeightFloor, bounds.height * maximumHeightRatio)
    }

    /// `whenClipped` is given the clamped height and answers with the one to use, which is how
    /// a panel that cannot show every row ends on half a row instead of on a clean edge. It is
    /// passed in rather than read from the entries so this stays plain geometry a test can call;
    /// `ThemedMenuMetrics.clippedHeight(for:atMost:)` is what every caller hands it.
    static func frame(
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
        let clamped = min(desiredSize.height, maximumHeight(in: bounds), available)
        let height = clamped < desiredSize.height ? whenClipped(clamped) : clamped

        let y: CGFloat
        if flipped {
            y = opensAfter ? anchor.maxY + gap : anchor.minY - gap - height
        } else {
            y = opensAfter ? anchor.minY - gap - height : anchor.maxY + gap
        }
        return NSRect(x: x, y: y, width: width, height: height)
    }

    /// How far a submenu tucks under its parent panel's edge. Panels that merely touched read
    /// as two unrelated windows; the platform's own submenus overlap for the same reason.
    static let submenuOverlap: CGFloat = gap

    /// Where a submenu panel lands: beside its parent panel, its first row level with the row
    /// that opened it. To the right until there is no room, then mirrored to the left; clamped
    /// vertically the way the root panel is.
    ///
    /// `firstRowInset` is the panel's own padding above its first row
    /// (`ThemedMenuMetrics.outerInset`), passed in so this stays plain geometry a test can call.
    static func submenuFrame(
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

    /// The sessions currently up, which is how `ThemedMenuPresenter.isMenuOpen(in:)` answers
    /// for a window. Weak, and dropped in `finish`, so the roster ends where the session does
    /// rather than where its exit animation does. Held per session rather than per window
    /// because a menu can be let go and a sibling's opened by the same click.
    static let open = NSHashTable<ThemedMenuSession>.weakObjects()

    private weak var source: NSView?
    fileprivate weak var window: NSWindow?
    private let overlay: ThemedMenuOverlayView
    private let onChoose: (Int, ThemedMenuItem) -> Void
    private let onDismiss: () -> Void
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
        self.onChoose = onChoose
        self.onDismiss = onDismiss

        let menuWidth = ThemedMenuMetrics.width(
            for: presentation.entries,
            minimum: presentation.minimumWidth
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
        overlay.menuSource = source
        overlay.onDismiss = { [weak self] in self?.closeFromUser() }
        overlay.onChoose = { [weak self] index, item in self?.choose(index: index, item: item) }
        overlay.autoresizingMask = [.width, .height]
        root.addSubview(overlay, positioned: .above, relativeTo: nil)
        // The surface is constructed before the overlay joins the source's view tree. A
        // window-local appearance (the gallery's Light/Dark preview) may therefore differ from
        // the app appearance under which its layer-backed fill first resolved. Re-resolve once
        // attached so menu fill, rows, and text all use the source window's appearance.
        AppThemeRefresh.repaint(overlay)
        window.makeFirstResponder(overlay)
        overlay.animateIn()

        for name in [
            NSWindow.didResignKeyNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didResizeNotification
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
        overlay.pointerHighlight(atWindowPoint: event.locationInWindow)
    }

    func dragEnded(_ event: NSEvent) {
        guard !isClosed else { return }
        let point = event.locationInWindow
        if let source, source.bounds.contains(source.convert(point, from: nil)) {
            // Released back on the control: the plain click-to-open. The menu stays for
            // browsing, which is the other half of how platform menus track a press.
            return
        }
        switch overlay.dragTarget(atWindowPoint: point) {
        case .row(let index, let item):
            choose(index: index, item: item)
        case .surface:
            break
        case .outside:
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
        Self.open.remove(self)
        NotificationCenter.default.removeObserver(self)
        if let window, window.firstResponder === overlay, let source {
            window.makeFirstResponder(source)
        }
        overlay.tearDown(exit: exit)
        onDismiss()
    }
}

/// How a closing menu leaves the screen. Every path has already ended the session; this only
/// names the pixels' exit.
enum ThemedMenuExit {
    case instant
    case fade
    /// The classic confirmation blink: the chosen row flickers once, then the panel fades.
    case confirm(Int)
}

// MARK: - Overlay

private final class ThemedMenuOverlayView: ThemedControl {

    var onChoose: ((Int, ThemedMenuItem) -> Void)?
    var onDismiss: (() -> Void)?

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
        guard duration > 0, let layer = host.layer else { return }

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
            column.surface.setAccessibilityRole(nil)
        }

        let duration = Design.Motion.vanish
        let fadeOut: @MainActor @Sendable () -> Void = {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = Design.Motion.vanish
                self.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                Task { @MainActor in
                    self?.removeFromSuperview()
                }
            })
        }

        switch exit {
        case .instant:
            removeFromSuperview()
        case .fade where duration <= 0, .confirm where duration <= 0:
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
                if row.item.submenu != nil, row.item.onChoose == nil {
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
        if row.item.isEnabled, row.item.submenu != nil, row.item.onChoose == nil {
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
        if item.submenu != nil, item.onChoose == nil {
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
            firstRowInset: ThemedMenuMetrics.outerInset,
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
            column.surface.setAccessibilityRole(nil)
            let host = column.host
            let duration = Design.Motion.vanish
            if case .instant = exit {
                host.removeFromSuperview()
            } else if duration <= 0 {
                host.removeFromSuperview()
            } else {
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = Design.Motion.vanish
                    host.animator().alphaValue = 0
                }, completionHandler: {
                    Task { @MainActor in host.removeFromSuperview() }
                })
            }
        }
    }

    /// Right arrow: the highlighted parent row opens, with its first row lit — keyboard
    /// travel always says where it landed.
    private func openSubmenuFromKeyboard() {
        let columnIndex = columns.count - 1
        guard columnIndex >= 0,
              let highlighted = columns[columnIndex].highlightedIndex
        else { return }
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
enum ThemedMenuMetrics {
    /// Between the panel's edge and its rows, so a highlighted row's capsule floats inside
    /// the panel instead of grazing its border.
    static let outerInset: CGFloat = Design.Spacing.small
    static let rowHeight: CGFloat = 28
    /// Taller than the ink it holds, and deliberately so: a title and its subtitle are drawn as
    /// one centred block, so everything above this beyond that block becomes the gap to the row
    /// stacked against it. At 42 the two gaps came out ~18pt within a pair against ~24pt between
    /// them and the pairs did not read as pairs; 46 buys a little over 2:1, which is the point at
    /// which proximity does the grouping on its own — no rules, no alternating fill, both of
    /// which would have fought the hover pill this row draws at full bleed.
    static let subtitleRowHeight: CGFloat = 46
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
    static let fillInset: CGFloat = Design.Spacing.hairline / 2
    /// A separator's slot. Sized so the gap it opens between two rows' text reads as the
    /// ordinary inter-row rhythm plus the rule — at the old 9pt the rule crowded whichever
    /// row's fill it sat against and the spacing read as unequal.
    static let separatorHeight: CGFloat = 13
    /// The strip across the top echoing what has been typed while the menu is open.
    static let filterHeaderHeight: CGFloat = 22
    /// How far a filtered-out row's ink drops. Dimmed rather than hidden, so the menu keeps
    /// its shape while the user types and nothing moves under the pointer.
    static let filteredOutDimming: CGFloat = 0.4
    /// A row that cannot be chosen at all.
    static let disabledDimming: CGFloat = 0.45
    /// The wash a *disabled* row shows under the pointer — feedback that the hover was
    /// seen, well short of the fill that says "choosable".
    static let disabledHoverWash: CGFloat = 0.4
    /// A row's own leading and trailing padding — also where the checkmark sits, which was
    /// previously drawn 4pt from the row's edge and read as pinned to the panel's side.
    static let contentInset: CGFloat = Design.Spacing.medium
    static let checkSize: CGFloat = 10
    /// The checkmark column: glyph plus the gap to whatever follows it.
    static let leadingSlot: CGFloat = checkSize + Design.Spacing.small
    static let imageSize: CGFloat = 14
    static let imageSlot: CGFloat = 18
    /// A live preview's column. The orb is the widest thing that goes in it and states its own
    /// 20pt footprint, so the slot is that plus the gap to whatever follows — the same shape as
    /// the image column one size up, rather than a second guess at it.
    static let previewSize: CGFloat = 20
    static let previewSlot: CGFloat = previewSize + Design.Spacing.tight

    /// The chevron marking a row that opens a submenu, and the column it sits in — trailing,
    /// where the platform's own submenu arrow lives.
    static let submenuChevronSize: CGFloat = 8
    static let submenuChevronSlot: CGFloat = submenuChevronSize + Design.Spacing.small

    /// The image column is reserved only when some item actually carries an image. Reserving
    /// it always left an 18pt hole between checkmark and title in every icon-less menu.
    static func hasImageColumn(_ entries: [ThemedMenuEntry]) -> Bool {
        entries.contains { entry in
            guard case .item(let item) = entry else { return false }
            return item.image != nil
        }
    }

    /// Reserved on the image column's terms: only when some row actually opens a submenu, so a
    /// menu of plain actions keeps its trailing edge tight against the longest title.
    static func hasSubmenuColumn(_ entries: [ThemedMenuEntry]) -> Bool {
        entries.contains { entry in
            guard case .item(let item) = entry else { return false }
            return item.submenu != nil
        }
    }

    /// Reserved on the same terms as the image column, and only for a preview that sits *beside*
    /// a title — one placed in the title's own slot occupies a column that already exists.
    static func hasPreviewColumn(_ entries: [ThemedMenuEntry]) -> Bool {
        entries.contains { entry in
            guard case .item(let item) = entry else { return false }
            return item.preview?.placement == .leading
        }
    }

    /// Where a row's content begins, per column, so a *drawn* title and a *hosted* preview land
    /// in the same place. A preview replaces the text rather than joining it, and a column of
    /// names that shifted sideways when one of them animated would read as a layout bug in the
    /// menu rather than as the transition it is demonstrating.
    static var imageInset: CGFloat { contentInset + leadingSlot }

    static func previewInset(hasImageColumn: Bool) -> CGFloat {
        imageInset + (hasImageColumn ? imageSlot : 0)
    }

    static func titleInset(hasImageColumn: Bool, hasPreviewColumn: Bool) -> CGFloat {
        previewInset(hasImageColumn: hasImageColumn) + (hasPreviewColumn ? previewSlot : 0)
    }

    static func height(of entry: ThemedMenuEntry) -> CGFloat {
        switch entry {
        case .separator:
            return separatorHeight
        case .item(let item):
            return item.subtitle?.isEmpty == false ? subtitleRowHeight : rowHeight
        }
    }

    static func height(for entries: [ThemedMenuEntry]) -> CGFloat {
        entries.reduce(outerInset * 2) { $0 + height(of: $1) }
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
    static func clippedHeight(for entries: [ThemedMenuEntry], atMost limit: CGFloat) -> CGFloat {
        let budget = limit - outerInset * 2
        var consumed: CGFloat = 0
        var peeked: CGFloat?

        for entry in entries {
            let height = height(of: entry)
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
        return peeked + outerInset * 2
    }

    static func width(for entries: [ThemedMenuEntry], minimum: CGFloat) -> CGFloat {
        let text = entries.compactMap { entry -> CGFloat? in
            guard case .item(let item) = entry else { return nil }
            let title = ceil(item.title.size(
                withAttributes: [.font: Design.Typography.control()]
            ).width)
            let subtitle = ceil((item.subtitle ?? "").size(
                withAttributes: [.font: Design.Typography.detail()]
            ).width)
            return max(title, subtitle)
        }.max() ?? 0

        let imageColumn = hasImageColumn(entries) ? imageSlot : 0
        let previewColumn = hasPreviewColumn(entries) ? previewSlot : 0
        let chevronColumn = hasSubmenuColumn(entries) ? submenuChevronSlot : 0
        let content = outerInset * 2 + contentInset * 2
            + leadingSlot + imageColumn + previewColumn + text + chevronColumn
        return min(max(minimum, content), ThemedMenuLayout.maximumWidth)
    }
}

/// How the menu moves. File-local because no other surface animates this way yet; a second
/// one promotes these to `Design`.
enum ThemedMenuMotion {
    static let appearScale: CGFloat = 0.97
    static let appearAnimationKey = "threading.menu.appear"
    static let shadowOpacity: Float = 0.28
    static let shadowRadius: CGFloat = 16

    /// How long the pointer rests on a parent row before its submenu opens. Short enough to
    /// feel attached to the hover, long enough that sweeping down a menu does not fan panels
    /// out of every parent row on the way past.
    static let submenuOpenDelay: TimeInterval = 0.16
    /// How long an open submenu survives the pointer leaving its row for a sibling. This is
    /// the recovery window for an overshoot; the safe-travel corridor below covers the
    /// deliberate diagonal.
    static let submenuCloseGrace: TimeInterval = 0.28
    /// How long a pointer may sit still inside the safe-travel corridor before the row it is
    /// actually on wins. Without a deadline, parking the pointer between panels would pin the
    /// menu to a highlight it has visibly left.
    static let safeTravelStall: TimeInterval = 0.35
    /// How far the pointer must actually travel, after a panel has scrolled under it, before
    /// hover may claim the highlight again. Scrolling hands `mouseEntered` to whichever row
    /// slides under a stationary pointer; the tolerance is hysteresis for a physical mouse
    /// nudged while its wheel turns, not an allowance for deliberate movement.
    static let scrollHoverTolerance: CGFloat = 4
}

private final class ThemedMenuSurfaceView: NSView, ThemedComponent {

    var onChoose: ((Int, ThemedMenuItem) -> Void)?
    var onHighlight: ((Int) -> Void)?
    /// The panel scrolled under its rows — what tells an open submenu its anchor moved.
    var onScrolled: (() -> Void)?

    let selectableIndices: [Int]

    private let scrollView = ThemedScrollView()
    private let document: ThemedMenuDocumentView
    private let rows: [Int: ThemedMenuRowView]
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
        let hasImageColumn = ThemedMenuMetrics.hasImageColumn(entries)
        let hasPreviewColumn = ThemedMenuMetrics.hasPreviewColumn(entries)
        let hasSubmenuColumn = ThemedMenuMetrics.hasSubmenuColumn(entries)

        for (index, entry) in entries.enumerated() {
            switch entry {
            case .separator:
                views.append(ThemedMenuSeparatorView())
            case .item(let item):
                let row = ThemedMenuRowView(
                    entryIndex: index,
                    item: item,
                    isSelected: item.isSelected || index == selectedEntryIndex,
                    hasImageColumn: hasImageColumn,
                    hasPreviewColumn: hasPreviewColumn,
                    hasSubmenuColumn: hasSubmenuColumn
                )
                madeRows[index] = row
                views.append(row)
                if item.isEnabled { selectable.append(index) }
            }
        }

        rows = madeRows
        selectableIndices = selectable
        document = ThemedMenuDocumentView(views: views)
        super.init(frame: frame)

        applySurface(
            fill: Design.Surface.elevated,
            radius: .panel,
            border: Design.Surface.border,
            glow: true
        )

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller =
            document.naturalHeight > frame.height - ThemedMenuMetrics.outerInset * 2
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
        }
        setAccessibilityRole(.menu)

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

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let inset = ThemedMenuMetrics.outerInset
        var content = bounds.insetBy(dx: inset, dy: inset)
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

private final class ThemedMenuDocumentView: NSView {

    let naturalHeight: CGFloat
    private let views: [NSView]

    override var isFlipped: Bool { true }

    init(views: [NSView]) {
        self.views = views
        naturalHeight = views.reduce(0) { total, view in
            total + ((view as? ThemedMenuRowView)?.preferredHeight
                ?? ThemedMenuMetrics.separatorHeight)
        }
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
        for view in views {
            let height = (view as? ThemedMenuRowView)?.preferredHeight
                ?? ThemedMenuMetrics.separatorHeight
            view.frame = NSRect(x: 0, y: y, width: bounds.width, height: height)
            y += height
        }
    }
}

private final class ThemedMenuSeparatorView: NSView, ThemedComponent {
    override func draw(_ dirtyRect: NSRect) {
        let height = Design.Radius.border
        // Inset to the rows' own content padding, so the rule reads as part of the column
        // of text it divides rather than a wall-to-wall strut.
        let rect = NSRect(
            x: ThemedMenuMetrics.contentInset,
            y: bounds.midY - height / 2,
            width: max(0, bounds.width - ThemedMenuMetrics.contentInset * 2),
            height: height
        )
        Design.Surface.divider.setFill()
        rect.fill()
    }
}

// MARK: - Row

private final class ThemedMenuRowView: ThemedControl {

    let entryIndex: Int
    let item: ThemedMenuItem
    let preferredHeight: CGFloat

    var onChoose: ((Int, ThemedMenuItem) -> Void)?
    var onHighlight: ((Int) -> Void)?
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
    private let hasImageColumn: Bool
    private let hasPreviewColumn: Bool
    private let hasSubmenuColumn: Bool
    private var pressed = false { didSet { needsDisplay = true } }
    /// The pointer is on a row that cannot be chosen. It answers with a wash far fainter
    /// than the hover fill — feedback that the hover was seen, not an invitation.
    private var isDisabledHover = false { didSet { needsDisplay = true } }

    /// The open panel this row fathered, while it is open. It keeps the row drawing the
    /// menu-path highlight — the parent stays lit wherever the pointer is in its chain, as
    /// the platform's own menus stay lit — and it is what accessibility descends into.
    private(set) weak var openSubmenuSurface: NSView?

    /// A preview in the title's slot is the row's name, so the row draws no text of its own.
    private var drawsTitle: Bool { item.preview?.placement != .title }

    init(
        entryIndex: Int,
        item: ThemedMenuItem,
        isSelected: Bool,
        hasImageColumn: Bool,
        hasPreviewColumn: Bool,
        hasSubmenuColumn: Bool
    ) {
        self.entryIndex = entryIndex
        self.item = item
        selected = isSelected
        self.hasImageColumn = hasImageColumn
        self.hasPreviewColumn = hasPreviewColumn
        self.hasSubmenuColumn = hasSubmenuColumn
        preferredHeight = item.subtitle?.isEmpty == false
            ? ThemedMenuMetrics.subtitleRowHeight
            : ThemedMenuMetrics.rowHeight
        super.init(frame: .zero)
        toolTip = item.subtitle
        installPreview()
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
            NSLayoutConstraint.activate([
                preview.view.leadingAnchor.constraint(
                    equalTo: leadingAnchor,
                    constant: ThemedMenuMetrics.previewInset(hasImageColumn: hasImageColumn)
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
        guard item.isEnabled else { return }
        pressed = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard item.isEnabled else { return }
        pressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
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

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .menuItem }
    override func accessibilityTitle() -> String? { item.title }
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
        let fillRect = bounds.insetBy(dx: 0, dy: ThemedMenuMetrics.fillInset)

        // **A checked row is not a filled row.** The check states what is on; the fill states
        // where the pointer or the keyboard is, and only one row can be that at a time. Painting
        // both meant a menu of toggles came up three-quarters filled before it had been touched —
        // and the role it filled with, `selection`, is the ground behind selected *text*: at
        // Win98's near-opaque navy or the System theme's accent it read as three highlighted rows
        // fighting the one the pointer was actually on.
        //
        // The open-submenu fill is the menu path: the parent stays lit while the pointer is
        // anywhere in the chain it opened, which is what keeps a three-panel menu readable.
        if isKeyboardHighlighted || pressed || openSubmenuSurface != nil {
            ThemedSurface.draw(
                fillRect,
                fill: Design.Surface.controlHover,
                radius: Design.Radius.control
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
                radius: Design.Radius.control
            )
        }

        let alpha = contentAlpha
        let label = ink(Design.Text.label, alpha)
        // `secondary` rather than `tertiary`, deliberately. A subtitle here is not decoration —
        // it is the sentence that says what a permission mode will *do* — and rendered against
        // these titles `tertiary` read as disabled rather than as support. The separation the
        // pair was missing comes from `ink` no longer flattening this role to opaque black, and
        // from the rhythm, not from taking the copy down another tier.
        let secondary = ink(Design.Text.secondary, alpha)

        if selected {
            drawCheckMark(
                in: NSRect(
                    x: ThemedMenuMetrics.contentInset,
                    y: bounds.midY - ThemedMenuMetrics.checkSize / 2,
                    width: ThemedMenuMetrics.checkSize,
                    height: ThemedMenuMetrics.checkSize
                ),
                color: label
            )
        }

        if hasImageColumn, let image = item.image {
            let imageRect = NSRect(
                x: ThemedMenuMetrics.imageInset,
                y: bounds.midY - ThemedMenuMetrics.imageSize / 2,
                width: ThemedMenuMetrics.imageSize,
                height: ThemedMenuMetrics.imageSize
            )
            draw(image, in: imageRect, tint: label)
        }

        if item.submenu != nil {
            drawChevron(
                in: NSRect(
                    x: bounds.maxX - ThemedMenuMetrics.contentInset
                        - ThemedMenuMetrics.submenuChevronSize,
                    y: bounds.midY - ThemedMenuMetrics.submenuChevronSize / 2,
                    width: ThemedMenuMetrics.submenuChevronSize,
                    height: ThemedMenuMetrics.submenuChevronSize
                ),
                color: label
            )
        }

        guard drawsTitle else { return }

        let x = ThemedMenuMetrics.titleInset(
            hasImageColumn: hasImageColumn,
            hasPreviewColumn: hasPreviewColumn
        )
        let titleFont = Design.Typography.control()
        let titleHeight = ceil(titleFont.boundingRectForFont.height)
        let subtitleFont = Design.Typography.detail()
        let subtitleHeight = ceil(subtitleFont.boundingRectForFont.height)
        let hasSubtitle = item.subtitle?.isEmpty == false
        // The two lines are placed as **one block, centred** — not each against `midY`
        // separately, which is what this did before. Independently, they sat 4pt apart inside a
        // row whose neighbours it touches edge to edge, so the gap to the *next row's* title came
        // out barely wider than the gap to a title's own subtitle: ~18pt against ~24pt. At that
        // ratio proximity states nothing and the menu reads as one evenly stacked column of
        // alternating weights rather than as pairs.
        //
        // Stacked flush, because `boundingRectForFont.height` already carries the font's internal
        // leading — the gap between the lines is inside the boxes, and adding another one on top
        // is what re-opens the problem. Centring the block pools the row's remaining space at its
        // two edges, where it separates rows, instead of splitting it around the text.
        let blockBottom = bounds.midY - (titleHeight + subtitleHeight) / 2
        let titleY = hasSubtitle
            ? blockBottom + subtitleHeight
            : bounds.midY - titleHeight / 2
        let chevronColumn = hasSubmenuColumn ? ThemedMenuMetrics.submenuChevronSlot : 0
        let textWidth = max(
            0,
            bounds.maxX - ThemedMenuMetrics.contentInset - chevronColumn - x
        )
        (item.title as NSString).draw(
            in: NSRect(x: x, y: titleY, width: textWidth, height: titleHeight),
            withAttributes: [.font: titleFont, .foregroundColor: label]
        )

        if let subtitle = item.subtitle, !subtitle.isEmpty {
            (subtitle as NSString).draw(
                in: NSRect(
                    x: x,
                    y: blockBottom,
                    width: textWidth,
                    height: subtitleHeight
                ),
                withAttributes: [.font: subtitleFont, .foregroundColor: secondary]
            )
        }
    }

    private func draw(_ image: NSImage, in rect: NSRect, tint: NSColor) {
        TemplateImageDrawing.draw(image, in: rect, tint: tint)
    }

    private func drawCheckMark(in rect: NSRect, color: NSColor) {
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

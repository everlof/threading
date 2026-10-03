import AppKit

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
    // Open submenus are children of their owning rows, not duplicate roots in this overlay.
    override func accessibilityChildren() -> [Any]? { columns.prefix(1).map(\.surface) }
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
        // The shortcut printed beside a row is the same route as choosing that row. The menu's
        // window-local monitor owns every key-down while it is open, so leaving the chord as
        // decoration would swallow the application command and leave the menu standing. Search
        // the panels that are actually on screen, deepest first, before ordinary navigation.
        if chooseShortcut(matching: event) { return }

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

    /// Chooses the enabled visible row whose printed shortcut matches `event`.
    private func chooseShortcut(matching event: NSEvent) -> Bool {
        for column in columns.reversed() {
            guard let row = column.surface.row(matchingShortcut: event) else { continue }
            return row.performPrimaryAction()
        }
        return false
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
        let rowPlan = ThemedMenuRowPlan(entries: entries, selectedEntryIndex: selectedEntryIndex)

        for (index, entry) in entries.enumerated() {
            switch entry {
            case .separator:
                views.append(ThemedMenuSeparatorView())
            case .header(let title):
                views.append(ThemedMenuHeaderView(title: title))
            case .item(let item):
                guard let row = rowPlan.row(at: index) else { continue }
                madeRows[index] = row
                views.append(row)
                if item.isEnabled { selectable.append(index) }
            }
        }

        rows = madeRows
        selectableIndices = selectable
        document = ThemedMenuDocumentView(views: views, heights: rowPlan.heights)
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
    override func isAccessibilityElement() -> Bool { !isRetiredFromAccessibility }

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

    /// The enabled row whose shortcut is `event`, in stable menu order. A dictionary walk here
    /// would make duplicate chords choose nondeterministically; menu order is the tie-breaker a
    /// person can see.
    func row(matchingShortcut event: NSEvent) -> ThemedMenuRowView? {
        for index in selectableIndices {
            guard let row = rows[index], row.item.resolvedShortcut?.matches(event) == true else {
                continue
            }
            return row
        }
        return nil
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

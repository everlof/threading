import AppKit

/// What the pointer can reach while a surface covers a window's content.
///
/// A dropdown here is a **view over the window** rather than a window of its own — see
/// `ThemedMenuPresenter` for why — and a view has no pointer boundary. A window's does not stop
/// at what is drawn in front of it: three separate AppKit mechanisms carry the pointer to the
/// content beneath an overlay, and none of them looks at z-order.
///
/// - **Cursor rectangles** are the window's list. The split view's seam kept offering its `↔`
///   inside an open menu; `CoveredWindowCursor` turns the list off and is folded in here.
/// - **Tracking areas** report crossings of a *rectangle*: `mouseEntered` reaches every view
///   whose area the pointer entered, whichever one a click would land on. That is how a chip
///   under an open menu lit as hovered while the pointer was on a menu row two rows away.
/// - **Mouse-moved delivery** — a tracking area's `.mouseMoved`, and `cursorUpdate` — hands
///   position to whatever registered for it. `NSTextView` sets its I-beam from both, measured
///   (`-[NSTextView mouseMoved:]` and `-[NSTextView cursorUpdate:]` both end in `_mouseInside:`),
///   which is how the composer's editor turned the pointer into an I-beam over the rows above it.
///
/// While a surface holds a claim on a window:
///
/// - **Arrivals beneath the surface are withheld** at a local event monitor: `mouseEntered` and
///   `cursorUpdate` whose tracking area belongs to a view neither inside the surface nor above it
///   never reach their owner. **Leavings always pass.** A hover that never ends is the failure
///   that shows, and it is not the one this exists to stop — the same rule `NSView.hoverIsStale`
///   states for the whole app.
/// - **A withheld arrival is owed, not dropped.** AppKit's own book says the pointer is *inside*
///   that area — it generated the crossing — so it will not say so again until the pointer leaves
///   and comes back. On release, every withheld arrival whose area the pointer is still inside is
///   delivered then, so the control the pointer rests on when a menu closes lights exactly as it
///   would have had the menu been a window. AppKit's own tracking manager carries the same idea
///   by its symbol names — `installMenuTrackingObserver`, `menuTrackingTrackingAreaEvent:
///   delayedArray:` — for the menus it draws itself. A nested surface re-asks: an arrival still
///   beneath another live claim moves to it.
/// - **The pointer is the arrow over the surface.** `mouseMoved` cannot be withheld — the manager
///   that computes every crossing in the window, the menu's own rows included, does so *inside*
///   the window's handling of that event (measured: `_NSTrackingAreaAKManager _mouseMoved:` runs
///   as a window mouse-moved listener) — so `NSTextView` beneath still hears the pointer move and
///   still sets its I-beam. The application therefore re-asserts the arrow after each pointer
///   event it dispatches to a claimed window (`applicationDidDispatch`). `NSCursor.set` defers
///   the window-server call to the display cycle, so the two sets in one dispatch coalesce and
///   nothing flickers.
///
/// **What this cannot do, and the rule that follows.** A view that reads hover off `mouseMoved`
/// rather than off a crossing — the split view's seam, the diff's line actions, the minimap's
/// fisheye, the chart's crosshair — is still told the pointer's position under an open menu, for
/// the reason above. Every such override reads its position through
/// `NSView.uncoveredPointerLocation(in:)`, and `scripts/check_architecture_boundaries.sh` fails
/// the build on one that does not. A hover that starts on `mouseEntered` needs nothing: the
/// surface withholds the arrival for it.
///
/// **The crossings half is every covering surface's; the cursor half is a policy the surface
/// states.** A dropdown covers the whole content view and nothing inside it wants a cursor other
/// than the arrow, so it claims `.arrow`: the window's cursor rectangles go off and the arrow is
/// re-asserted. A modal on an `InWindowOverlay` scrim has fields and drag handles of its own
/// registered in the same window's list, so it claims `.surfaceOwned`: only the crossings
/// beneath it are withheld, and its cursor is left to its own content — see
/// `CoveredWindowCursor` for the half of that problem that is still open, and
/// [`design-system.md`](../../../../docs/architecture/design-system.md) for why it needs a
/// different answer rather than the arrow policy applied more widely.
@MainActor
enum CoveredWindowPointer {

    /// What the pointer looks like over a claiming surface.
    enum CursorPolicy: Equatable {
        /// The surface shows nothing but the arrow — a dropdown. The window's cursor rectangles
        /// stop answering for as long as the claim holds, and the arrow is put back after every
        /// pointer event dispatched to the window while the pointer is over the surface.
        case arrow
        /// The surface's own content answers for the cursor over it — a modal whose search field
        /// wants its I-beam and whose handles want their arrows. Nothing about the cursor changes;
        /// only the crossings beneath are withheld. A listener beneath that sets its cursor from
        /// `mouseMoved` still speaks under such a surface (the open half on `CoveredWindowCursor`).
        case surfaceOwned
    }

    // MARK: - Bookkeeping

    /// One surface holding one window's pointer, and the arrivals it is holding back.
    ///
    /// A class rather than a struct because the owed arrivals accrue over the claim's life, and
    /// a value copied out of the array would accrue them somewhere nothing reads.
    @MainActor
    private final class Claim {
        weak var surface: NSView?
        weak var window: NSWindow?
        let cursor: CursorPolicy
        private(set) var owed: [OwedArrival] = []

        init(surface: NSView, window: NSWindow, cursor: CursorPolicy) {
            self.surface = surface
            self.window = window
            self.cursor = cursor
        }

        /// A claim counts for as long as its surface is still in the window it covered — the
        /// same backstop `CoveredWindowCursor` keeps, for the same reason: a surface that left
        /// without releasing must stop holding the window's pointer, not hold it forever.
        var isLive: Bool {
            guard let surface, let window else { return false }
            return surface.window === window
        }

        /// One arrival per area and kind: the latest crossing is the one that describes where
        /// the pointer is, and delivering an older one as well would light a view twice.
        func owe(_ arrival: OwedArrival) {
            owed.removeAll { $0.area === arrival.area && $0.kind == arrival.kind }
            owed.append(arrival)
        }

        /// The pointer left `area`: whatever arrival was owed for it is no longer true.
        func forget(_ area: NSTrackingArea) {
            owed.removeAll { $0.area === area }
        }

        func takeOwed() -> [OwedArrival] {
            defer { owed.removeAll() }
            return owed
        }
    }

    /// The kind of arrival a tracking area reported — the two AppKit generates for a rectangle
    /// the pointer entered.
    enum ArrivalKind: Equatable {
        case entered
        case cursorUpdate

        init?(_ type: NSEvent.EventType) {
            switch type {
            case .mouseEntered: self = .entered
            case .cursorUpdate: self = .cursorUpdate
            default: return nil
            }
        }
    }

    /// An arrival AppKit generated and this file held back, to be delivered when the surface
    /// over it goes.
    ///
    /// Weak on the area because a recycled row's tracking area is the row's to drop, and an
    /// arrival owed to a rectangle that no longer exists is owed to nobody. The event is the one
    /// AppKit built, kept whole: it is the object the owner would have received, tracking area
    /// and all, and no public initializer can build another like it.
    @MainActor
    struct OwedArrival {
        weak var area: NSTrackingArea?
        let kind: ArrivalKind
        let event: NSEvent
    }

    private static var claims: [Claim] = []
    private static var monitor: Any?

    // MARK: - Public Methods

    /// `surface` covers `window`: until it releases, arrivals beneath the surface are withheld,
    /// and the pointer over the surface is whatever `cursor` says.
    static func claim(_ surface: NSView, covering window: NSWindow, cursor: CursorPolicy) {
        if cursor == .arrow {
            CoveredWindowCursor.claim(surface, covering: window)
        }
        prune()
        guard !claims.contains(where: { $0.surface === surface }) else { return }
        claims.append(Claim(surface: surface, window: window, cursor: cursor))
        installMonitorIfNeeded()
    }

    /// `surface` is done covering. The arrivals it withheld are delivered to whatever the pointer
    /// is still on — or handed to the surface still covering that, if there is one — and the
    /// window gets its cursor back unless something else is still over it.
    ///
    /// Call this once the surface has stopped answering hit tests: an owed `mouseEntered` reaches
    /// views that ask `NSView.isPointerCovered(at:)` on arrival, and they must see the truth.
    static func release(_ surface: NSView) {
        CoveredWindowCursor.release(surface)
        let released = claims.filter { $0.surface === surface }
        claims.removeAll { $0.surface === surface }
        prune()
        for claim in released {
            settle(claim.takeOwed())
        }
        removeMonitorIfIdle()
    }

    /// Whether a live claim is holding `window`'s pointer.
    static func isClaimed(_ window: NSWindow) -> Bool {
        prune()
        return claims.contains { $0.window === window }
    }

    /// The application's half: called after every event `NSApplication` has dispatched.
    ///
    /// The one place a cursor set by a listener beneath the surface can be answered *after* it
    /// spoke — see the type comment for why the mouse-moved path cannot be withheld up front. It
    /// only speaks for a pointer that is actually over the surface: a mouse-moved event can reach
    /// the key window while the pointer is over another one, and that window's cursor is its own.
    static func applicationDidDispatch(_ event: NSEvent) {
        guard !claims.isEmpty else { return }
        switch event.type {
        case .mouseMoved, .mouseEntered, .mouseExited, .cursorUpdate:
            break
        default:
            return
        }
        guard let window = event.window,
              let claim = topClaim(for: window),
              claim.cursor == .arrow,
              let surface = claim.surface,
              surface.bounds.contains(surface.convert(event.locationInWindow, from: nil))
        else { return }
        if NSCursor.current != NSCursor.arrow {
            NSCursor.arrow.set()
        }
    }

    // MARK: - Interception

    /// The monitor's body: the event to let through, or nil for one withheld.
    static func intercept(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .mouseEntered, .mouseExited, .cursorUpdate:
            // `trackingArea` raises for any other event type, which is why the switch guards
            // the read rather than the other way around.
            return intercept(event, type: event.type, area: event.trackingArea, window: event.window)
                ? nil
                : event
        default:
            return event
        }
    }

    /// The decision, taken apart from the event so a test can hand it a real tracking area:
    /// **true** when the event is withheld from its owner.
    ///
    /// An event with no area, or one owned by something that is not a view, cannot be placed
    /// against the surface and passes — tooltips are the ordinary case, and a menu row's tooltip
    /// has to work as much as anything else's. Ownership by an *ancestor* of the surface passes
    /// too: that is a view being reached through, not something standing under the surface, the
    /// same reading `NSView.isPointerCovered(at:)` gives it.
    static func intercept(
        _ event: NSEvent,
        type: NSEvent.EventType,
        area: NSTrackingArea?,
        window: NSWindow?
    ) -> Bool {
        guard let window,
              let claim = topClaim(for: window),
              let surface = claim.surface,
              let area,
              let owner = area.owner as? NSView,
              covers(surface, owner)
        else { return false }

        switch type {
        case .mouseExited:
            claim.forget(area)
            return false
        case .mouseEntered, .cursorUpdate:
            guard let kind = ArrivalKind(type) else { return false }
            claim.owe(OwedArrival(area: area, kind: kind, event: event))
            return true
        default:
            return false
        }
    }

    /// How many arrivals the surface over `window` is holding back — the count a test asserts
    /// on, since the events themselves are AppKit's.
    static func owedArrivalCount(in window: NSWindow) -> Int {
        topClaim(for: window)?.owed.count ?? 0
    }

    // MARK: - Private Methods

    /// Whether `surface` stands between the pointer and `view`: neither contains the other.
    private static func covers(_ surface: NSView, _ view: NSView) -> Bool {
        !view.isDescendant(of: surface) && !surface.isDescendant(of: view)
    }

    /// The claim that answers for `window` — the last one made, since a surface claimed later
    /// was put over the ones before it.
    private static func topClaim(for window: NSWindow) -> Claim? {
        claims.last { $0.window === window && $0.isLive }
    }

    private static func prune() {
        claims.removeAll { !$0.isLive }
    }

    /// Delivers what a released claim was holding, to whichever owner the pointer is still on.
    /// An arrival still beneath another live surface is that surface's to hold now.
    private static func settle(_ arrivals: [OwedArrival]) {
        for arrival in arrivals {
            guard let area = arrival.area,
                  let owner = area.owner as? NSView,
                  let window = owner.window,
                  pointerIsInside(area, of: owner, in: window)
            else { continue }

            if let claim = topClaim(for: window), let surface = claim.surface, covers(surface, owner) {
                claim.owe(arrival)
                continue
            }

            switch arrival.kind {
            case .entered:
                owner.mouseEntered(with: arrival.event)
            case .cursorUpdate:
                owner.cursorUpdate(with: arrival.event)
            }
        }
    }

    /// AppKit's own answer to "is the pointer in this area", re-derived: the area's rectangle —
    /// or the owner's visible rectangle for an `.inVisibleRect` area — against where the pointer
    /// is now, in the owner's coordinates. Read from the window rather than from the owed event,
    /// because the point of asking is that time has passed since the event was made.
    private static func pointerIsInside(_ area: NSTrackingArea, of owner: NSView, in window: NSWindow) -> Bool {
        guard !owner.isHiddenOrHasHiddenAncestor else { return false }
        let rect = area.options.contains(.inVisibleRect)
            ? owner.bounds.intersection(owner.visibleRect)
            : area.rect
        return rect.contains(owner.convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    private static func installMonitorIfNeeded() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseEntered, .mouseExited, .cursorUpdate]
        ) { event in
            intercept(event)
        }
    }

    private static func removeMonitorIfIdle() {
        guard claims.isEmpty, let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }
}

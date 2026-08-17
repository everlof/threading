import AppKit

/// What the pointer looks like while a surface covers the window's content.
///
/// A dropdown here is a **view over the window** rather than a window of its own — see
/// `ThemedMenuPresenter` for why — and AppKit's cursor rectangles know nothing about what is
/// drawn in front of them. The split view registers a resize rectangle over each seam; the menu
/// overlay registers nothing; so a pointer resting *inside an open menu*, on the strip of window
/// where a seam runs behind it, turns into the divider's `↔`. The only thing a click can reach
/// there is the menu, and the cursor is offering to drag a pane edge. A menu that is a window of
/// its own — every one the platform draws — never had the question, because a window's cursor
/// rectangles stop at its own edges.
///
/// The platform has the switch for this. `NSWindow.disableCursorRects()` exists for a surface
/// that has taken the window over; what it lacks is a count. Measured: two disables followed by
/// one enable leave cursor management **on**, so one surface closing inside another would hand
/// back rectangles the surface still covering the window had turned off. This file is that count
/// and nothing else. A surface claims it through `CoveredWindowPointer`, which holds the rest of
/// what a covering surface takes from the pointer — the crossings and the arrow — so that one
/// call at the surface says all of it.
///
/// **Only a surface that answers for every cursor beneath it may claim.** A dropdown does: it
/// covers the whole content view, and nothing inside it wants a cursor other than the arrow. A
/// modal on a scrim does not — its own text fields and drag handles register rectangles of their
/// own, and a window-wide switch would take those down with the ones it meant to silence. That
/// half of the problem is still open, and
/// [`design-system.md`](../../../../docs/architecture/design-system.md) records why it needs a
/// different answer rather than this one applied more widely.
@MainActor
enum CoveredWindowCursor {

    /// One surface holding one window's cursor.
    ///
    /// Both ends are weak. This file's whole job is to give the window back, and retaining either
    /// party in order to do it would be a leak wearing bookkeeping's clothes.
    @MainActor
    private struct Claim {
        weak var surface: NSView?
        weak var window: NSWindow?

        /// A claim counts for as long as its surface is still in the window it covered.
        ///
        /// A surface that left without releasing stops counting instead of holding that window's
        /// cursor for the rest of the session. The owners here each release from a single
        /// teardown funnel, so this is the backstop rather than the mechanism — but the failure
        /// it guards is a window whose cursor never answers again, which is not a failure to
        /// leave to a `guard` somebody may move.
        var isLive: Bool {
            guard let surface, let window else { return false }
            return surface.window === window
        }
    }

    private static var claims: [Claim] = []

    /// The windows whose cursor management this file has turned off — weakly, so a window that
    /// closes takes its entry with it.
    private static let suppressed = NSHashTable<NSWindow>.weakObjects()

    // MARK: - Public Methods

    /// `surface` covers `window`: until it releases, the window's own cursor rectangles stop
    /// answering and the pointer is the arrow.
    static func claim(_ surface: NSView, covering window: NSWindow) {
        guard !claims.contains(where: { $0.surface === surface }) else { return }
        claims.append(Claim(surface: surface, window: window))
        apply()
    }

    /// `surface` is done covering. The window gets its cursor back unless something else is still
    /// over it.
    static func release(_ surface: NSView) {
        claims.removeAll { $0.surface === surface }
        apply()
    }

    /// Whether this file is holding `window`'s cursor.
    ///
    /// `NSWindow.areCursorRectsEnabled` answers the platform's half of that question and says
    /// nothing about who turned it off; a test asserts on both, because the count is the part
    /// AppKit does not keep.
    static func isClaimed(_ window: NSWindow) -> Bool { suppressed.contains(window) }

    // MARK: - Private Methods

    private static func apply() {
        claims.removeAll { !$0.isLive }
        let covered = claims.compactMap(\.window)

        for window in suppressed.allObjects where !covered.contains(where: { $0 === window }) {
            suppressed.remove(window)
            window.enableCursorRects()
            // Enabling only permits the next answer; AppKit rebuilds the rectangles when
            // something asks it to. Left to the next relayout, the pointer would keep the arrow
            // over a seam it is once again allowed to drag.
            window.resetCursorRects()
        }

        for window in covered where !suppressed.contains(window) {
            suppressed.add(window)
            window.disableCursorRects()
            // Disabling stops the *next* answer, and the cursor a seam has already set stays on
            // screen until something replaces it. A menu opened under a pointer that was resting
            // on the divider — a press on the pane header's own menu button is one — is exactly
            // that case, and without this it opens under the resize arrows.
            NSCursor.arrow.set()
        }
    }
}

import AppKit

/// Holding a window's frame on the screen it is on.
///
/// AppKit does this for a titled window and only for a titled window: `constrainFrameRect(_:to:)`
/// returns its argument untouched once `.titled` leaves the style mask, which under a
/// chrome-takeover theme (`WindowChromeCoordinator`) is every dress the main window wears.
/// Measured on a 1728×1084 visible frame, a titled window asked for `{{0, -2302}, {1728, 3386}}`
/// is given `{{0, 0}, {1728, 1084}}`; the same window frameless keeps all 3386 points of it,
/// composer and all, two thousand points below the bottom of the display.
///
/// And a saved frame reaches the window through the one door that is never policed at all:
/// `setFrameUsingName` does not call `constrainFrameRect(_:to:)` — not for a frameless window and
/// not for a titled one. So an oversized frame written once is restored verbatim on every launch
/// afterwards, which is how this shipped: not as a window that grew, but as a window that was
/// never able to come back.
enum MainWindowFrame {

    /// A screen as this needs it — where it is, and where on it a window may be.
    ///
    /// Values rather than `NSScreen` because the choice below is worth testing and a second
    /// display cannot be constructed in a test.
    struct Screen: Equatable {
        let frame: NSRect
        let visibleFrame: NSRect

        init(frame: NSRect, visibleFrame: NSRect) {
            self.frame = frame
            self.visibleFrame = visibleFrame
        }

        init(_ screen: NSScreen) {
            self.init(frame: screen.frame, visibleFrame: screen.visibleFrame)
        }
    }

    /// `rect` sized to fit `bounds` and then moved inside it — the same two steps, in the same
    /// order, that AppKit's own answer for a titled window was measured to take. Pass a screen's
    /// `visibleFrame`: the menu bar and the Dock are not somewhere a window may be.
    static func held(_ rect: NSRect, within bounds: NSRect) -> NSRect {
        var held = rect
        held.size.width = min(held.width, bounds.width)
        held.size.height = min(held.height, bounds.height)
        held.origin.x = min(max(held.minX, bounds.minX), bounds.maxX - held.width)
        held.origin.y = min(max(held.minY, bounds.minY), bounds.maxY - held.height)
        return held
    }

    /// Where `rect` may be: the visible frame of the screen it already shares the most area with.
    ///
    /// Chosen by overlap, not by `window.screen` — which is `nil` until the window is ordered on
    /// screen, and `NSScreen.main` is the *key window's* screen rather than the one this frame is
    /// on. Holding a frame saved on a second display inside the first display's bounds would move
    /// the window across the desk on the next launch, which is a worse bug than the one being
    /// fixed. `nil` when the frame is on no screen at all — a display that has since been
    /// unplugged — and the caller decides where such a window goes instead.
    static func bounds(for rect: NSRect, among screens: [Screen]) -> NSRect? {
        screens
            .map { ($0, rect.intersection($0.frame)) }
            .filter { !$0.1.isNull && !$0.1.isEmpty }
            .max { area(of: $0.1) < area(of: $1.1) }?
            .0.visibleFrame
    }

    /// The window's own screen, or the main one for a frame left on a display that is gone.
    static func bounds(for window: NSWindow) -> NSRect? {
        bounds(for: window.frame, among: NSScreen.screens.map(Screen.init))
            ?? NSScreen.main?.visibleFrame
    }

    private static func area(of rect: NSRect) -> CGFloat {
        rect.width * rect.height
    }
}

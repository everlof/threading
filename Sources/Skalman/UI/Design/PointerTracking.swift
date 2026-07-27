import AppKit

/// Where the pointer actually is, for any view that keeps a hover state.
///
/// **A tracking area reports crossings the *pointer* makes, and says nothing about crossings the
/// *view* makes.** A view moving out from under a stationary pointer is the ordinary case in this
/// window rather than an exotic one: collapsing the display panel slides the pane header — and the
/// pane toggles at its trailing edge — several hundred points sideways, a sidebar row scrolls, a
/// stack re-lays out around a control that appeared. No `mouseExited` is generated for any of
/// them, and none arrives late either: `updateTrackingAreas` tears the area down and installs a
/// fresh one, which assumes the pointer is *outside*, so the crossing that would have cleared the
/// flag has already been forgotten by the time the pointer moves again.
///
/// The hover flag stays true, and the control keeps drawing itself lit until the pointer happens
/// to cross it a second time. That is how the panel toggle came to sit filled with the panel
/// closed: on a toolbar icon button the resting hover fill is `surface` and so is the *selected*
/// fill, separated only by a hairline border, so a stale hover is a button claiming to be on.
///
/// The correction is to re-derive hover from the pointer whenever tracking is rebuilt, which is
/// the one moment the view's geometry is known to have changed. `ThemedControl` does it for every
/// drawn control; the views outside that base do it from their own `updateTrackingAreas`.
extension NSView {

    /// True when the pointer is over the part of this view that is on screen.
    ///
    /// Measured against the visible part of `bounds`, to match the `.inVisibleRect` areas these
    /// views install: a row scrolled half under its clip view is hovered over the half that shows
    /// and not over the half that does not. Read from the window rather than from an event,
    /// because the whole point is to answer at a moment when no event is being delivered.
    ///
    /// **`visibleRect` on its own is not that rectangle.** Where AppKit has clipped nothing — a
    /// view in a window that is not on screen, which is every window a test builds — it answers
    /// with the *window's* area expressed in this view's coordinates, so a 30-point button
    /// reported itself 480 points wide and swallowed a pointer that was nowhere near it.
    /// Intersecting says what was meant either way.
    ///
    /// Keyed to the *key* window because `.activeInKeyWindow` tracking is: a control under the
    /// pointer in a background window is not hovered, which is also how it draws.
    var isPointerInside: Bool {
        guard let window, window.isKeyWindow, !isHiddenOrHasHiddenAncestor else { return false }
        let unclipped = bounds.intersection(visibleRect)
        return unclipped.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    /// Whether a hover flag this view is holding has gone stale — the pointer is no longer on it.
    ///
    /// **Only ever answers "the pointer has left", never "the pointer has arrived."** A view that
    /// slides *under* a stationary pointer is left to AppKit, because entry is what drives dwell
    /// timers, popovers and highlight callbacks here, and synthesising those on every relayout
    /// would flash a popover under a pointer that never moved. Leaving is the direction that goes
    /// wrong visibly, and the only one that can be corrected without a side effect.
    func hoverIsStale(_ isHovered: Bool) -> Bool {
        isHovered && !isPointerInside
    }
}

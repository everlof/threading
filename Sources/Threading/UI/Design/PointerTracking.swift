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

    /// Whether something else in the window is drawn between the pointer and this view at
    /// `pointInWindow`.
    ///
    /// **A tracking area answers for a rectangle, and a rectangle knows nothing about what is
    /// drawn over it.** Two overlapping views are both sent `mouseEntered`, whichever one a click
    /// would actually reach — so a card floating over a list hands a pointer to every row it
    /// covers. The sidebar's receipt is the case that reported it: hovering the band lit the row
    /// hidden behind it, and since the row's highlight and the band are inset from the column by
    /// the same step, the 6% wash surfaced as a plate poking out above the band's own top edge —
    /// a backplate the band appeared to own, drawn to a corner that was not its.
    ///
    /// Hit-testing is how a *click* is aimed, so it is also what says which view the pointer is
    /// on. Asked of this window's tree alone: a popover or a menu is a window of its own and
    /// covers nothing here, which is right — a row must not drop its hover because the popover it
    /// opened is floating over it.
    ///
    /// A view with no window, or a pointer the content view does not claim at all, is **not**
    /// covered. This only ever reports what it can see for itself, so a fixture built without a
    /// window behaves exactly as it did before.
    ///
    /// **Asked for, never folded into `hoverIsStale`.** A dropdown's dismissing surface is a view
    /// in this same window and covers every control under it, so a shared correction would put out
    /// the chip that a menu is open *on* — and the overlay's handoff rule depends on that chip
    /// staying lit and clickable (see
    /// [`design-system.md`](../../../../docs/architecture/design-system.md)). Whether being covered
    /// means anything is the covered view's own question: for a list under a card it is the whole
    /// answer, and for a control under a menu it is not.
    func isPointerCovered(at pointInWindow: CGPoint) -> Bool {
        // `hitTest` takes its point in the *superview's* coordinates, and the content view's
        // superview is the window's frame view — whose coordinates are the window's.
        guard let hit = window?.contentView?.hitTest(pointInWindow) else { return false }

        // `isDescendant(of:)` counts the view itself, so this reads "neither of us contains the
        // other". An ancestor answering the hit — a table view where the row declined it — is
        // this view being reached through, not something standing over it.
        return !hit.isDescendant(of: self) && !isDescendant(of: hit)
    }

    /// The same question wherever the pointer is now, for the moments when there is no event to
    /// read a location off.
    var isPointerCovered: Bool {
        guard let window else { return false }
        return isPointerCovered(at: window.mouseLocationOutsideOfEventStream)
    }

    /// Whether a hover flag this view is holding has gone stale — the pointer is no longer on it.
    ///
    /// **Only ever answers "the pointer has left", never "the pointer has arrived."** A view that
    /// slides *under* a stationary pointer is left to AppKit, because entry is what drives dwell
    /// timers, popovers and highlight callbacks here, and synthesising those on every relayout
    /// would flash a popover under a pointer that never moved. Leaving is the direction that goes
    /// wrong visibly, and the only one that can be corrected without a side effect.
    ///
    /// It answers for the pointer's *position* alone. A surface rising over a still pointer leaves
    /// this true and is a separate question, because being covered does not mean the same thing to
    /// every view — see `isPointerCovered(at:)`.
    func hoverIsStale(_ isHovered: Bool) -> Bool {
        isHovered && !isPointerInside
    }
}

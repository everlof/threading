import AppKit

/// The application object, subclassed for the one thing a delegate cannot do: act **after** an
/// event has been dispatched.
///
/// A local event monitor sees an event before AppKit routes it and may withhold it, which is how
/// `CoveredWindowPointer` keeps hover from reaching the controls beneath an open dropdown. What
/// no monitor can do is answer a listener that has already spoken — the composer's `NSTextView`
/// sets its I-beam from the mouse-moved delivery every crossing in the window depends on, so
/// that event has to go through, and the arrow can only be put back once it has. `sendEvent` is
/// the seam AppKit offers for that, and this class exists to hold it. Nothing else belongs here:
/// startup, menus and lifecycle stay on `AppDelegate`.
final class ThreadingApplication: NSApplication {

    override func sendEvent(_ event: NSEvent) {
        super.sendEvent(event)
        CoveredWindowPointer.applicationDidDispatch(event)
    }
}

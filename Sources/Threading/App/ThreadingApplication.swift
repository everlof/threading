import AppKit

/// The application object, subclassed for the two event boundaries a delegate cannot expose:
/// the exact interval **during** AppKit dispatch, and the moment **after** it has completed.
///
/// A local event monitor sees an event before AppKit routes it and may withhold it, which is how
/// `CoveredWindowPointer` keeps hover from reaching the controls beneath an open dropdown. What
/// no monitor can do is answer a listener that has already spoken — the composer's `NSTextView`
/// sets its I-beam from the mouse-moved delivery every crossing in the window depends on, so
/// that event has to go through, and the arrow can only be put back once it has. The dispatch
/// context also lets a component distinguish the event AppKit is routing now from
/// `NSApplication.currentEvent`, which remains the last event retrieved after routing ends.
/// `sendEvent` is the seam AppKit offers for both answers. Nothing else belongs here: startup,
/// menus and lifecycle stay on `AppDelegate`.
final class ThreadingApplication: NSApplication {

    override func sendEvent(_ event: NSEvent) {
        do {
            ApplicationEventDispatchContext.begin(event)
            defer { ApplicationEventDispatchContext.end() }
            super.sendEvent(event)
        }
        CoveredWindowPointer.applicationDidDispatch(event)
    }
}

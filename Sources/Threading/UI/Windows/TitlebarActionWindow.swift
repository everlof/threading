import AppKit

/// The window that performs its own titlebar double-click, because this window's titlebar never
/// sees one.
///
/// `.fullSizeContentView` and `titlebarAppearsTransparent` are each harmless alone and together
/// take the gesture away. Measured across all four combinations of the two flags in a window
/// otherwise identical to this one, a click 22pt below the top edge hit-tests to `NSTitlebarView`
/// in three of them and to the **content view** in the fourth — which is this window's pair. Zoom
/// on double-click is AppKit's, and it lives in the titlebar the click no longer reaches, so the
/// window quietly lost a gesture every other Mac window has: the strip beside the traffic lights
/// swallowed the double-click and did nothing with it.
///
/// Neither flag is negotiable (see `docs/architecture/window-chrome.md`): the first is what lets
/// the sidebar run the full height under the traffic lights, and the second is what keeps the
/// toolbar from drawing a material bar between the window's rounded corner and the content. So the
/// gesture is restored here rather than traded away.
///
/// **`mouseDown` on the window is the one place it can go.** AppKit calls it only for a click that
/// no view claimed, which means a double-click on a toolbar item, a traffic light, or anything a
/// pane puts under the strip has already been handled and never arrives. There is nothing to
/// hit-test and nothing to steal — the window is asked last, exactly as the responder chain
/// intends.
final class TitlebarActionWindow: NSWindow {

    /// What a double-click performs, as a closure so a test can state the answer rather than
    /// inherit whichever setting the machine running it happens to carry — the gesture is only
    /// worth asserting against a known one.
    var doubleClickAction: () -> TitlebarDoubleClick.Action = { TitlebarDoubleClick.preferredAction }

    /// `NSWindow` answers `false` to both of these the moment `.titled` leaves the style mask,
    /// which under a chrome-takeover theme (`WindowChromeCoordinator`) would leave the app's
    /// only window unable to take keyboard focus at all.
    ///
    /// Deliberately **conditional**, not a bare `true`: a titled window keeps AppKit's own
    /// answer. The first version answered `true` unconditionally on the grounds that a titled
    /// window "already answered true" — but AppKit's answer consults state the documentation
    /// does not name, and overriding it for titled windows shifted `zoom()`'s animation path
    /// on unshown fixtures enough to surface a use-after-free in
    /// `_NSWindowTransformAnimation` two test suites away. Only the frameless case, where the
    /// default is a hard `false`, gets the override.
    ///
    /// In takeover the rest of this class is inert by geometry rather than by flag: a
    /// frameless window's `contentLayoutRect` is its whole content, so `isInTitlebarStrip` is
    /// never true, `mouseDown` always falls through to `super`, and the double-click gesture
    /// belongs to the app-drawn title band instead — which reads the same
    /// `TitlebarDoubleClick.preferredAction`.
    override var canBecomeKey: Bool {
        styleMask.contains(.titled) ? super.canBecomeKey : true
    }
    override var canBecomeMain: Bool {
        styleMask.contains(.titled) ? super.canBecomeMain : true
    }

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == TitlebarDoubleClick.clickCount,
              isInTitlebarStrip(event.locationInWindow) else {
            super.mouseDown(with: event)
            return
        }

        perform(doubleClickAction())
    }

    /// Whether a window-relative point is in the band the platform holds back for the titlebar and
    /// toolbar — the band that, under `.fullSizeContentView`, is drawn *over* the content view
    /// rather than above it.
    ///
    /// `contentLayoutRect` is what the platform left for content, in the same coordinates as an
    /// event's `locationInWindow`, so this is the whole test: everything above it is chrome, and
    /// its height already accounts for the toolbar and for the style the toolbar is drawn in.
    func isInTitlebarStrip(_ locationInWindow: NSPoint) -> Bool {
        locationInWindow.y >= contentLayoutRect.maxY
    }

    private func perform(_ action: TitlebarDoubleClick.Action) {
        switch action {
        case .zoom:
            performZoom(nil)
        case .minimize:
            performMiniaturize(nil)
        case .doNothing:
            break
        }
    }
}

// MARK: - The System's Own Setting

/// What a double-click on a titlebar does, as the user set it in System Settings.
///
/// Read rather than assumed. The point of restoring the gesture is that this window behaves like
/// every other one, which includes behaving like them when the user turned the gesture off — a
/// window that zooms after "Do Nothing" was chosen is a worse bug than the missing gesture, and
/// one nobody would think to look for here.
enum TitlebarDoubleClick {

    /// System Settings → Desktop & Dock → "Double-click a window's title bar to".
    ///
    /// Read from `UserDefaults.standard` on purpose: every app's search list includes the global
    /// domain, which is where the platform keeps this, and nothing in this app ever writes it.
    /// It is a *system* setting being read, not a user choice this app records, so it does not go
    /// through `PreferenceStore` (see `docs/architecture/persistence.md` for that line).
    static let preferenceKey = "AppleActionOnDoubleClick"

    /// A double-click, named so the guard reads as the gesture rather than as an integer.
    static let clickCount = 2

    enum Action: Equatable {
        case zoom
        case minimize
        case doNothing
    }

    /// Anything unrecognised zooms, because zoom is the platform's own default and this value has
    /// gained spellings before — recent System Settings offers "Fill" alongside the older
    /// "Maximize", and both mean "make it fill the screen", which is what `performZoom` does for a
    /// window that proposes no standard frame of its own. The two spellings that must not be
    /// guessed at are the ones that would surprise: turning the gesture off, and miniaturising.
    static func action(forPreference value: String?) -> Action {
        switch value {
        case "Minimize":
            return .minimize
        case "None":
            return .doNothing
        default:
            return .zoom
        }
    }

    static var preferredAction: Action {
        action(forPreference: UserDefaults.standard.string(forKey: preferenceKey))
    }
}

import AppKit

// MARK: - Window Layout Reset

/// Forgets where the user left the window and its dividers.
///
/// **A launch input worth being able to discard.** `setFrameUsingName` is the one door into a
/// window's frame that AppKit does not police — measured, it calls `constrainFrameRect(_:to:)`
/// not at all — so a frame saved on a display that no longer exists is applied whole, and
/// `MainWindowController.holdRestoredFrameOnScreen` is already the patch for it. The recovery
/// surface offers this because a window that comes up somewhere unusable is indistinguishable,
/// from the outside, from an app that will not start.
///
/// Each value is cleared by the type that owns its key rather than by a list of strings here: two
/// of them live in `PreferenceStore` and two do not, and a second spelling of a key is how a reset
/// silently stops resetting something.
@MainActor
enum WindowLayoutReset {

    static func perform() {
        NSWindow.removeFrame(
            usingName: NSWindow.FrameAutosaveName(MainWindowDefaults.frameAutosaveName)
        )
        SidebarWidth.reset()
        DisplayPaneWidth.reset()
        StatusCardVisibility.reset()
        ShellDrawerHeight.reset()
    }
}

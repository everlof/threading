import AppKit

/// The colour the window is painted with, and the ink that reads on it.
///
/// The window's backdrop is **not** the chrome's ground. A terminal pane paints the window with
/// the *terminal* palette's background, so the colour runs into the window's rounded corners and
/// under the transparent toolbar instead of meeting the chrome in a hard seam — see
/// `TerminalContainerViewController.applyPaneBackground`. That is the effect worth keeping, and
/// it has one consequence: everything drawn directly on the window is over a colour the app theme
/// knows nothing about.
///
/// The toolbar is the whole of that "everything" today — the session title, the usage pill, the
/// pane toggles. They read their ink from here rather than from `Design.Text`, which answers for
/// the chrome and is wrong by exactly the amount the two palettes differ: a light app theme with
/// a dark terminal wrote a near-black title straight across it.
///
/// Deliberately *not* the same thing as a theme change. The backdrop moves when the selected
/// session changes as well, since the session next to this one may draw with another palette.
@MainActor
enum WindowBackdrop {

    private(set) static var color: NSColor = Design.Surface.ground

    /// The label tiers that read on the current backdrop.
    static var ink: Design.Ink { Design.Text.on(color) }

    /// Records the backdrop and tells whatever is drawn on it. Ignores a repeat, because the pane
    /// re-applies its colour on every surface swap and a notification per swap would re-ink the
    /// toolbar for nothing.
    static func set(_ newColor: NSColor) {
        guard newColor != color else { return }
        color = newColor
        NotificationCenter.default.post(WindowBackdropDidChange(color: newColor))
    }
}

// MARK: - Event

struct WindowBackdropDidChange: AppEvent {
    static let name = Notification.Name("windowBackdropDidChange")
    let color: NSColor
}

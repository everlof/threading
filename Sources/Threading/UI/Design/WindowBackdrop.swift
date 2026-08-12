import AppKit

/// The colour the window is painted with, the ink that reads on it — and *whose* colour it is.
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
///
/// The backdrop is recorded as a `Ground` rather than as a bare colour so the chrome case can
/// resolve its dynamic system role when it is *read* — storing the colour chosen during the swap
/// would freeze a System window onto the previous light/dark appearance.
///
/// It deliberately no longer says who *owns* the ground. `ThemedSplitView` asked that, taking the
/// theme's border on the chrome and a measured neutral over a terminal palette, and under System
/// dark the two grounds are the same `#1E1E1E`: the seam changed weight on pixels that had not
/// changed at all. What ink reads is a question about the colour, and the colour is all this needs
/// to answer.
@MainActor
enum WindowBackdrop {

    /// What the window is currently painted with.
    enum Ground: Equatable {
        /// The chrome's own ground — the app theme's `ground` role, resolved when asked, so a
        /// dynamic System colour follows a light/dark switch instead of freezing at the swap.
        case chrome
        /// A terminal palette's background: a colour the app theme does not own.
        case terminal(NSColor)
    }

    private(set) static var ground: Ground = .chrome

    /// The colour the window is painted with right now.
    static var color: NSColor {
        switch ground {
        case .chrome: return Design.Surface.ground
        case .terminal(let color): return color
        }
    }

    /// The label tiers that read on the current backdrop.
    static var ink: Design.Ink { Design.Text.on(color) }

    /// A surface role made **opaque** against the ground it will sit on.
    ///
    /// `Design.Ink.surface` and its neighbours are the base tone at a low alpha, which is right
    /// for a control resting on an empty stretch of backdrop — the ground shows through and the
    /// pill reads as a lift rather than as a patch. It is wrong for anything floating over *live
    /// content*: at 14% alpha the git card let the conversation's own text run straight through
    /// its middle, so a branch name and a line of the agent's answer were interleaved.
    ///
    /// Flattening keeps the colour the role asked for — over bare backdrop the result is
    /// identical, which is the point — and drops only the see-through. Resolve inside the drawing
    /// appearance (`BackdropOverlay` already does) so a dynamic ground is measured as it renders.
    static func opaque(_ role: NSColor) -> NSColor {
        role.composited(over: color)
    }

    /// Records the backdrop and tells whatever is drawn on it. Ignores a repeat, because the pane
    /// re-applies its colour on every surface swap and a notification per swap would re-ink the
    /// toolbar for nothing.
    static func set(_ newGround: Ground) {
        guard newGround != ground else { return }
        ground = newGround
        NotificationCenter.default.post(WindowBackdropDidChange(color: color))
    }
}

// MARK: - Event

struct WindowBackdropDidChange: AppEvent {
    static let name = Notification.Name("windowBackdropDidChange")
    let color: NSColor
}

import AppKit

/// The window's split view, with a divider that can actually be seen.
///
/// AppKit draws a divider in a chrome colour, and this window's panes do not sit on the chrome's
/// ground: a terminal pane paints the *window* with the terminal palette's background (see
/// `WindowBackdrop`), so the stock hairline is measured against one ground and drawn on another.
/// On a near-black terminal the seam between the sidebar and the session simply was not there,
/// and the panes read as one undivided surface.
///
/// `dividerColor` is the whole of the seam AppKit offers here, so it reads the same ink the
/// toolbar does. The backdrop moves when the selected session changes as well as when the theme
/// does — both are observed, because a divider that keeps the previous session's ink is the bug
/// this exists to fix, one palette later.
final class ThemedSplitView: NSSplitView {

    private let appEvents = AppEventObservations()

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        // `NSSplitViewController` configures the split view it makes for itself, and handing it
        // one instead inherits `NSSplitView`'s own defaults rather than the controller's. Two of
        // those matter and neither is announced: `isVertical` defaults to **false**, which stacks
        // the panes — the sidebar arrived as a band across the top of the window — and
        // `dividerStyle` defaults to `.thick`. Stated here so replacing the split view is a
        // change of ink and nothing else; a caller wanting a horizontal split still says so.
        isVertical = true
        dividerStyle = .thin

        observeInk()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Appearance

    /// A hairline that reads on the backdrop rather than on the chrome's ground.
    override var dividerColor: NSColor { WindowBackdrop.ink.border }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: - Private Methods

    private func observeInk() {
        appEvents.observe(WindowBackdropDidChange.self) { [weak self] _ in
            self?.needsDisplay = true
        }
        appEvents.observe(AppThemeDidChange.self) { [weak self] _ in
            self?.needsDisplay = true
        }
        appEvents.observe(AccessibilityDisplayOptionsDidChange.self) { [weak self] _ in
            self?.needsDisplay = true
        }
    }
}

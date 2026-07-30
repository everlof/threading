import AppKit

/// The window's split view, with a divider that can actually be seen.
///
/// AppKit draws a divider in a chrome colour, and this window's panes do not sit on the chrome's
/// ground: a terminal pane paints the *window* with the terminal palette's background (see
/// `WindowBackdrop`), so the stock hairline is measured against one ground and drawn on another.
/// On a near-black terminal the seam between the sidebar and the session simply was not there,
/// and the panes read as one undivided surface.
///
/// `dividerColor` is the whole of the seam AppKit offers here. The rule is: **the theme's own
/// line wherever it visibly reads on the backdrop; the measured neutral only where it does
/// not.** Over the chrome's ground the theme's border always reads — a theme is built that way
/// — and a neutral there drew a pale grey seam across a theme whose every other rule is its own
/// hue. Over a terminal palette the border is *measured* against the actual backdrop first: the
/// System theme's terminal deliberately matches the chrome, where the quiet themed hairline is
/// right and the neutral was the one loud line in the window — while a palette the border
/// vanishes against (a black terminal under a light chrome's black rules) still gets the
/// neutral, which is the seam this view originally existed to restore. The backdrop moves when
/// the selected session changes as well as when the theme does — both are observed, because a
/// divider that keeps the previous session's ink is the bug this exists to fix, one palette
/// later.
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

    /// The faintest a hairline may sit above its ground and still register as a line. Well
    /// below text legibility on purpose: a seam is found by the eye sweeping across it, not
    /// read — the System theme's own dark hairline sits at ~1.35:1.
    private static let visibleLineRatio: CGFloat = 1.2

    /// The seam is also the drag handle, so it stays grabbable however fine a theme rules.
    private static let minimumGrab: CGFloat = 1

    /// The seam weighs what every other rule in the window weighs.
    ///
    /// `dividerStyle = .thin` is a *fixed* point, while every other rule here — the pane
    /// headers' and footers' `SeparatorView`s, the shell drawer's grab strip, a table's column
    /// rules — is `Design.Radius.border` thick, because how heavily a style rules is part of its
    /// identity in the same way its palette is. A theme that rules at 2 (Bauhaus) or 3
    /// (Neo Brutalism) therefore drew heavy horizontal rules meeting a one-point vertical seam
    /// between the very same two panes, and the sidebar's header rule visibly stepped down where
    /// it crossed the split. Two weights for one decision, and the theme only ever stated one.
    override var dividerThickness: CGFloat { max(Self.minimumGrab, Design.Radius.border) }

    /// The theme's own line wherever it reads on the backdrop; measured ink where it cannot.
    override var dividerColor: NSColor {
        let border = Design.Surface.border
        guard !WindowBackdrop.isChromeGround else { return border }

        let backdrop = WindowBackdrop.color
        let drawn = backdrop.composited(under: border)
        return ThemeContrast.ratio(drawn, backdrop) >= Self.visibleLineRatio
            ? border
            : WindowBackdrop.ink.border
    }

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
            self?.reweigh()
        }
        appEvents.observe(AccessibilityDisplayOptionsDidChange.self) { [weak self] _ in
            self?.reweigh()
        }
    }

    /// A theme change moves the seam's *weight* as well as its ink, and the panes are placed
    /// against that weight: the split view reads `dividerThickness` while it builds the
    /// constraints between its arranged subviews and does not ask again on its own. Repainting
    /// alone left the panes spaced for the outgoing theme until the window was next resized.
    private func reweigh() {
        needsUpdateConstraints = true
        needsLayout = true
        needsDisplay = true
    }
}

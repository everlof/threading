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

    /// Called when a divider drag ends, with the divider's index and where the pointer was let
    /// go, in this view's coordinates.
    ///
    /// A pane stops dead at its floor while the pointer keeps travelling, and the distance
    /// between the two is the only record of how hard the divider was pushed — the frames say
    /// nothing, because nothing moved. The owner decides what a push that far means; this view
    /// only knows that a drag ended and where the hand was.
    var dividerDragDidEnd: ((_ dividerIndex: Int, _ pointerX: CGFloat) -> Void)?

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
    ///
    /// The theme's *rule* ink, not its border: the seam is a rule between panes, and the pane
    /// headers' `SeparatorView`s it meets draw `Design.Surface.divider` — which is also where
    /// the rule-ink budget is enforced. Drawn in `Surface.border` it was the one full-strength
    /// rule left in a window whose every other rule had been held back, stepping in *ink* at
    /// exactly the crossing where it once stepped in weight.
    override var dividerColor: NSColor {
        let rule = Design.Surface.divider
        guard !WindowBackdrop.isChromeGround else { return rule }

        let backdrop = WindowBackdrop.color
        let drawn = backdrop.composited(under: rule)
        return ThemeContrast.ratio(drawn, backdrop) >= Self.visibleLineRatio
            ? rule
            : WindowBackdrop.ink.rule
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: - Dragging

    /// How far either side of the seam still counts as grabbing it. The drawn divider is a
    /// hairline, and AppKit widens its own hit area for exactly this reason; the answer only
    /// has to be as good as "which divider", since `super` decides whether a drag begins.
    private static let dividerGrab = Design.Spacing.small

    /// Reports where a divider drag ended, without taking the drag over.
    ///
    /// `super.mouseDown` does not return until the tracking loop has pulled its own mouse-up —
    /// there are no gesture recognizers on this view, checked at runtime — so everything AppKit
    /// does with a divider still happens, and the release is read once it has finished.
    ///
    /// The release point is read first from the **event that ended the loop**, which `nextEvent`
    /// leaves as the application's current one, and only then from the pointer itself. The two
    /// agree in the app, and only the first can be driven from a test, where the physical mouse
    /// is wherever the developer left it — while only the second survives a loop that ends on
    /// something other than a mouse-up.
    override func mouseDown(with event: NSEvent) {
        let index = dividerIndex(at: convert(event.locationInWindow, from: nil))
        super.mouseDown(with: event)
        guard let index else { return }

        if let release = NSApp.currentEvent, release.type == .leftMouseUp {
            dividerDragDidEnd?(index, convert(release.locationInWindow, from: nil).x)
        } else if let window {
            let pointer = window.convertPoint(fromScreen: NSEvent.mouseLocation)
            dividerDragDidEnd?(index, convert(pointer, from: nil).x)
        }
    }

    private func dividerIndex(at point: NSPoint) -> Int? {
        arrangedSubviews.dropLast().indices.first { index in
            let seam = arrangedSubviews[index].frame.maxX
            return point.x >= seam - Self.dividerGrab
                && point.x <= seam + dividerThickness + Self.dividerGrab
        }
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

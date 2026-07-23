import AppKit

/// A view drawn directly on the window's **backdrop** rather than on the chrome's ground.
///
/// # Why this type exists
///
/// The window has two grounds, and they are not the same colour.
///
/// The chrome's ground is `Design.Surface.ground`, which the app theme owns and which
/// `Design.Text.*` is calibrated against. But a terminal pane paints the *window itself* with the
/// **terminal palette's** background (`TerminalContainerViewController.applyPaneBackground`), so
/// that colour fills the strip under the transparent toolbar and runs into the window's rounded
/// corners instead of meeting the chrome in a hard seam. That effect is worth keeping — and it
/// means the toolbar is floating over a colour the app theme knows nothing about.
///
/// Reading `Design.Text.label` up there is wrong by exactly the amount the two palettes differ.
/// The failure is not subtle: a light app theme over a dark terminal wrote a near-black session
/// title and an invisible usage pill straight across it.
///
/// # What this type guarantees
///
/// Subclassing is the *only* way to put a custom view in the toolbar — `MainWindowToolbar`'s
/// item factory takes a `BackdropOverlay`, so a new button or label cannot be added without one,
/// and the compiler is what says so.
///
/// Given that, this class guarantees the rest:
///
/// - **The wiring cannot be forgotten.** The backdrop is observed here, and `applyInk` is called
///   before the view is first shown and again on every change — including a change of *selected
///   session*, since the session beside this one may draw with another palette.
/// - **The override cannot be forgotten.** The base `applyInk` traps. Doing nothing instead would
///   leave a view quietly reading the chrome's ink over a ground the chrome does not own, which
///   is the exact bug this exists to prevent — so it fails loudly, on first display, in
///   development. A view that genuinely has no ink says so with an empty override and a comment.
///
/// # What a subclass must do
///
/// Colour **everything it draws** from the `ink` it is handed, and nothing from `Design.Text.*`.
/// Surfaces are the same story: a fill from `Design.Surface.*` is calibrated for the chrome's
/// ground, so a pill that needs one derives it from `ink` instead (see `Design.Ink.surface`).
@MainActor
class BackdropOverlay: NSView {

    private let appEvents = AppEventObservations()

    /// The ink that reads on the backdrop right now. Held here so a subclass rebuilding its own
    /// content between backdrop changes — a label whose text changed — re-reads the same source
    /// rather than reaching for a `Design` role out of habit.
    final var ink: Design.Ink { WindowBackdrop.ink }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        appEvents.observe(WindowBackdropDidChange.self) { [weak self] _ in self?.inkDidChange() }
        // The backdrop can stay the same colour while the *theme* moves — a session on a fixed
        // palette under a changing chrome — and a subclass may derive more than ink from it.
        appEvents.observe(AppThemeDidChange.self) { [weak self] _ in self?.inkDidChange() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Colour everything this view draws, from `ink`.
    ///
    /// Traps by default; see the type's documentation for why silence would be worse.
    func applyInk(_ ink: Design.Ink) {
        fatalError("\(type(of: self)) is a BackdropOverlay and must override applyInk(_:)")
    }

    /// Applied here rather than in `init`, so a subclass's own `setupViews` has already run and
    /// there is nothing to order by hand.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        inkDidChange()
    }

    /// The third thing that moves the ink, and the one that fires no event of its own.
    ///
    /// Under the System theme the backdrop is a *dynamic* colour, so macOS switching between
    /// light and dark at sunset changes what that colour resolves to while the app theme and the
    /// backdrop object both stay exactly as they were. Without this the toolbar would keep the
    /// previous appearance's ink until something else happened to move it.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        inkDidChange()
    }

    /// Resolved inside the view's own appearance, because the backdrop may be a dynamic colour
    /// and a dynamic colour answers whatever appearance is current when it is asked. Off a
    /// notification there is no drawing appearance in force, so asking here rather than there is
    /// the difference between measuring the ground the view is actually on and measuring
    /// whichever one AppKit last had in hand.
    private func inkDidChange() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            applyInk(ink)
        }
        needsDisplay = true
    }
}

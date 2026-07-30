import AppKit

/// A view whose whole job is to *be* a surface: a pane's ground, filled from a semantic role and
/// kept correct for as long as it is on screen.
///
/// `applySurface` writes a **resolved `CGColor`** onto the layer, and a `CGColor` is frozen — the
/// same fact that makes `ThemedControl` draw in `draw(_:)` rather than into a layer. Two things
/// can invalidate it, and they are answered in two different places:
///
/// - **A theme change** is answered for the whole window by `AppThemeRefresh`'s sweep, which
///   re-runs every recorded surface. Nothing here is needed for that.
/// - **A system light/dark switch is not.** There is no app-wide hook for it; every view that
///   resolves its own colours overrides `viewDidChangeEffectiveAppearance` and says so. A ground
///   that missed it kept dark grey behind light text — measured on the sidebar the day it stopped
///   being a system material and started painting itself.
///
/// It exists as a component rather than as a `viewDidChangeEffectiveAppearance` on whichever
/// controller happens to need one, because "a rectangle of ground" is a thing several panes want
/// and the trap above is not visible from a call site that merely fills a view.
final class ThemedSurfaceView: NSView, ThemedComponent {

    // MARK: - Initialization

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Appearance

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // Through `AppThemeRefresh` rather than by re-running the caller's `applySurface`: the
        // recorded surface is the one the view is actually wearing, including a state a caller
        // set later, and it is re-resolved in this view's *own* effective appearance — which is
        // not always the app's, since the Component Gallery previews both at once.
        AppThemeRefresh.repaint(self)
    }
}

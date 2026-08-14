import AppKit

// MARK: - Reveal Highlight

/// The wash a search leaves on the row it just scrolled to: the search-match ground, drawn
/// over the row's own bounds, that fades in, stands a beat, and leaves.
///
/// It wears `Design.Surface.searchMatch` on purpose — the same accent ground `SearchMatchLabel`
/// puts behind a matched run of text — so "the query landed here" is one signal whether it is
/// marking three characters in a result row or the whole setting those characters led to.
///
/// Decorative by contract: `hitTest` returns nil so the row underneath keeps its controls, and
/// it is not an accessibility element — the reveal that places it posts its own announcement.
/// The fill is drawn in `draw(_:)` rather than assigned to a layer, so a live theme switch,
/// an appearance flip and Increase Contrast each resolve the colour again for as long as the
/// wash is on screen.
final class RevealHighlightView: NSView, ThemedComponent {

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Arrives invisible; `flash()` owns the whole presence transition.
        alphaValue = 0
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        ThemedSurface.draw(
            bounds,
            fill: Design.Surface.searchMatch,
            border: nil,
            radius: Design.Radius.control
        )
    }

    // MARK: - Interaction

    /// Never a target: the wash marks the row, it does not stand between the pointer and it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // MARK: - Presence

    /// Fade in, hold, fade out, then tell the owner it is over — which is where the view is
    /// removed. The fades collapse under Reduce Motion; the hold does not, because a hold is
    /// not movement and the wash's whole job is to be seen standing still.
    func flash(completion: @escaping () -> Void) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Design.Motion.appear
            context.allowsImplicitAnimation = true
            self.animator().alphaValue = 1
        }, completionHandler: {
            DispatchQueue.main.asyncAfter(deadline: .now() + Design.Motion.revealHold) { [weak self] in
                guard let self else {
                    completion()
                    return
                }
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = Design.Motion.vanish
                    context.allowsImplicitAnimation = true
                    self.animator().alphaValue = 0
                }, completionHandler: completion)
            }
        })
    }
}

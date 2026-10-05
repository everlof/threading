import AppKit

/// The Linux host's backdrop-ink seam for unchanged passive Design overlays. The host owns
/// palette changes; the component still owns its drawing and receives the current ink when
/// attached or when its inherited appearance changes.
@MainActor
public class BackdropOverlay: NSView {
    public let inkSource: InkSource = .backdrop
    public var ink: Design.Ink { inkSource.ink }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError() }

    public func applyInk(_ ink: Design.Ink) {
        preconditionFailure("A BackdropOverlay must implement applyInk(_:)")
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { invalidateBackdropInk() }
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        invalidateBackdropInk()
    }

    public func invalidateBackdropInk() {
        effectiveAppearance.performAsCurrentDrawingAppearance { applyInk(ink) }
        needsDisplay = true
    }
}

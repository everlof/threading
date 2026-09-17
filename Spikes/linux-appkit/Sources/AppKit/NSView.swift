import Foundation

@MainActor
open class NSResponder {
    public init() {}
    open var acceptsFirstResponder: Bool { false }
    open func mouseDown(with event: NSEvent) {}
    open func mouseUp(with event: NSEvent) {}
    open func mouseEntered(with event: NSEvent) {}
    open func mouseExited(with event: NSEvent) {}
    open func keyDown(with event: NSEvent) {}
}

/// The retained view tree: frames, a subview list, an override point for drawing, and the
/// invalidation flag. This is the *structural* half the Linux draft calls the real portability
/// project — not the widgets, which `UI/Design` already owns.
///
/// What is deliberately absent: Auto Layout. `NSLayoutConstraint` is the fourth-heaviest symbol
/// in `UI/Design` (256 sites) and reproducing it means owning a Cassowary solver and its
/// invalidation contract. The spike sets frames directly and records that gap rather than
/// pretending it is small.
@MainActor
open class NSView: NSResponder {

    // MARK: - Geometry

    open var frame: NSRect {
        didSet { needsDisplay = true }
    }

    open var bounds: NSRect {
        get { NSRect(origin: .zero, size: frame.size) }
        set { frame = NSRect(origin: frame.origin, size: newValue.size) }
    }

    /// AppKit's default is y-up; a flipped view draws top-down. Both appear in `UI/Design`.
    open var isFlipped: Bool { false }

    open var alphaValue: CGFloat = 1
    open var isHidden: Bool = false
    open var needsDisplay: Bool = true
    open var wantsLayer: Bool = false
    open var identifier: NSUserInterfaceItemIdentifier?
    open var toolTip: String?

    // MARK: - Tree

    public private(set) var subviews: [NSView] = []
    public private(set) weak var superview: NSView?

    public init(frame frameRect: NSRect) {
        frame = frameRect
        super.init()
    }

    public required init?(coder: NSCoder) {
        frame = .zero
        super.init()
    }

    open func addSubview(_ view: NSView) {
        view.removeFromSuperview()
        view.superview = self
        subviews.append(view)
        needsDisplay = true
    }

    open func removeFromSuperview() {
        guard let superview else { return }
        superview.subviews.removeAll { $0 === self }
        self.superview = nil
    }

    // MARK: - Drawing

    open func draw(_ dirtyRect: NSRect) {}

    open func layout() {}

    open func setNeedsDisplay(_ rect: NSRect) { needsDisplay = true }

    /// Walks the tree the way AppKit does for a layer-free view: the view's own `draw(_:)`, then
    /// its subviews in order, each under a translated origin, a clipped bounds, and its own alpha.
    public func render(in context: NSGraphicsContext) {
        guard !isHidden, alphaValue > 0 else { return }
        context.saveGraphicsState()
        defer { context.restoreGraphicsState() }

        context.translateBy(x: frame.minX, y: frame.minY)
        if isFlipped { context.flipVertically(in: frame.height) }
        context.alpha = context.alpha * alphaValue

        layout()
        NSGraphicsContext.current = context
        draw(bounds)
        for subview in subviews { subview.render(in: context) }
    }

    // MARK: - Hit testing

    open func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, frame.contains(point) else { return nil }
        let local = NSPoint(x: point.x - frame.minX, y: point.y - frame.minY)
        for subview in subviews.reversed() {
            if let hit = subview.hitTest(local) { return hit }
        }
        return self
    }

    open func convert(_ point: NSPoint, to view: NSView?) -> NSPoint { point }
    open func convert(_ rect: NSRect, to view: NSView?) -> NSRect { rect }

    // MARK: - Accessibility

    private var accessibilityIsElement = true
    private var accessibilityLabelValue: String?
    private var accessibilityRoleValue: String?

    open func setAccessibilityElement(_ isElement: Bool) { accessibilityIsElement = isElement }
    open func isAccessibilityElement() -> Bool { accessibilityIsElement }
    open func setAccessibilityLabel(_ label: String?) { accessibilityLabelValue = label }
    open func accessibilityLabel() -> String? { accessibilityLabelValue }
    open func setAccessibilityRole(_ role: String?) { accessibilityRoleValue = role }

    // MARK: - Animation

    /// The proxy `NSAnimationContext` drives. Unanimated here: the spike renders one frame, and
    /// what it needs to prove is that the *call sites* compile and that a value set through the
    /// animator still lands on the view.
    open func animator() -> Self { self }
}

public struct NSUserInterfaceItemIdentifier: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

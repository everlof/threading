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
/// Auto Layout is present now, and it is the largest thing the shim has taken on: see
/// `Layout/`. The solver is a from-scratch simplex re-solved per pass, which is correct and not
/// incremental — deliberately, so that "expressible and correct" and "fast enough" stay two
/// separate measurements.
@MainActor
open class NSView: NSResponder, NSLayoutItem {

    // MARK: - Geometry

    open var frame: NSRect {
        didSet {
            needsDisplay = true
            needsLayout = true
        }
    }

    /// The engine's way in. Assigning `frame` from inside a solve would mark layout dirty again
    /// and, on a real invalidation loop, never settle.
    func setLaidOutFrame(_ rect: NSRect) {
        if frame != rect {
            frame = rect
            needsLayout = true
        }
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
    open var needsLayout: Bool = true
    open var needsUpdateConstraints: Bool = true
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
        setNeedsLayout()
    }

    open func removeFromSuperview() {
        guard let superview else { return }
        superview.subviews.removeAll { $0 === self }
        superview.setNeedsLayout()
        self.superview = nil
    }

    // MARK: - Auto Layout

    public var layoutSuperview: NSView? { superview }

    /// AppKit's default is true, and so is this one. A view only joins the solve as a solved
    /// rectangle once its owner says so — which is why forgetting this line produces a view pinned
    /// to a stale frame rather than a crash, on both platforms.
    open var translatesAutoresizingMaskIntoConstraints: Bool = true

    var activeConstraints: [NSLayoutConstraint] = []
    public private(set) var layoutGuides: [NSLayoutGuide] = []

    public var constraints: [NSLayoutConstraint] { activeConstraints }

    open func addConstraint(_ constraint: NSLayoutConstraint) { constraint.isActive = true }
    open func addConstraints(_ constraints: [NSLayoutConstraint]) { NSLayoutConstraint.activate(constraints) }
    open func removeConstraint(_ constraint: NSLayoutConstraint) { constraint.isActive = false }
    open func removeConstraints(_ constraints: [NSLayoutConstraint]) { NSLayoutConstraint.deactivate(constraints) }

    open func addLayoutGuide(_ guide: NSLayoutGuide) {
        guide.owningView = self
        layoutGuides.append(guide)
        setNeedsLayout()
    }

    public static let noIntrinsicMetric: CGFloat = -1
    open var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    open func invalidateIntrinsicContentSize() { setNeedsLayout() }

    public enum LayoutConstraintOrientation: Sendable { case horizontal, vertical }

    private var hugging: [Bool: NSLayoutConstraint.Priority] = [:]
    private var compression: [Bool: NSLayoutConstraint.Priority] = [:]

    open func setContentHuggingPriority(_ priority: NSLayoutConstraint.Priority, for orientation: LayoutConstraintOrientation) {
        hugging[orientation == .horizontal] = priority
        setNeedsLayout()
    }

    open func contentHuggingPriority(for orientation: LayoutConstraintOrientation) -> NSLayoutConstraint.Priority {
        hugging[orientation == .horizontal] ?? .defaultLow
    }

    open func setContentCompressionResistancePriority(_ priority: NSLayoutConstraint.Priority, for orientation: LayoutConstraintOrientation) {
        compression[orientation == .horizontal] = priority
        setNeedsLayout()
    }

    open func contentCompressionResistancePriority(for orientation: LayoutConstraintOrientation) -> NSLayoutConstraint.Priority {
        compression[orientation == .horizontal] ?? .defaultHigh
    }

    open func setNeedsLayout() {
        needsLayout = true
        superview?.setNeedsLayout()
    }

    open func updateConstraints() {}

    /// Solve this subtree if anything in it is dirty. AppKit runs this from the window's update
    /// cycle; the spike runs it from the render walk, which is the same contract with a much
    /// simpler clock.
    @discardableResult
    open func layoutSubtreeIfNeeded() -> LayoutEngine.Diagnosis? {
        guard needsLayout else { return nil }
        let diagnosis = LayoutEngine.layout(self)
        clearNeedsLayout()
        return diagnosis
    }

    private func clearNeedsLayout() {
        needsLayout = false
        for subview in subviews { subview.clearNeedsLayout() }
    }

    public var leadingAnchor: NSLayoutXAxisAnchor { NSLayoutXAxisAnchor(item: self, attribute: .leading) }
    public var trailingAnchor: NSLayoutXAxisAnchor { NSLayoutXAxisAnchor(item: self, attribute: .trailing) }
    public var leftAnchor: NSLayoutXAxisAnchor { NSLayoutXAxisAnchor(item: self, attribute: .left) }
    public var rightAnchor: NSLayoutXAxisAnchor { NSLayoutXAxisAnchor(item: self, attribute: .right) }
    public var centerXAnchor: NSLayoutXAxisAnchor { NSLayoutXAxisAnchor(item: self, attribute: .centerX) }
    public var topAnchor: NSLayoutYAxisAnchor { NSLayoutYAxisAnchor(item: self, attribute: .top) }
    public var bottomAnchor: NSLayoutYAxisAnchor { NSLayoutYAxisAnchor(item: self, attribute: .bottom) }
    public var centerYAnchor: NSLayoutYAxisAnchor { NSLayoutYAxisAnchor(item: self, attribute: .centerY) }
    public var firstBaselineAnchor: NSLayoutYAxisAnchor { NSLayoutYAxisAnchor(item: self, attribute: .firstBaseline) }
    public var lastBaselineAnchor: NSLayoutYAxisAnchor { NSLayoutYAxisAnchor(item: self, attribute: .lastBaseline) }
    public var widthAnchor: NSLayoutDimension { NSLayoutDimension(item: self, attribute: .width) }
    public var heightAnchor: NSLayoutDimension { NSLayoutDimension(item: self, attribute: .height) }

    // MARK: - Drawing

    open func draw(_ dirtyRect: NSRect) {}

    open func layout() {}

    open func setNeedsDisplay(_ rect: NSRect) { needsDisplay = true }

    /// Walks the tree the way AppKit does for a layer-free view: the view's own `draw(_:)`, then
    /// its subviews in order, each under a translated origin, a clipped bounds, and its own alpha.
    public func render(in context: NSGraphicsContext) {
        guard !isHidden, alphaValue > 0 else { return }
        layoutSubtreeIfNeeded()
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

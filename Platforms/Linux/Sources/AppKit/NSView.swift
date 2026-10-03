import Foundation

/// A baseline's position in the solver's top-down local coordinates. A centred text line moves
/// by half the extra height its view receives; keeping that fraction in the linear expression
/// lets baseline constraints remain correct when another constraint stretches the label.
public struct NSBaselineMetric: Equatable, Sendable {
    public let heightFraction: CGFloat
    public let offset: CGFloat

    public init(heightFraction: CGFloat, offset: CGFloat) {
        precondition(heightFraction.isFinite && (0...1).contains(heightFraction)
                     && offset.isFinite, "invalid baseline metric")
        self.heightFraction = heightFraction
        self.offset = offset
    }
}

@MainActor
open class NSResponder: Equatable {
    public init() {}
    nonisolated public static func == (lhs: NSResponder, rhs: NSResponder) -> Bool { lhs === rhs }
    open var acceptsFirstResponder: Bool { false }
    open func becomeFirstResponder() -> Bool { true }
    open func resignFirstResponder() -> Bool { true }
    open func mouseDown(with event: NSEvent) {}
    open func mouseDragged(with event: NSEvent) {}
    open func mouseUp(with event: NSEvent) {}
    open func mouseEntered(with event: NSEvent) {}
    open func mouseExited(with event: NSEvent) {}
    open func rightMouseDown(with event: NSEvent) {}
    open func keyDown(with event: NSEvent) {}
    open func scrollWheel(with event: NSEvent) {}
    open func performKeyEquivalent(with event: NSEvent) -> Bool { false }
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

    public struct AutoresizingMask: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let width = AutoresizingMask(rawValue: 1 << 0)
        public static let height = AutoresizingMask(rawValue: 1 << 1)
    }

    open var autoresizingMask: AutoresizingMask = []

    // MARK: - Geometry

    /// The macOS 26 region vocabulary used by unchanged pane bands. The Linux host places
    /// decorations outside this retained content tree, so neither safe areas nor margins
    /// currently consume content. Corner adaptation remains part of the recipe rather than
    /// importing macOS window-control clearances into a native Linux window.
    public struct LayoutRegion: Hashable, Sendable {
        public enum AdaptivityAxis: Hashable, Sendable { case horizontal, vertical }
        private enum Kind: Hashable, Sendable { case safeArea, margins }

        private let kind: Kind
        private let cornerAdaptation: AdaptivityAxis?

        public static func safeArea(cornerAdaptation: AdaptivityAxis? = nil) -> LayoutRegion {
            LayoutRegion(kind: .safeArea, cornerAdaptation: cornerAdaptation)
        }

        public static func margins(cornerAdaptation: AdaptivityAxis? = nil) -> LayoutRegion {
            LayoutRegion(kind: .margins, cornerAdaptation: cornerAdaptation)
        }
    }

    open var frame: NSRect {
        didSet {
            let widthDelta = frame.width - oldValue.width
            let heightDelta = frame.height - oldValue.height
            if widthDelta != 0 || heightDelta != 0 {
                for child in subviews {
                    var resized = child.frame
                    if child.autoresizingMask.contains(.width) {
                        resized.size.width = max(0, resized.width + widthDelta)
                    }
                    if child.autoresizingMask.contains(.height) {
                        resized.size.height = max(0, resized.height + heightDelta)
                    }
                    if resized != child.frame { child.frame = resized }
                }
            }
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

    private var storedBoundsOrigin: NSPoint = .zero

    open var bounds: NSRect {
        get { NSRect(origin: storedBoundsOrigin, size: frame.size) }
        set {
            precondition(newValue.origin.x.isFinite && newValue.origin.y.isFinite,
                         "invalid bounds origin")
            let originChanged = storedBoundsOrigin != newValue.origin
            let sizeChanged = frame.size != newValue.size
            guard originChanged || sizeChanged else { return }
            storedBoundsOrigin = newValue.origin
            if sizeChanged { frame = NSRect(origin: frame.origin, size: newValue.size) }
            needsDisplay = true
            updateTrackingAreasInSubtree()
        }
    }

    open func setBoundsOrigin(_ point: NSPoint) {
        bounds = NSRect(origin: point, size: bounds.size)
    }

    /// AppKit's default is y-up; a flipped view draws top-down. Both appear in `UI/Design`.
    open var isFlipped: Bool { false }

    open var alphaValue: CGFloat = 1
    open var isHidden: Bool = false {
        didSet {
            guard isHidden != oldValue else { return }
            (superview as? NSStackView)?.arrangedSubviewVisibilityDidChange(self)
            needsDisplay = true
            setNeedsLayout()
        }
    }
    open var isHiddenOrHasHiddenAncestor: Bool {
        var ancestor: NSView? = self
        while let view = ancestor {
            if view.isHidden { return true }
            ancestor = view.superview
        }
        return false
    }
    open var needsDisplay: Bool = true
    open var needsLayout: Bool = true
    open var needsUpdateConstraints: Bool = true
    open var wantsLayer: Bool = false
    open var wantsUpdateLayer: Bool { false }
    open var identifier: NSUserInterfaceItemIdentifier?
    open var toolTip: String?

    /// An explicit appearance overrides the inherited one. AppKit calls the hook for each
    /// affected descendant when that effective value changes, including after reparenting.
    open var appearance: NSAppearance? {
        didSet {
            let previous = oldValue?.name ?? superview?.effectiveAppearance.name
                ?? NSAppearance.applicationDefault.name
            notifyEffectiveAppearanceChanged(from: previous)
        }
    }

    open var effectiveAppearance: NSAppearance {
        appearance ?? superview?.effectiveAppearance ?? NSAppearance.applicationDefault
    }

    open func viewDidChangeEffectiveAppearance() {}

    func notifyEffectiveAppearanceChanged(from previous: NSAppearance.Name) {
        guard effectiveAppearance.name != previous else { return }
        viewDidChangeEffectiveAppearance()
        needsDisplay = true
        for child in subviews where child.appearance == nil {
            child.notifyEffectiveAppearanceChanged(from: previous)
        }
    }

    // MARK: - Tree

    public private(set) var subviews: [NSView] = []
    public private(set) weak var superview: NSView?
    weak var contentWindow: NSWindow?

    /// The content root is owned by its window; descendants inherit that owner through parents.
    open var window: NSWindow? { superview?.window ?? contentWindow }
    open func viewWillMove(toWindow newWindow: NSWindow?) {}
    open func viewDidMoveToSuperview() {}
    open func viewDidMoveToWindow() {}

    func notifyWillMove(toWindow newWindow: NSWindow?) {
        viewWillMove(toWindow: newWindow)
        for child in subviews { child.notifyWillMove(toWindow: newWindow) }
    }

    func notifyDidMoveToWindow() {
        for child in subviews { child.notifyDidMoveToWindow() }
        viewDidMoveToWindow()
        if superview == nil {
            if window == nil { clearTrackingEntriesInSubtree() }
            else { updateTrackingAreasInSubtree() }
        }
    }

    public init(frame frameRect: NSRect) {
        frame = frameRect
        super.init()
    }

    public override convenience init() { self.init(frame: .zero) }

    public required init?(coder: NSCoder) {
        frame = .zero
        super.init()
    }

    /// A plain child passes an unhandled press up the view responder chain, as AppKit does.
    /// This lets an image inside a row leave the row in charge of the gesture.
    open override func mouseDown(with event: NSEvent) {
        superview?.mouseDown(with: event)
    }

    open override func keyDown(with event: NSEvent) {
        superview?.keyDown(with: event)
    }

    open override func scrollWheel(with event: NSEvent) {
        superview?.scrollWheel(with: event)
    }

    open func addSubview(_ view: NSView) {
        precondition(!isDescendant(of: view), "cannot add a view to its own descendant")
        let previousWindow = view.window
        let destinationWindow = window
        if previousWindow !== destinationWindow {
            previousWindow?.focusDidLeave(view)
        }
        let announcesWindowMove = previousWindow != nil || destinationWindow != nil
        if announcesWindowMove { view.notifyWillMove(toWindow: destinationWindow) }
        let previousAppearance = view.effectiveAppearance.name
        view.detachFromSuperview(notifyAppearance: false, notifyWindow: false)
        if let contentWindow = view.contentWindow {
            contentWindow.detachContentRootWithoutNotification(view)
            view.contentWindow = nil
        }
        view.superview = self
        subviews.append(view)
        view.viewDidMoveToSuperview()
        view.notifyEffectiveAppearanceChanged(from: previousAppearance)
        needsDisplay = true
        setNeedsLayout()
        if announcesWindowMove { view.notifyDidMoveToWindow() }
        view.updateTrackingAreasInSubtree()
    }

    open func addSubview(_ view: NSView, positioned place: NSWindow.OrderingMode,
                         relativeTo otherView: NSView?) {
        precondition(place != .out, "a subview can only be ordered above or below")
        precondition(otherView !== view, "a subview cannot be positioned relative to itself")
        precondition(otherView == nil || otherView?.superview === self,
                     "relative view must be a sibling")
        addSubview(view)
        subviews.removeLast()
        let index: Int
        if let otherView {
            let siblingIndex = subviews.firstIndex { $0 === otherView }!
            index = place == .above ? siblingIndex + 1 : siblingIndex
        } else {
            index = place == .above ? subviews.count : 0
        }
        subviews.insert(view, at: index)
    }

    open func removeFromSuperview() {
        detachFromSuperview(notifyAppearance: true, notifyWindow: true)
    }

    /// Includes the receiver itself, as AppKit's containment query does.
    open func isDescendant(of view: NSView) -> Bool {
        var ancestor: NSView? = self
        while let candidate = ancestor {
            if candidate === view { return true }
            ancestor = candidate.superview
        }
        return false
    }

    func detachFromSuperview(notifyAppearance: Bool, notifyWindow: Bool) {
        guard let superview else { return }
        let previousWindow = window
        if let previousWindow { discardCursorRectsInSubtree(from: previousWindow) }
        if notifyWindow { previousWindow?.focusDidLeave(self) }
        if notifyWindow && previousWindow != nil { notifyWillMove(toWindow: nil) }
        let previousAppearance = effectiveAppearance.name
        (superview as? NSStackView)?.arrangedSubviewRemovedFromHierarchy(self)
        superview.subviews.removeAll { $0 === self }
        superview.setNeedsLayout()
        self.superview = nil
        viewDidMoveToSuperview()
        if notifyAppearance {
            notifyEffectiveAppearanceChanged(from: previousAppearance)
        }
        if notifyWindow && previousWindow != nil { notifyDidMoveToWindow() }
        clearTrackingEntriesInSubtree()
    }

    /// AppKit offers key equivalents to descendants even when they do not own keyboard focus.
    /// The focused container decides whether its own shortcut should answer the event.
    open override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard !isHidden else { return false }
        for child in subviews where !child.isHidden {
            if child.performKeyEquivalent(with: event) { return true }
        }
        return false
    }

    // MARK: - Auto Layout

    public var layoutSuperview: NSView? { superview }

    /// AppKit's default is true, and so is this one. A view only joins the solve as a solved
    /// rectangle once its owner says so — which is why forgetting this line produces a view pinned
    /// to a stale frame rather than a crash, on both platforms.
    open var translatesAutoresizingMaskIntoConstraints: Bool = true

    var activeConstraints: [NSLayoutConstraint] = []
    public private(set) var layoutGuides: [NSLayoutGuide] = []
    private var regionGuides: [LayoutRegion: NSLayoutGuide] = [:]

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

    open var safeAreaLayoutGuide: NSLayoutGuide { layoutGuide(for: .safeArea()) }

    /// A region owns one guide and four equations for this view's lifetime. Resizing and
    /// reparenting reuse them; the solver updates the guide frame on the next layout pass,
    /// while `rect(for:)` answers current local geometry without forcing layout.
    public func layoutGuide(for region: LayoutRegion) -> NSLayoutGuide {
        if let guide = regionGuides[region] { return guide }
        let guide = NSLayoutGuide()
        addLayoutGuide(guide)
        NSLayoutConstraint.activate([
            guide.leadingAnchor.constraint(equalTo: leadingAnchor),
            guide.trailingAnchor.constraint(equalTo: trailingAnchor),
            guide.topAnchor.constraint(equalTo: topAnchor),
            guide.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        regionGuides[region] = guide
        return guide
    }

    /// Linux content currently has no native decoration or platform-authored margin inside
    /// it. This deliberately differs from macOS's default 20-point layout margins.
    public func edgeInsets(for _: LayoutRegion) -> NSEdgeInsets { NSEdgeInsets() }

    public func rect(for _: LayoutRegion) -> NSRect { bounds }

    public static let noIntrinsicMetric: CGFloat = -1
    open var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    /// Ask Auto Layout for the smallest size satisfying this subtree's constraints at
    /// fitting-size compression priority. The measurement does not change the live frames.
    open var fittingSize: NSSize { LayoutEngine.fittingSize(of: self) }

    /// Plain views have no text baseline; their first and last anchors remain their top and
    /// bottom edges. Text views override these with measured font metrics from their renderer.
    open var firstBaselineMetric: NSBaselineMetric { NSBaselineMetric(heightFraction: 0, offset: 0) }
    open var lastBaselineMetric: NSBaselineMetric { NSBaselineMetric(heightFraction: 1, offset: 0) }

    open func invalidateIntrinsicContentSize() { setNeedsLayout() }

    open func setFrameSize(_ newSize: NSSize) {
        frame = NSRect(origin: frame.origin, size: newSize)
    }

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

    /// Solve dirty constraint islands in this subtree. A frame-placed descendant fixes its own
    /// rectangle, so its internal constraints can be solved separately from its parent's tree.
    /// AppKit runs this from the window update cycle; the Linux host also calls it before input
    /// geometry is read.
    @discardableResult
    open func layoutSubtreeIfNeeded() -> LayoutEngine.Diagnosis? {
        let boundaries = LayoutEngine.independentDescendants(of: self)
        var diagnosis = layoutIslandIfNeeded(boundaries: boundaries)
        for boundary in boundaries {
            guard let childDiagnosis = boundary.layoutSubtreeIfNeeded() else { continue }
            if diagnosis == nil || (diagnosis?.solved == true && !childDiagnosis.solved) {
                diagnosis = childDiagnosis
            }
        }
        return diagnosis
    }

    private func layoutIslandIfNeeded(boundaries: [NSView]? = nil) -> LayoutEngine.Diagnosis? {
        guard needsLayout else { return nil }
        let boundaries = boundaries ?? LayoutEngine.independentDescendants(of: self)
        let diagnosis = LayoutEngine.layoutIsland(self, boundaries: boundaries)
        let excluded = Set(boundaries.map(ObjectIdentifier.init))
        clearNeedsLayout(excluding: excluded)
        updateTrackingAreasInSubtree()
        return diagnosis
    }

    private func clearNeedsLayout(excluding boundaries: Set<ObjectIdentifier>) {
        if boundaries.contains(ObjectIdentifier(self)) { return }
        needsLayout = false
        for subview in subviews { subview.clearNeedsLayout(excluding: boundaries) }
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
        effectiveAppearance.performAsCurrentDrawingAppearance {
            _ = layoutIslandIfNeeded()
            context.saveGraphicsState()
            defer { context.restoreGraphicsState() }

            let previousContext = NSGraphicsContext.current
            NSGraphicsContext.current = context
            defer { NSGraphicsContext.current = previousContext }

            context.translateBy(x: frame.minX, y: frame.minY)
            // A child's coordinates differ from its parent's only when their flipped states
            // differ. Flipping every flipped descendant makes a label inside a flipped stack
            // draw upside down (and prevents the Pango label from drawing at all).
            if isFlipped != (superview?.isFlipped ?? false) {
                context.flipVertically(in: frame.height)
            }
            context.translateBy(x: -bounds.minX, y: -bounds.minY)
            context.alpha = context.alpha * alphaValue
            // The transform above puts bounds in this view's own coordinate system. Keep the
            // clip in the saved graphics state so descendants inherit it and siblings do not.
            NSBezierPath(rect: bounds).addClip()

            layout()
            draw(bounds)
            for subview in subviews { subview.render(in: context) }
        }
    }

    // MARK: - Hit testing

    open func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, frame.contains(point) else { return nil }
        let relativeY = point.y - frame.minY
        let local = NSPoint(
            x: point.x - frame.minX + bounds.minX,
            y: (isFlipped == (superview?.isFlipped ?? false)
                ? relativeY : frame.height - relativeY) + bounds.minY
        )
        for subview in subviews.reversed() {
            if let hit = subview.hitTest(local) { return hit }
        }
        return self
    }

    // MARK: - Pointer tracking and cursor claims

    private var installedTrackingAreas: [NSTrackingArea] = []
    private var lastTrackedPath: [WeakTrackingView] = []

    /// Ancestor clipping is converted into this view's local coordinates. The intersection is
    /// bounded by this view's own bounds even when an offscreen host has no clipping surface.
    open var visibleRect: NSRect {
        var visible = bounds
        var ancestor = superview
        while let view = ancestor {
            let p = convert(view.bounds.origin, from: view)
            let q = convert(NSPoint(x: view.bounds.maxX, y: view.bounds.maxY), from: view)
            let clip = NSRect(x: min(p.x, q.x), y: min(p.y, q.y),
                              width: abs(q.x - p.x), height: abs(q.y - p.y))
            visible = visible.intersection(clip)
            if visible.isEmpty { break }
            ancestor = view.superview
        }
        return visible
    }

    open func updateTrackingAreas() {}
    open func resetCursorRects() {}

    open func addTrackingArea(_ area: NSTrackingArea) {
        guard !installedTrackingAreas.contains(where: { $0 === area }) else { return }
        installedTrackingAreas.append(area)
    }

    open func removeTrackingArea(_ area: NSTrackingArea) {
        installedTrackingAreas.removeAll { $0 === area }
        area.isEntered = false
    }

    open func addCursorRect(_ rect: NSRect, cursor: NSCursor) {
        guard !rect.isEmpty else { return }
        window?.registerCursorRect(rect, cursor: cursor, for: self)
    }

    /// Called only after geometry changes. A moving parent can leave a child hovered even when
    /// the pointer stays still, so every descendant gets the same stale-state check.
    func updateTrackingAreasInSubtree() {
        updateTrackingAreas()
        window?.invalidateCursorRects(for: self)
        for child in subviews { child.updateTrackingAreasInSubtree() }
    }

    private func discardCursorRectsInSubtree(from window: NSWindow) {
        window.discardCursorRects(for: self)
        for child in subviews { child.discardCursorRectsInSubtree(from: window) }
    }

    private func clearTrackingEntriesInSubtree() {
        for area in installedTrackingAreas { area.isEntered = false }
        for child in subviews { child.clearTrackingEntriesInSubtree() }
    }

    /// The host delivers one window-coordinate position per pointer event. Only the hit path and
    /// the previous path are inspected; rows elsewhere in a file-backed navigator do no work.
    public func pointerMoved(toWindowPoint point: NSPoint, event: NSEvent) {
        layoutSubtreeIfNeeded()
        let hit = hitTest(point)
        var newPath: [NSView] = []
        var current = hit
        while let view = current {
            newPath.append(view)
            if view === self { break }
            current = view.superview
        }
        let newIDs = Set(newPath.map(ObjectIdentifier.init))
        var visited = Set<ObjectIdentifier>()
        for view in lastTrackedPath.compactMap(\.view) + newPath {
            let id = ObjectIdentifier(view)
            guard visited.insert(id).inserted else { continue }
            view.deliverOwnTracking(at: point, onHitPath: newIDs.contains(id), event: event)
        }
        lastTrackedPath = newPath.map(WeakTrackingView.init)
    }

    private func deliverOwnTracking(at point: NSPoint, onHitPath: Bool, event: NSEvent) {
        let local = convert(point, from: nil)
        for area in installedTrackingAreas {
            guard area.options.contains(.mouseEnteredAndExited) else { continue }
            let rect = area.options.contains(.inVisibleRect) ? visibleRect : area.rect
            let active = !area.options.contains(.activeInKeyWindow) || window?.isKeyWindow == true
            let inside = active && !isHiddenOrHasHiddenAncestor
                && onHitPath && rect.contains(local)
            guard inside != area.isEntered else { continue }
            area.isEntered = inside
            let crossing = event.trackingCrossing(inside ? .mouseEntered : .mouseExited, area: area)
            if inside { area.owner?.mouseEntered(with: crossing) }
            else { area.owner?.mouseExited(with: crossing) }
        }
    }

    /// The same screen-space and visibility rule used by the production hover-staleness helper.
    open var isPointerInside: Bool {
        guard let window, window.isKeyWindow, !isHiddenOrHasHiddenAncestor else { return false }
        return visibleRect.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    open func hoverIsStale(_ isHovered: Bool) -> Bool { isHovered && !isPointerInside }

    private func pointInRoot(_ point: NSPoint) -> NSPoint {
        guard let superview else {
            let localY = point.y - bounds.minY
            return NSPoint(x: frame.minX + point.x - bounds.minX,
                           y: frame.minY + (isFlipped ? frame.height - localY : localY))
        }
        let localY = point.y - bounds.minY
        let y = isFlipped == superview.isFlipped ? localY : frame.height - localY
        return superview.pointInRoot(NSPoint(x: frame.minX + point.x - bounds.minX,
                                             y: frame.minY + y))
    }

    private func pointFromRoot(_ point: NSPoint) -> NSPoint {
        guard let superview else {
            let localY = point.y - frame.minY
            return NSPoint(x: point.x - frame.minX + bounds.minX,
                           y: (isFlipped ? frame.height - localY : localY) + bounds.minY)
        }
        let parent = superview.pointFromRoot(point)
        let y = parent.y - frame.minY
        return NSPoint(x: parent.x - frame.minX + bounds.minX,
                       y: (isFlipped == superview.isFlipped ? y : frame.height - y) + bounds.minY)
    }

    open func convert(_ point: NSPoint, to view: NSView?) -> NSPoint {
        let root = pointInRoot(point)
        return view?.pointFromRoot(root) ?? root
    }

    open func convert(_ point: NSPoint, from view: NSView?) -> NSPoint {
        pointFromRoot(view?.pointInRoot(point) ?? point)
    }

    open func convert(_ rect: NSRect, to view: NSView?) -> NSRect {
        let first = convert(rect.origin, to: view)
        let second = convert(NSPoint(x: rect.maxX, y: rect.maxY), to: view)
        return NSRect(x: min(first.x, second.x), y: min(first.y, second.y),
                      width: abs(second.x - first.x), height: abs(second.y - first.y))
    }

    open func convert(_ rect: NSRect, from view: NSView?) -> NSRect {
        let first = convert(rect.origin, from: view)
        let second = convert(NSPoint(x: rect.maxX, y: rect.maxY), from: view)
        return NSRect(x: min(first.x, second.x), y: min(first.y, second.y),
                      width: abs(second.x - first.x), height: abs(second.y - first.y))
    }

    // MARK: - Accessibility

    private var accessibilityIsElement = true
    private var accessibilityLabelValue: String?
    private var accessibilityRoleValue: NSAccessibility.Role?
    private var accessibilityIdentifierValue: String?
    private var accessibilityStoredValue: Any?
    private var accessibilityTitleValue: String?
    private var accessibilityHelpValue: String?
    private weak var accessibilityExplicitParent: AnyObject?

    open func setAccessibilityElement(_ isElement: Bool) { accessibilityIsElement = isElement }
    open func isAccessibilityElement() -> Bool { accessibilityIsElement }
    open func setAccessibilityLabel(_ label: String?) { accessibilityLabelValue = label }
    open func accessibilityLabel() -> String? { accessibilityLabelValue }
    open func setAccessibilityRole(_ role: NSAccessibility.Role?) { accessibilityRoleValue = role }
    open func accessibilityRole() -> NSAccessibility.Role? { accessibilityRoleValue }
    open func setAccessibilityIdentifier(_ identifier: String?) { accessibilityIdentifierValue = identifier }
    open func accessibilityIdentifier() -> String? { accessibilityIdentifierValue }
    open func setAccessibilityValue(_ value: Any?) { accessibilityStoredValue = value }
    open func accessibilityValue() -> Any? { accessibilityStoredValue }
    open func accessibilityPerformPress() -> Bool { false }
    open func isAccessibilityEnabled() -> Bool { true }
    open func setAccessibilityTitle(_ title: String?) { accessibilityTitleValue = title }
    open func accessibilityTitle() -> String? { accessibilityTitleValue }
    open func setAccessibilityHelp(_ help: String?) { accessibilityHelpValue = help }
    open func accessibilityHelp() -> String? { accessibilityHelpValue }
    open func accessibilityPerformShowMenu() -> Bool { false }
    open func setAccessibilityParent(_ parent: Any?) {
        accessibilityExplicitParent = parent as AnyObject?
    }
    open func accessibilityParent() -> Any? { accessibilityExplicitParent ?? superview }
    open func accessibilityChildren() -> [Any]? { subviews }
    open func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? { nil }

    open nonisolated func accessibilityHitTest(_ point: NSPoint) -> Any? {
        struct Result: @unchecked Sendable { let value: NSView? }
        return MainActor.assumeIsolated {
            Result(value: accessibleHitTest(point))
        }.value
    }

    private func accessibleHitTest(_ screenPoint: NSPoint) -> NSView? {
        let local = convert(window?.convertPoint(fromScreen: screenPoint) ?? screenPoint, from: nil)
        guard !isHiddenOrHasHiddenAncestor,
              bounds.intersection(visibleRect).contains(local) else { return nil }
        for child in subviews.reversed() {
            if let hit = child.accessibleHitTest(screenPoint) { return hit }
        }
        return isAccessibilityElement() ? self : nil
    }

    // MARK: - Animation

    /// The proxy `NSAnimationContext` drives. Unanimated here: the spike renders one frame, and
    /// what it needs to prove is that the *call sites* compile and that a value set through the
    /// animator still lands on the view.
    open func animator() -> Self { self }
}

public extension NSWindow {
    enum OrderingMode { case above, below, out }
}

public struct NSUserInterfaceItemIdentifier: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

public enum NSAccessibility {
    public enum Role: String, Hashable, Sendable {
        case staticText
        case textArea
        case button
        case group
        case menu
        case menuItem
    }
}

/// A secondary action stays on the row in the accessibility tree. The closure is retained by
/// the action; production callers capture their row weakly to avoid a menu-cycle.
@MainActor
public final class NSAccessibilityCustomAction {
    public let name: String
    private let handler: () -> Bool

    public init(name: String, handler: @escaping () -> Bool) {
        self.name = name
        self.handler = handler
    }

    @discardableResult
    public func perform() -> Bool { handler() }
}

@MainActor
private final class WeakTrackingView {
    weak var view: NSView?
    init(_ view: NSView) { self.view = view }
}

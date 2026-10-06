import Foundation

public enum NSUserInterfaceLayoutOrientation: Sendable {
    case horizontal, vertical
}

/// Arranges structural views with ordinary Auto Layout constraints. The constraints are rebuilt
/// when membership or stack settings change, before the next solve; drawing stays with the
/// arranged views. Hidden members remain in `arrangedSubviews` but consume no slot when detaching
/// is enabled, matching the call sites that hide an action without rebuilding its row.
@MainActor
open class NSStackView: NSView {

    public enum Distribution: Sendable {
        case gravityAreas, fill, fillEqually
    }

    public enum Gravity: Hashable, Sendable {
        case top, bottom, leading, trailing, center
    }

    public static let useDefaultSpacing = CGFloat(Float.greatestFiniteMagnitude)

    public private(set) var arrangedSubviews: [NSView] = []

    open var orientation: NSUserInterfaceLayoutOrientation = .horizontal {
        didSet {
            // AppKit carries the default centre alignment across an axis change.
            if orientation == .vertical && alignment == .centerY { alignment = .centerX }
            if orientation == .horizontal && alignment == .centerX { alignment = .centerY }
            rebuildArrangement()
        }
    }
    open var alignment: NSLayoutConstraint.Attribute = .centerY {
        didSet { rebuildArrangement() }
    }
    open var distribution: Distribution = .gravityAreas {
        didSet { rebuildArrangement() }
    }
    open var spacing: CGFloat = 8 {
        didSet { rebuildArrangement() }
    }
    open var edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) {
        didSet { rebuildArrangement() }
    }
    open var detachesHiddenViews = true {
        didSet { rebuildArrangement() }
    }

    private var customSpacings: [ObjectIdentifier: CGFloat] = [:]
    private var huggingPriorities: [LayoutConstraintOrientation: NSLayoutConstraint.Priority] = [:]
    private var clippingResistancePriorities: [LayoutConstraintOrientation: NSLayoutConstraint.Priority] = [:]
    private var arrangementConstraints: [NSLayoutConstraint] = []
    // The mounted Design components place one gravity area in each stack. A second area needs
    // separate edge/centre layout equations, which this small solver does not yet provide.
    private var arrangedGravity: Gravity?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    public convenience init(views: [NSView]) {
        self.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        for view in views { addArrangedSubview(view) }
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    open func addArrangedSubview(_ view: NSView) {
        insertArrangedSubview(view, at: arrangedSubviews.count)
    }

    open func insertArrangedSubview(_ view: NSView, at index: Int) {
        precondition((0...arrangedSubviews.count).contains(index), "stack arrangement index out of bounds")
        if let previous = arrangedSubviews.firstIndex(where: { $0 === view }) {
            arrangedSubviews.remove(at: previous)
            arrangedSubviews.insert(view, at: min(index, arrangedSubviews.count))
        } else {
            arrangedSubviews.insert(view, at: index)
        }
        if arrangedGravity == nil { arrangedGravity = defaultGravity }
        adopt(view)
        rebuildArrangement()
    }

    /// Replaces the stack's single supported gravity area, including its ordinary subviews.
    /// This differs from removeArrangedSubview, which intentionally leaves a view in the tree.
    /// Production subagent cards use this to install a fixed heading/line set in one operation.
    open func setViews(_ views: [NSView], in gravity: Gravity) {
        precondition(Set(views.map(ObjectIdentifier.init)).count == views.count,
                     "a stack gravity cannot contain the same view twice")
        precondition(gravity == .leading || gravity == .top,
                     "trailing, bottom and center gravity need separate positioning equations")
        precondition(arrangedSubviews.isEmpty || arrangedGravity == gravity,
                     "multiple stack gravity areas require edge-aware layout")

        // NSLayoutConstraint resolves its owning container from the current hierarchy. Once a
        // replaced child is detached, that lookup no longer finds the stack. Retire old stack
        // equations while all of their views are still attached, then rebuild once at the end.
        NSLayoutConstraint.deactivate(arrangementConstraints)
        arrangementConstraints.removeAll(keepingCapacity: true)

        let previous = arrangedSubviews
        arrangedSubviews = views
        arrangedGravity = views.isEmpty ? nil : gravity
        let retained = Set(views.map(ObjectIdentifier.init))
        let removed = previous.filter { !retained.contains(ObjectIdentifier($0)) }
        let removedIDs = Set(removed.map(ObjectIdentifier.init))
        let obsolete = activeConstraints.filter { constraint in
            (constraint.firstItem.map { removedIDs.contains(ObjectIdentifier($0)) } ?? false)
                || (constraint.secondItem.map { removedIDs.contains(ObjectIdentifier($0)) } ?? false)
        }
        let portableDimensions = obsolete.filter { constraint in
            guard let first = constraint.firstItem else { return false }
            return removedIDs.contains(ObjectIdentifier(first)) && constraint.secondItem == nil
                && (constraint.firstAttribute == .width || constraint.firstAttribute == .height)
        }
        NSLayoutConstraint.deactivate(obsolete)
        for view in removed {
            view.removeFromSuperview()
            customSpacings.removeValue(forKey: ObjectIdentifier(view))
        }
        // AppKit keeps a removed view's own width/height constraints with that view. Our
        // constraint owner depends on the current parent, so reinstall those after detaching.
        NSLayoutConstraint.activate(portableDimensions)
        for view in views { adopt(view) }
        rebuildArrangement()
    }

    /// AppKit leaves a removed arranged view in the ordinary subview list. Callers that no longer
    /// need it remove it from the hierarchy separately.
    open func removeArrangedSubview(_ view: NSView) {
        guard let index = arrangedSubviews.firstIndex(where: { $0 === view }) else { return }
        arrangedSubviews.remove(at: index)
        if arrangedSubviews.isEmpty { arrangedGravity = nil }
        customSpacings.removeValue(forKey: ObjectIdentifier(view))
        rebuildArrangement()
    }

    private var defaultGravity: Gravity { orientation == .vertical ? .top : .leading }

    private func adopt(_ view: NSView) {
        if view.superview !== self {
            // A fixed size activated while the view belonged to another container was
            // installed on that container. Reinstall it after reparenting, as AppKit does;
            // otherwise a toolbar button loses its width when ControlRow readopts it.
            let dimensions = view.superview?.activeConstraints.filter {
                $0.firstItem === view && $0.secondItem == nil
                    && ($0.firstAttribute == .width || $0.firstAttribute == .height)
            } ?? []
            NSLayoutConstraint.deactivate(dimensions)
            addSubview(view)
            NSLayoutConstraint.activate(dimensions)
        }
        view.translatesAutoresizingMaskIntoConstraints = false
    }

    /// How strongly the stack keeps itself no larger than its arranged views along an axis. These
    /// are the stack's own edge equations, distinct from a leaf view's content hugging.
    open func huggingPriority(for orientation: LayoutConstraintOrientation) -> NSLayoutConstraint.Priority {
        huggingPriorities[orientation] ?? .defaultLow
    }

    open func setHuggingPriority(_ priority: NSLayoutConstraint.Priority,
                                 for orientation: LayoutConstraintOrientation) {
        huggingPriorities[orientation] = priority
        rebuildArrangement()
    }

    /// How strongly the stack refuses to become smaller than its arranged views along an axis.
    open func clippingResistancePriority(for orientation: LayoutConstraintOrientation)
        -> NSLayoutConstraint.Priority {
        clippingResistancePriorities[orientation] ?? .required
    }

    open func setClippingResistancePriority(_ priority: NSLayoutConstraint.Priority,
                                            for orientation: LayoutConstraintOrientation) {
        clippingResistancePriorities[orientation] = priority
        rebuildArrangement()
    }

    open func setCustomSpacing(_ spacing: CGFloat, after view: NSView) {
        precondition(arrangedSubviews.contains(where: { $0 === view }), "view is not arranged in this stack")
        let key = ObjectIdentifier(view)
        if spacing == Self.useDefaultSpacing {
            customSpacings.removeValue(forKey: key)
        } else {
            customSpacings[key] = spacing
        }
        rebuildArrangement()
    }

    open func customSpacing(after view: NSView) -> CGFloat {
        precondition(arrangedSubviews.contains(where: { $0 === view }), "view is not arranged in this stack")
        return customSpacings[ObjectIdentifier(view)] ?? Self.useDefaultSpacing
    }

    /// Called by NSView's visibility and hierarchy hooks, so a hidden action loses its slot on
    /// the same layout pass, including when the stack itself has no other property mutation.
    func arrangedSubviewVisibilityDidChange(_ view: NSView) {
        guard detachesHiddenViews, arrangedSubviews.contains(where: { $0 === view }) else { return }
        rebuildArrangement()
    }

    func arrangedSubviewRemovedFromHierarchy(_ view: NSView) {
        removeArrangedSubview(view)
    }

    // These follow the equations AppKit installs, read from its constraint identifiers on
    // macOS 26.5 (`NSStackView.Edge`, `.Edge.Min`, `.Stack`, `.Align`, `.EqualSizing`). What
    // matters is the priorities: a top-gravity list leaves spare height below its rows only
    // because a nested stack, hugging each of its children at 250, costs more to stretch than
    // the list's single 250 trailing hug. AppKit additionally softens the leading edge (750)
    // and spacing (749.99) behind required inequalities; those two extra rows per view more
    // than doubled the solve on the Linux document page and no mounted view relies on them
    // yielding, so here they stay required equalities, as before.
    private enum Defaults {
        static let alignment = NSLayoutConstraint.Priority(260)
    }

    private func rebuildArrangement() {
        NSLayoutConstraint.deactivate(arrangementConstraints)
        arrangementConstraints.removeAll(keepingCapacity: true)

        let visible = arrangedSubviews.filter { !detachesHiddenViews || !$0.isHidden }
        guard !visible.isEmpty else {
            setNeedsLayout()
            return
        }

        if orientation == .horizontal {
            arrangeAlongAxis(visible, axis: .horizontal, leadingInset: edgeInsets.left,
                             trailingInset: edgeInsets.right,
                             leading: { $0.leadingAnchor }, trailing: { $0.trailingAnchor })
            for view in visible { arrangeVerticalCrossAxis(view, baselineView: visible[0]) }
        } else {
            arrangeAlongAxis(visible, axis: .vertical, leadingInset: edgeInsets.top,
                             trailingInset: edgeInsets.bottom,
                             leading: { $0.topAnchor }, trailing: { $0.bottomAnchor })
            for view in visible { arrangeHorizontalCrossAxis(view) }
        }
        if distribution == .fillEqually {
            for view in visible.dropFirst() {
                let equal = orientation == .horizontal
                    ? view.widthAnchor.constraint(equalTo: visible[0].widthAnchor)
                    : view.heightAnchor.constraint(equalTo: visible[0].heightAnchor)
                append(equal, Defaults.alignment)
            }
        }

        NSLayoutConstraint.activate(arrangementConstraints)
        setNeedsLayout()
    }

    /// Views sit at the leading inset and their spacing. Gravity areas hug the trailing edge
    /// only at the stack's hugging priority, so spare room collects after the last view; fill
    /// distributions make that edge required as well.
    private func arrangeAlongAxis<Anchor>(
        _ visible: [NSView], axis: LayoutConstraintOrientation,
        leadingInset: CGFloat, trailingInset: CGFloat,
        leading: (NSView) -> NSLayoutAnchor<Anchor>, trailing: (NSView) -> NSLayoutAnchor<Anchor>
    ) {
        let first = visible[0]
        let last = visible[visible.count - 1]
        arrangementConstraints.append(leading(first).constraint(equalTo: leading(self), constant: leadingInset))
        for (previous, next) in zip(visible, visible.dropFirst()) {
            arrangementConstraints.append(leading(next).constraint(
                equalTo: trailing(previous),
                constant: customSpacings[ObjectIdentifier(previous)] ?? spacing))
        }
        let trailingEdge = trailing(last).constraint(equalTo: trailing(self), constant: -trailingInset)
        if distribution == .gravityAreas {
            append(trailing(last).constraint(lessThanOrEqualTo: trailing(self), constant: -trailingInset),
                   clippingResistancePriority(for: axis))
            append(trailingEdge, huggingPriority(for: axis))
        } else {
            arrangementConstraints.append(trailingEdge)
        }
    }

    /// Across a horizontal stack each view stays inside the stack, hugs both inset edges at the
    /// stack's vertical hugging priority, and states its alignment just above that hug. An
    /// alignment that pins an edge replaces that edge's hug: the same equation, stated stronger.
    private func arrangeVerticalCrossAxis(_ view: NSView, baselineView: NSView) {
        let hug = huggingPriority(for: .vertical)
        let clipping = clippingResistancePriority(for: .vertical)
        append(view.topAnchor.constraint(greaterThanOrEqualTo: topAnchor), clipping)
        append(view.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor), clipping)
        let top = view.topAnchor.constraint(equalTo: topAnchor, constant: edgeInsets.top)
        let bottom = view.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -edgeInsets.bottom)
        switch alignment {
        case .top:
            append(top, Defaults.alignment)
            append(bottom, hug)
        case .bottom:
            append(top, hug)
            append(bottom, Defaults.alignment)
        case .height:
            append(top, Defaults.alignment)
            append(bottom, Defaults.alignment)
        case .firstBaseline, .lastBaseline:
            append(top, hug)
            append(bottom, hug)
            if baselineView !== view {
                let baseline = alignment == .firstBaseline
                    ? view.firstBaselineAnchor.constraint(equalTo: baselineView.firstBaselineAnchor)
                    : view.lastBaselineAnchor.constraint(equalTo: baselineView.lastBaselineAnchor)
                append(baseline, Defaults.alignment)
            }
        default:
            append(top, hug)
            append(bottom, hug)
            append(view.centerYAnchor.constraint(equalTo: centerYAnchor), Defaults.alignment)
        }
    }

    private func arrangeHorizontalCrossAxis(_ view: NSView) {
        let hug = huggingPriority(for: .horizontal)
        let clipping = clippingResistancePriority(for: .horizontal)
        append(view.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor), clipping)
        append(view.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor), clipping)
        let leading = view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: edgeInsets.left)
        let trailing = view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -edgeInsets.right)
        switch alignment {
        case .leading, .left:
            append(leading, Defaults.alignment)
            append(trailing, hug)
        case .trailing, .right:
            append(leading, hug)
            append(trailing, Defaults.alignment)
        case .width:
            append(leading, Defaults.alignment)
            append(trailing, Defaults.alignment)
        default:
            append(leading, hug)
            append(trailing, hug)
            append(view.centerXAnchor.constraint(equalTo: centerXAnchor), Defaults.alignment)
        }
    }

    private func append(_ constraint: NSLayoutConstraint, _ priority: NSLayoutConstraint.Priority) {
        constraint.priority = priority
        arrangementConstraints.append(constraint)
    }
}

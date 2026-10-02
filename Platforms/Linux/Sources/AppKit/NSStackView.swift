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
        case fill, fillEqually
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
    open var distribution: Distribution = .fill {
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

    private func rebuildArrangement() {
        NSLayoutConstraint.deactivate(arrangementConstraints)
        arrangementConstraints.removeAll(keepingCapacity: true)

        let visible = arrangedSubviews.filter { !detachesHiddenViews || !$0.isHidden }
        guard !visible.isEmpty else {
            setNeedsLayout()
            return
        }

        switch orientation {
        case .horizontal:
            arrangementConstraints.append(
                visible[0].leadingAnchor.constraint(equalTo: leadingAnchor, constant: edgeInsets.left)
            )
            for (first, second) in zip(visible, visible.dropFirst()) {
                arrangementConstraints.append(second.leadingAnchor.constraint(
                    equalTo: first.trailingAnchor,
                    constant: customSpacings[ObjectIdentifier(first)] ?? spacing
                ))
            }
            let last = visible[visible.count - 1]
            let trailingLimit = last.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor, constant: -edgeInsets.right)
            let trailingFill = last.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -edgeInsets.right)
            // An un-sized spring absorbs spare width, while fixed/intrinsic children stay at
            // the leading edge. AppKit's fill distribution does not stretch a fixed child just
            // because the stack has extra room.
            trailingFill.priority = .defaultLow
            arrangementConstraints.append(contentsOf: [trailingLimit, trailingFill])
            for view in visible { constrainHorizontalCrossAxis(view, baselineView: visible[0]) }
            if distribution == .fillEqually {
                for view in visible.dropFirst() {
                    arrangementConstraints.append(view.widthAnchor.constraint(equalTo: visible[0].widthAnchor))
                }
            }

        case .vertical:
            arrangementConstraints.append(
                visible[0].topAnchor.constraint(equalTo: topAnchor, constant: edgeInsets.top)
            )
            for (first, second) in zip(visible, visible.dropFirst()) {
                arrangementConstraints.append(second.topAnchor.constraint(
                    equalTo: first.bottomAnchor,
                    constant: customSpacings[ObjectIdentifier(first)] ?? spacing
                ))
            }
            let last = visible[visible.count - 1]
            let bottomLimit = last.bottomAnchor.constraint(
                lessThanOrEqualTo: bottomAnchor, constant: -edgeInsets.bottom)
            // A top-gravity list keeps its authored rows at their fitting heights and leaves
            // unused height below. Even a child stack has no intrinsic size of its own, so a
            // low-priority bottom equality stretches its first row and shifts every label.
            arrangementConstraints.append(bottomLimit)
            if visible.contains(where: isFlexibleVerticalSpacer) {
                // An explicit, otherwise unconstrained spacer is the exception: AppKit's fill
                // distribution lets it consume the remaining height and move later rows down.
                let bottomFill = last.bottomAnchor.constraint(
                    equalTo: bottomAnchor, constant: -edgeInsets.bottom)
                bottomFill.priority = .defaultLow
                arrangementConstraints.append(bottomFill)
            }
            for view in visible { constrainVerticalCrossAxis(view) }
            if distribution == .fillEqually {
                for view in visible.dropFirst() {
                    arrangementConstraints.append(view.heightAnchor.constraint(equalTo: visible[0].heightAnchor))
                }
            }
        }

        NSLayoutConstraint.activate(arrangementConstraints)
        setNeedsLayout()
    }

    private func isFlexibleVerticalSpacer(_ view: NSView) -> Bool {
        guard view.subviews.isEmpty,
              view.intrinsicContentSize.height == NSView.noIntrinsicMetric else { return false }
        return !(view.constraints + activeConstraints).contains { constraint in
            constraint.firstItem === view && constraint.secondItem == nil
                && constraint.firstAttribute == .height
        }
    }

    private func constrainHorizontalCrossAxis(_ view: NSView, baselineView: NSView) {
        switch alignment {
        case .top:
            arrangementConstraints.append(view.topAnchor.constraint(equalTo: topAnchor, constant: edgeInsets.top))
        case .bottom:
            arrangementConstraints.append(view.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -edgeInsets.bottom))
        case .firstBaseline:
            if baselineView !== view {
                arrangementConstraints.append(view.firstBaselineAnchor.constraint(equalTo: baselineView.firstBaselineAnchor))
            }
        case .lastBaseline:
            if baselineView !== view {
                arrangementConstraints.append(view.lastBaselineAnchor.constraint(equalTo: baselineView.lastBaselineAnchor))
            }
        default:
            arrangementConstraints.append(view.centerYAnchor.constraint(equalTo: centerYAnchor))
        }
        let top = view.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: edgeInsets.top)
        let bottom = view.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -edgeInsets.bottom)
        top.priority = .defaultHigh
        bottom.priority = .defaultHigh
        arrangementConstraints.append(contentsOf: [top, bottom])
    }

    private func constrainVerticalCrossAxis(_ view: NSView) {
        switch alignment {
        case .leading, .left:
            arrangementConstraints.append(view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: edgeInsets.left))
        case .trailing, .right:
            arrangementConstraints.append(view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -edgeInsets.right))
        default:
            arrangementConstraints.append(view.centerXAnchor.constraint(equalTo: centerXAnchor))
        }
        let leading = view.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: edgeInsets.left)
        let trailing = view.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -edgeInsets.right)
        leading.priority = .defaultHigh
        trailing.priority = .defaultHigh
        arrangementConstraints.append(contentsOf: [leading, trailing])
    }
}

import AppKit

/// A hairline rule, replacing `NSBox(boxType: .separator)`.
///
/// A box is a container that happens to be able to draw a line, and the line it draws is a
/// *system* grey — which on a themed page is the one grey the theme has already replaced.
/// Swiss Minimalist is the case that makes this obvious: the style is black rules on white, and
/// a pale system hairline is the single thing it cannot have.
public final class SeparatorView: NSView, ThemedComponent {

    public enum Orientation {
        case horizontal
        case vertical
    }

    /// How strongly the rule separates what sits on either side of it.
    ///
    /// Most separators divide rows inside one surface and deliberately stay quiet. A boundary
    /// between sibling panes has to remain legible when both panes resolve to nearly the same
    /// ground, so it takes the theme's structural border ink instead.
    public enum Role {
        case content
        case paneBoundary
    }

    private let orientation: Orientation
    private let role: Role
    private var themeRedraw: ThemeRedraw?

    public init(_ orientation: Orientation = .horizontal, role: Role = .content) {
        self.orientation = orientation
        self.role = role
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        themeRedraw = ThemeRedraw(self)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The rule's thickness is the theme's border width, so a style that draws heavy rules draws
    /// them here too rather than only around its cards.
    public override var intrinsicContentSize: NSSize {
        switch orientation {
        case .horizontal: NSSize(width: NSView.noIntrinsicMetric, height: Design.Radius.border)
        case .vertical: NSSize(width: Design.Radius.border, height: NSView.noIntrinsicMetric)
        }
    }

    /// The frame gap that leaves `inkGap` between this rule and what the adjacent view visibly
    /// draws. A padded control owns the correction; the separator merely applies it on the axis
    /// it divides. Bare labels and structural containers have no correction and keep the full
    /// gap.
    public func frameGap(to adjacentView: NSView, forInkGap inkGap: CGFloat) -> CGFloat {
        guard let provider = adjacentView as? OpticalInsetProviding else {
            return max(0, inkGap)
        }
        let inset: CGFloat
        switch orientation {
        case .horizontal:
            inset = provider.opticalVerticalInset(
                forFrameHeight: Self.resolvedLength(of: adjacentView, on: .vertical)
            )
        case .vertical:
            inset = provider.opticalHorizontalInset
        }
        return max(0, inkGap - inset)
    }

    /// Applies one visible-ink gap on both sides of a rule arranged in a stack. The views are
    /// the actual neighbours whose frames the stack places; hidden or nested content remains the
    /// host's decision rather than something this component walks and guesses at.
    public func applyOpticalSpacing(
        in stack: NSStackView,
        precededBy precedingView: NSView?,
        followedBy followingView: NSView?,
        inkGap: CGFloat
    ) {
        let expectedStackOrientation: NSUserInterfaceLayoutOrientation = orientation == .horizontal
            ? .vertical
            : .horizontal
        guard stack.orientation == expectedStackOrientation else {
            assertionFailure("A separator must be perpendicular to the stack it spaces")
            return
        }
        if let precedingView {
            stack.setCustomSpacing(
                frameGap(to: precedingView, forInkGap: inkGap),
                after: precedingView
            )
        }
        if let followingView {
            stack.setCustomSpacing(
                frameGap(to: followingView, forInkGap: inkGap),
                after: self
            )
        }
    }

    private enum Axis {
        case horizontal
        case vertical
    }

    /// Prefer an active fixed constraint over `bounds`: density can change a row constraint and
    /// ask for spacing again before the next layout pass, when the bounds still carry the old
    /// height. Intrinsic/fitting sizes are fallbacks for naturally sized controls.
    private static func resolvedLength(of view: NSView, on axis: Axis) -> CGFloat {
        let attribute: NSLayoutConstraint.Attribute = axis == .horizontal ? .width : .height
        var fixed: (priority: NSLayoutConstraint.Priority, value: CGFloat)?
        for constraint in view.constraints where constraint.isActive
            && constraint.relation == .equal
            && constraint.firstAttribute == attribute
            && constraint.secondItem == nil {
            guard let item = constraint.firstItem as? NSView, item === view else { continue }
            if fixed == nil || constraint.priority.rawValue > fixed!.priority.rawValue {
                fixed = (constraint.priority, constraint.constant)
            }
        }
        if let fixed, fixed.value > 0 { return fixed.value }

        let boundsLength = axis == .horizontal ? view.bounds.width : view.bounds.height
        if boundsLength > 0 { return boundsLength }

        let intrinsic = view.intrinsicContentSize
        let intrinsicLength = axis == .horizontal ? intrinsic.width : intrinsic.height
        if intrinsicLength > 0, intrinsicLength < 10_000 { return intrinsicLength }

        let fitting = view.fittingSize
        return max(0, axis == .horizontal ? fitting.width : fitting.height)
    }

    public override func draw(_ dirtyRect: NSRect) {
        switch role {
        case .content: Design.Surface.divider.setFill()
        case .paneBoundary: Design.Surface.border.setFill()
        }
        bounds.fill()
    }
}

import Foundation

/// Anything a constraint can be attached to: a view, or a guide standing in for a rectangle that
/// has no view of its own.
@MainActor
public protocol NSLayoutItem: AnyObject {
    var layoutSuperview: NSView? { get }
}

@MainActor
public final class NSLayoutConstraint {

    public enum Relation: Sendable {
        case lessThanOrEqual, equal, greaterThanOrEqual
    }

    public enum Attribute: Sendable {
        case left, right, top, bottom, leading, trailing
        case width, height, centerX, centerY
        case firstBaseline, lastBaseline
        case notAnAttribute
    }

    /// AppKit's `Float`-backed priority, including the three names our code actually writes.
    public struct Priority: RawRepresentable, Comparable, Hashable, Sendable {
        public let rawValue: Float
        public init(rawValue: Float) { self.rawValue = rawValue }
        public init(_ rawValue: Float) { self.rawValue = rawValue }
        public static let required = Priority(1000)
        public static let defaultHigh = Priority(750)
        public static let dragThatCanResizeWindow = Priority(510)
        public static let windowSizeStayPut = Priority(500)
        public static let dragThatCannotResizeWindow = Priority(490)
        public static let defaultLow = Priority(250)
        public static let fittingSizeCompression = Priority(50)
        public static func < (lhs: Priority, rhs: Priority) -> Bool { lhs.rawValue < rhs.rawValue }
        public static func - (lhs: Priority, rhs: Float) -> Priority {
            Priority(lhs.rawValue - rhs)
        }
    }

    public weak var firstItem: AnyObject?
    public let firstAttribute: Attribute
    public let relation: Relation
    public weak var secondItem: AnyObject?
    public let secondAttribute: Attribute
    public let multiplier: CGFloat
    public var constant: CGFloat {
        didSet { invalidate() }
    }
    public var priority: Priority = .required {
        didSet { invalidate() }
    }
    public var identifier: String?

    public var isActive: Bool = false {
        didSet {
            guard isActive != oldValue else { return }
            if isActive {
                container?.activeConstraints.append(self)
            } else {
                container?.activeConstraints.removeAll { $0 === self }
            }
            invalidate()
        }
    }

    public init(
        item firstItem: Any,
        attribute firstAttribute: Attribute,
        relatedBy relation: Relation,
        toItem secondItem: Any?,
        attribute secondAttribute: Attribute,
        multiplier: CGFloat,
        constant: CGFloat
    ) {
        self.firstItem = firstItem as AnyObject
        self.firstAttribute = firstAttribute
        self.relation = relation
        self.secondItem = secondItem as AnyObject?
        self.secondAttribute = secondAttribute
        self.multiplier = multiplier
        self.constant = constant
    }

    public static func activate(_ constraints: [NSLayoutConstraint]) {
        for constraint in constraints { constraint.isActive = true }
    }

    public static func deactivate(_ constraints: [NSLayoutConstraint]) {
        for constraint in constraints { constraint.isActive = false }
    }

    // MARK: - Where a constraint lives

    /// AppKit installs a constraint on the nearest common ancestor of its two items, and that
    /// detail is not cosmetic: it decides which solve a constraint takes part in, and getting it
    /// wrong makes a constraint silently inert rather than wrong-looking.
    var container: NSView? {
        guard let firstItem = firstItem as? NSLayoutItem, let firstView = view(of: firstItem) else {
            return nil
        }
        guard let secondItem = secondItem as? NSLayoutItem, let secondView = view(of: secondItem) else {
            return firstView.superview ?? firstView
        }
        var ancestors: [NSView] = []
        var cursor: NSView? = firstView
        while let view = cursor {
            ancestors.append(view)
            cursor = view.superview
        }
        cursor = secondView
        while let view = cursor {
            if ancestors.contains(where: { $0 === view }) { return view }
            cursor = view.superview
        }
        return nil
    }

    private func view(of item: NSLayoutItem) -> NSView? {
        if let view = item as? NSView { return view }
        if let guide = item as? NSLayoutGuide { return guide.owningView }
        return nil
    }

    private func invalidate() {
        container?.setNeedsLayout()
    }
}

/// A rectangle with anchors and no view — `safeAreaLayoutGuide`'s shape, and the cheap way to
/// express a margin or a column without adding a subview to the tree.
@MainActor
public final class NSLayoutGuide: NSLayoutItem {

    public weak var owningView: NSView?
    public var identifier: NSUserInterfaceItemIdentifier?

    public init() {}

    public var layoutSuperview: NSView? { owningView }

    public var leadingAnchor: NSLayoutXAxisAnchor { NSLayoutXAxisAnchor(item: self, attribute: .leading) }
    public var trailingAnchor: NSLayoutXAxisAnchor { NSLayoutXAxisAnchor(item: self, attribute: .trailing) }
    public var leftAnchor: NSLayoutXAxisAnchor { NSLayoutXAxisAnchor(item: self, attribute: .left) }
    public var rightAnchor: NSLayoutXAxisAnchor { NSLayoutXAxisAnchor(item: self, attribute: .right) }
    public var centerXAnchor: NSLayoutXAxisAnchor { NSLayoutXAxisAnchor(item: self, attribute: .centerX) }
    public var topAnchor: NSLayoutYAxisAnchor { NSLayoutYAxisAnchor(item: self, attribute: .top) }
    public var bottomAnchor: NSLayoutYAxisAnchor { NSLayoutYAxisAnchor(item: self, attribute: .bottom) }
    public var centerYAnchor: NSLayoutYAxisAnchor { NSLayoutYAxisAnchor(item: self, attribute: .centerY) }
    public var widthAnchor: NSLayoutDimension { NSLayoutDimension(item: self, attribute: .width) }
    public var heightAnchor: NSLayoutDimension { NSLayoutDimension(item: self, attribute: .height) }

    /// Filled in by the engine after a solve, in the owning view's coordinate space.
    public internal(set) var frame: NSRect = .zero
}

import Foundation

/// The anchor family, generic exactly where AppKit is.
///
/// The generic parameter is not decoration: `leadingAnchor.constraint(equalTo: topAnchor)` has to
/// stay a *compile* error on Linux too, or the shim quietly accepts constraint code the real
/// framework would have rejected, and the spike's "it compiles" claim stops meaning anything.
@MainActor
public class NSLayoutAnchor<AnchorType: AnyObject> {

    let item: NSLayoutItem
    let attribute: NSLayoutConstraint.Attribute

    init(item: NSLayoutItem, attribute: NSLayoutConstraint.Attribute) {
        self.item = item
        self.attribute = attribute
    }

    public func constraint(
        equalTo anchor: NSLayoutAnchor<AnchorType>,
        constant: CGFloat = 0
    ) -> NSLayoutConstraint {
        make(.equal, anchor, multiplier: 1, constant: constant)
    }

    public func constraint(
        greaterThanOrEqualTo anchor: NSLayoutAnchor<AnchorType>,
        constant: CGFloat = 0
    ) -> NSLayoutConstraint {
        make(.greaterThanOrEqual, anchor, multiplier: 1, constant: constant)
    }

    public func constraint(
        lessThanOrEqualTo anchor: NSLayoutAnchor<AnchorType>,
        constant: CGFloat = 0
    ) -> NSLayoutConstraint {
        make(.lessThanOrEqual, anchor, multiplier: 1, constant: constant)
    }

    func make(
        _ relation: NSLayoutConstraint.Relation,
        _ anchor: NSLayoutAnchor<AnchorType>?,
        multiplier: CGFloat,
        constant: CGFloat
    ) -> NSLayoutConstraint {
        NSLayoutConstraint(
            item: item,
            attribute: attribute,
            relatedBy: relation,
            toItem: anchor?.item,
            attribute: anchor?.attribute ?? .notAnAttribute,
            multiplier: multiplier,
            constant: constant
        )
    }
}

@MainActor
public final class NSLayoutXAxisAnchor: NSLayoutAnchor<NSLayoutXAxisAnchor> {}

@MainActor
public final class NSLayoutYAxisAnchor: NSLayoutAnchor<NSLayoutYAxisAnchor> {}

@MainActor
public final class NSLayoutDimension: NSLayoutAnchor<NSLayoutDimension> {

    public func constraint(equalToConstant constant: CGFloat) -> NSLayoutConstraint {
        make(.equal, nil, multiplier: 1, constant: constant)
    }

    public func constraint(greaterThanOrEqualToConstant constant: CGFloat) -> NSLayoutConstraint {
        make(.greaterThanOrEqual, nil, multiplier: 1, constant: constant)
    }

    public func constraint(lessThanOrEqualToConstant constant: CGFloat) -> NSLayoutConstraint {
        make(.lessThanOrEqual, nil, multiplier: 1, constant: constant)
    }

    public func constraint(
        equalTo anchor: NSLayoutDimension,
        multiplier: CGFloat,
        constant: CGFloat = 0
    ) -> NSLayoutConstraint {
        make(.equal, anchor, multiplier: multiplier, constant: constant)
    }

    public func constraint(
        greaterThanOrEqualTo anchor: NSLayoutDimension,
        multiplier: CGFloat,
        constant: CGFloat = 0
    ) -> NSLayoutConstraint {
        make(.greaterThanOrEqual, anchor, multiplier: multiplier, constant: constant)
    }

    public func constraint(
        lessThanOrEqualTo anchor: NSLayoutDimension,
        multiplier: CGFloat,
        constant: CGFloat = 0
    ) -> NSLayoutConstraint {
        make(.lessThanOrEqual, anchor, multiplier: multiplier, constant: constant)
    }
}

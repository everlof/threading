import AppKit

/// The modern alert's shared geometry. Both hosts activate these same constraints against
/// their AppKit view trees; only window placement and classic requester chrome stay host-owned.
@MainActor
enum ThemedAlertLayout {
    static let minimumContentWidth: CGFloat = 360
    static let iconSize: CGFloat = 30
    static let minimumCopyWidth = minimumContentWidth - iconSize - Design.Spacing.inset

    static func copyStack(title: NSView, message: NSView) -> NSStackView {
        let stack = NSStackView(views: [title, message])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.small
        stack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return stack
    }

    static func heading(icon: NSView, copy: NSView) -> NSStackView {
        let stack = NSStackView(views: [icon, copy])
        stack.orientation = .horizontal
        stack.alignment = .top
        stack.spacing = Design.Spacing.inset
        return stack
    }

    static func sectionStack(_ sections: [NSView]) -> NSStackView {
        let stack = NSStackView(views: sections)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.large
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    static func iconConstraints(_ icon: NSView) -> [NSLayoutConstraint] {
        [icon.widthAnchor.constraint(equalToConstant: iconSize),
         icon.heightAnchor.constraint(equalToConstant: iconSize)]
    }

    static func modernTopConstraint(_ stack: NSStackView, in root: NSView) -> NSLayoutConstraint {
        stack.topAnchor.constraint(equalTo: root.topAnchor, constant: Design.Spacing.large)
    }

    static func contentConstraints(_ stack: NSStackView, in root: NSView,
                                   widthPeers: [NSView]) -> [NSLayoutConstraint] {
        [stack.bottomAnchor.constraint(equalTo: root.bottomAnchor,
                                       constant: -Design.Spacing.large),
         stack.leadingAnchor.constraint(equalTo: root.leadingAnchor,
                                        constant: Design.Spacing.large),
         stack.trailingAnchor.constraint(equalTo: root.trailingAnchor,
                                         constant: -Design.Spacing.large),
         stack.widthAnchor.constraint(greaterThanOrEqualToConstant: minimumContentWidth)]
        + widthPeers.map { $0.widthAnchor.constraint(equalTo: stack.widthAnchor) }
    }
}

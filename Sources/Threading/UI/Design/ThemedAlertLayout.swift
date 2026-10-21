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

/// The alert content tree shared by the macOS sheet and Linux modal host. Hosts supply their
/// controls and window behavior; this view owns the heading, action row, section order and
/// constraints. A classic requester adds its own title band and heading well to this tree.
@MainActor
class ThemedAlertBodyView: NSView {
    private(set) var copyStack: NSStackView?
    private var sectionStack: NSStackView?
    private var modernTopConstraint: NSLayoutConstraint?
    private var requesterTopConstraint: NSLayoutConstraint?
    private var titleBand: NSView?

    func installContent(icon: NSView, title: NSView, message: NSView,
                        additionalSections: [NSView], buttons: [NSView],
                        headingContainer: (NSView) -> NSView = { $0 },
                        classicBand: NSView? = nil, classicBandHeight: CGFloat = 18,
                        classicInitially: Bool = false) {
        precondition(sectionStack == nil, "Alert content may only be installed once")

        let copy = ThemedAlertLayout.copyStack(title: title, message: message)
        let heading = ThemedAlertLayout.heading(icon: icon, copy: copy)
        let sections = [headingContainer(heading)] + additionalSections
            + [Self.actionRow(buttons: buttons, spacerAfterFirst: classicInitially)]
        let stack = ThemedAlertLayout.sectionStack(sections)
        copyStack = copy
        sectionStack = stack
        titleBand = classicBand

        if let classicBand { addSubview(classicBand) }
        addSubview(stack)

        let modernTop = ThemedAlertLayout.modernTopConstraint(stack, in: self)
        modernTopConstraint = modernTop
        var constraints = ThemedAlertLayout.iconConstraints(icon)
            + ThemedAlertLayout.contentConstraints(stack, in: self, widthPeers: sections)
        if let classicBand {
            let requesterTop = stack.topAnchor.constraint(
                equalTo: classicBand.bottomAnchor, constant: Design.Spacing.small)
            requesterTopConstraint = requesterTop
            constraints += [
                classicBand.topAnchor.constraint(equalTo: topAnchor, constant: 1),
                classicBand.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
                classicBand.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
                classicBand.heightAnchor.constraint(equalToConstant: classicBandHeight)
            ]
        }
        NSLayoutConstraint.activate(constraints)
        setClassicLayout(classicInitially)
    }

    func setClassicLayout(_ classic: Bool) {
        // Switch top edges in order so a live theme change cannot briefly constrain both.
        if classic, let requesterTopConstraint {
            modernTopConstraint?.isActive = false
            requesterTopConstraint.isActive = true
        } else {
            requesterTopConstraint?.isActive = false
            modernTopConstraint?.isActive = true
        }
        titleBand?.isHidden = !classic
        sectionStack?.spacing = classic ? Design.Spacing.small : Design.Spacing.large
    }

    private static func actionRow(buttons: [NSView], spacerAfterFirst: Bool) -> NSStackView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        var arranged = buttons
        arranged.insert(spacer, at: spacerAfterFirst ? min(1, buttons.count) : 0)
        let row = NSStackView(views: arranged)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Design.Spacing.small
        return row
    }
}

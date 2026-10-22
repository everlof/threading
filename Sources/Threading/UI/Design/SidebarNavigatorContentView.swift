import AppKit

/// The sidebar's shared destination control. Hosts provide the action, while the symbol,
/// type, and accessibility identity belong to the same footer on both platforms.
@MainActor
enum SidebarFooterControls {
    static func settings() -> ThemedButton {
        let button = ThemedButton()
        button.title = L10n.string("Settings")
        button.image = NSImage(
            systemSymbolName: "gearshape", accessibilityDescription: button.title
        )?.withSymbolConfiguration(Design.Symbol.configuration(Design.Symbol.control))
        button.isBordered = false
        button.applyFont(.controlRegular)
        button.setAccessibilityIdentifier("sidebar.settings")
        return button
    }
}

/// The standing header and outline geometry of the project navigator.
/// Each host supplies its own bands and outer chrome; this view owns their shared placement.
@MainActor
final class SidebarNavigatorContentView: NSView {
    #if os(Linux)
    override func hitTest(_ point: NSPoint) -> NSView? {
        let target = super.hitTest(point)
        return target === self ? nil : target
    }
    #endif

    func mountFooter(_ footer: NSView) {
        precondition(footer.superview == nil, "navigator footer is already mounted")
        footer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(footer)
        NSLayoutConstraint.activate([
            footer.leadingAnchor.constraint(equalTo: leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    func mountHeader(_ header: NSView, top: NSLayoutYAxisAnchor) {
        precondition(header.superview == nil, "navigator header is already mounted")
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: top),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }

    @discardableResult
    func mountOutline(_ outline: NSView, below header: NSView,
                      bottom: NSLayoutYAxisAnchor) -> NSLayoutConstraint {
        precondition(header.superview === self && outline.superview == nil,
                     "mount the navigator header before its outline")
        outline.translatesAutoresizingMaskIntoConstraints = false
        addSubview(outline)
        let bottomConstraint = outline.bottomAnchor.constraint(equalTo: bottom)
        NSLayoutConstraint.activate([
            outline.topAnchor.constraint(equalTo: header.bottomAnchor),
            outline.leadingAnchor.constraint(equalTo: leadingAnchor),
            outline.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomConstraint
        ])
        return bottomConstraint
    }

    func mountEmptyState(_ emptyState: NSView, over outline: NSView,
                         inset: CGFloat) {
        precondition(outline.superview === self && emptyState.superview == nil,
                     "mount the navigator outline before its empty state")
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyState)
        NSLayoutConstraint.activate([
            emptyState.centerXAnchor.constraint(equalTo: outline.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: outline.centerYAnchor),
            emptyState.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor,
                                                 constant: inset),
            emptyState.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor,
                                                  constant: -inset)
        ])
    }
}

import AppKit

/// The session row's standing status column and the two actions that replace it on hover.
/// The row host owns session identity, status content and action routing; this view owns the
/// visible subtree and its internal constraints on both desktop platforms.
@MainActor
final class SidebarSessionTrailingSlot: NSView {
    let statusSlot = NSView()
    let actionButton = ThemedIconButton(
        symbolName: SidebarRowDefaults.actionSymbol,
        accessibility: L10n.string("Session actions"),
        target: .inline,
        inkSource: .chrome,
        glyphMaterialization: .deferred
    )
    let archiveButton = ThemedIconButton(
        symbolName: SidebarRowDefaults.archiveSymbol,
        accessibility: SidebarRowDefaults.archiveAccessibilityLabel,
        target: .inline,
        inkSource: .chrome,
        glyphMaterialization: .deferred
    )
    let hoverControls = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("sidebar.session.trailing")

        statusSlot.translatesAutoresizingMaskIntoConstraints = false
        statusSlot.setAccessibilityIdentifier("sidebar.session.status")
        addSubview(statusSlot)
        SidebarRowDefaults.constrainSessionStatus(statusSlot, in: self)

        actionButton.translatesAutoresizingMaskIntoConstraints = false
        actionButton.presentsMenu = true
        actionButton.setAccessibilityIdentifier("sidebar.session.actions")
        archiveButton.translatesAutoresizingMaskIntoConstraints = false
        archiveButton.setAccessibilityIdentifier("sidebar.session.archive")
        hoverControls.orientation = .horizontal
        hoverControls.alignment = .centerY
        hoverControls.spacing = SidebarRowDefaults.hoverButtonSpacing
        hoverControls.alphaValue = 0
        hoverControls.translatesAutoresizingMaskIntoConstraints = false
        hoverControls.setAccessibilityIdentifier("sidebar.session.hover-controls")
        hoverControls.addArrangedSubview(actionButton)
        hoverControls.addArrangedSubview(archiveButton)
        addSubview(hoverControls)
        SidebarRowDefaults.constrainSessionHoverControls(hoverControls, in: self)
    }
}

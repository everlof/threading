import AppKit

/// The native navigator's empty message. Hosts decide when to mount it and own folder import.
@MainActor
enum SidebarEmptyState {
    static var title: String { L10n.string("No Projects") }
    static var detail: String { L10n.string("Drop a folder here, or click + above.") }

    static func makeView() -> NSStackView {
        let title = NSTextField(labelWithString: title)
        title.applyFont(.emphasizedBody)
        title.textColor = Design.Text.secondary
        title.alignment = .center
        let subtitle = NSTextField(wrappingLabelWithString: detail)
        subtitle.applyFont(.detail())
        subtitle.textColor = Design.Text.tertiary
        subtitle.alignment = .center
        let stack = NSStackView(views: [title, subtitle])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = SidebarDefaults.emptyStateSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }
}

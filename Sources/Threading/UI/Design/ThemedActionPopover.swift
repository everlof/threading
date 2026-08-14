import AppKit

/// One row or group boundary in a compact action popover.
///
/// This is deliberately smaller than `ThemedMenuEntry`: an action popover is already open and
/// can carry a rich preview above its commands, while a menu also owns nested destinations,
/// selection state, metrics, shortcuts, filtering and modal keyboard behavior. Sharing this
/// row model still keeps hover-preview features from rebuilding the same icon/text buttons and
/// separator rhythm one surface at a time.
enum ThemedActionPopoverEntry {
    case action(ThemedActionPopoverAction)
    case separator
}

struct ThemedActionPopoverAction {
    let title: String
    let systemSymbolName: String
    let isEnabled: Bool
    let onChoose: () -> Void

    init(
        title: String,
        systemSymbolName: String,
        isEnabled: Bool = true,
        onChoose: @escaping () -> Void
    ) {
        self.title = title
        self.systemSymbolName = systemSymbolName
        self.isEnabled = isEnabled
        self.onChoose = onChoose
    }
}

/// A bounded rich preview followed by menu-like, full-cell action rows.
///
/// The popover chrome, anchoring and dismissal still belong to `ThemedPopover`. This controller
/// owns only the reusable anatomy inside it: optional preview, one visible group rule, and action
/// rows drawn by `ThemedButton`. Callers provide a preview view only when the hover actually
/// opens, which preserves the scaling boundary for thumbnails and extension-backed content.
final class ThemedActionPopoverViewController: NSViewController {

    private let preview: NSView?
    private let previewHeight: CGFloat
    private let entries: [ThemedActionPopoverEntry]
    private let contentWidth: CGFloat
    private let onHoverChange: (Bool) -> Void
    private var actions: [ThemedActionPopoverAction] = []

    init(
        preview: NSView?,
        previewHeight: CGFloat = 0,
        entries: [ThemedActionPopoverEntry],
        contentWidth: CGFloat,
        onHoverChange: @escaping (Bool) -> Void
    ) {
        self.preview = preview
        self.previewHeight = max(0, previewHeight)
        self.entries = entries
        self.contentWidth = contentWidth
        self.onHoverChange = onHoverChange
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = HoverTrackingView()
        container.onHoverChange = onHoverChange
        container.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(
            top: Design.Spacing.medium,
            left: Design.Spacing.medium,
            bottom: Design.Spacing.medium,
            right: Design.Spacing.medium
        )
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        var preceding: NSView?
        var pendingDivider: (view: SeparatorView, preceding: NSView?, inkGap: CGFloat)?
        if let preview {
            preview.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(preview)
            NSLayoutConstraint.activate([
                preview.widthAnchor.constraint(equalToConstant: contentWidth),
                preview.heightAnchor.constraint(equalToConstant: previewHeight)
            ])
            preceding = preview

            let divider = SeparatorView()
            stack.addArrangedSubview(divider)
            pendingDivider = (divider, preview, Design.Spacing.medium)
            preceding = divider
        }

        actions.removeAll(keepingCapacity: true)
        for entry in entries {
            switch entry {
            case .separator:
                let divider = SeparatorView()
                stack.addArrangedSubview(divider)
                pendingDivider = (divider, preceding, Design.Spacing.small)
                preceding = divider

            case .action(let action):
                let index = actions.count
                actions.append(action)
                let button = ThemedButton(
                    symbol: action.systemSymbolName,
                    accessibility: action.title,
                    target: self,
                    action: #selector(choose(_:))
                )
                button.tag = index
                button.title = action.title
                button.emphasis = .tertiary
                button.contentAlignment = .leading
                // A tertiary button normally rests as secondary ink because it is a quiet mark
                // in a larger surface. These are menu commands: quiet chrome, primary words.
                // Stating that distinction here keeps every rich action popover from looking
                // disabled until it is hovered.
                button.contentTintColor = Design.Text.label
                button.isEnabled = action.isEnabled
                button.hoverFill = Design.Surface.controlHover
                button.translatesAutoresizingMaskIntoConstraints = false
                stack.addArrangedSubview(button)
                NSLayoutConstraint.activate([
                    button.widthAnchor.constraint(equalToConstant: contentWidth),
                    button.heightAnchor.constraint(equalToConstant: ThemedMenuMetrics.rowHeight)
                ])
                if let pendingDivider {
                    pendingDivider.view.applyOpticalSpacing(
                        in: stack,
                        precededBy: pendingDivider.preceding,
                        followedBy: button,
                        inkGap: pendingDivider.inkGap
                    )
                }
                pendingDivider = nil
                preceding = button
            }
        }

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        container.setAccessibilityIdentifier("themed.action-popover")
        view = container
    }

    @objc private func choose(_ sender: ThemedButton) {
        guard actions.indices.contains(sender.tag), actions[sender.tag].isEnabled else { return }
        actions[sender.tag].onChoose()
    }

}

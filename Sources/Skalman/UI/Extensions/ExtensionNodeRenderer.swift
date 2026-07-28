import AppKit
import SkalmanExtensionKit

/// Turns an extension's semantic UI values into Skalman-owned AppKit views.
///
/// This is the rendering boundary: extensions choose meaning, while Skalman chooses concrete
/// controls, colours, typography, focus, accessibility, geometry, and live-theme behaviour.
/// No view supplied by an extension crosses this boundary.
@MainActor
enum ExtensionNodeRenderer {
    typealias ImageResolver = @MainActor (ExtensionImageReference) -> NSImage?
    typealias CustomSurfaceRenderer = @MainActor (ExtensionCustomSurface) -> NSView?

    enum RenderError: Error, Equatable, LocalizedError {
        case tooDeep(maximum: Int)
        case tooManyNodes(maximum: Int)
        case customSurfaceUnavailable

        var errorDescription: String? {
            switch self {
            case .tooDeep(let maximum):
                return L10n.format(
                    "Extension UI exceeds the maximum depth of %lld.",
                    Int64(maximum)
                )
            case .tooManyNodes(let maximum):
                return L10n.format(
                    "Extension UI exceeds the maximum node count of %lld.",
                    Int64(maximum)
                )
            case .customSurfaceUnavailable:
                return L10n.string("The extension custom surface could not be created.")
            }
        }
    }

    private enum Limits {
        static let depth = ExtensionPanel.nodeConstraints.maximumDepth
        static let nodes = ExtensionPanel.nodeConstraints.maximumNodes
    }

    static func render(
        _ node: ExtensionNode,
        imageResolver: @escaping ImageResolver = defaultImageResolver,
        customSurfaceRenderer: @escaping CustomSurfaceRenderer = { _ in nil },
        onAction: @escaping (String) -> Void
    ) throws -> ExtensionNodeHostView {
        var count = 0
        try validate(node, depth: 0, count: &count)
        return try ExtensionNodeHostView(
            node: node,
            imageResolver: imageResolver,
            customSurfaceRenderer: customSurfaceRenderer,
            onAction: onAction
        )
    }

    private static func defaultImageResolver(_ reference: ExtensionImageReference) -> NSImage? {
        guard case .systemSymbol(let name) = reference else { return nil }
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    private static func validate(
        _ node: ExtensionNode,
        depth: Int,
        count: inout Int
    ) throws {
        guard depth <= Limits.depth else {
            throw RenderError.tooDeep(maximum: Limits.depth)
        }

        count += 1
        guard count <= Limits.nodes else {
            throw RenderError.tooManyNodes(maximum: Limits.nodes)
        }

        switch node {
        case .stack(_, _, let children):
            for child in children {
                try validate(child, depth: depth + 1, count: &count)
            }
        case .overlay(let base, let overlay):
            try validate(base, depth: depth + 1, count: &count)
            try validate(overlay, depth: depth + 1, count: &count)
        default:
            break
        }
    }
}

/// The one view an extension panel hands to the rest of Skalman.
///
/// It owns the target/action bridge for every button in its tree. Retaining that bridge here
/// matters: AppKit's `target` is weak, so a renderer-local proxy would disappear before the
/// first click.
@MainActor
final class ExtensionNodeHostView: NSView, ThemedComponent {

    private let imageResolver: ExtensionNodeRenderer.ImageResolver
    private let customSurfaceRenderer: ExtensionNodeRenderer.CustomSurfaceRenderer
    private let onAction: (String) -> Void
    private var actionsByButton: [ObjectIdentifier: String] = [:]
    private(set) var proceedPlaceholder: ExtensionProceedPlaceholderView?

    init(
        node: ExtensionNode,
        imageResolver: @escaping ExtensionNodeRenderer.ImageResolver,
        customSurfaceRenderer: @escaping ExtensionNodeRenderer.CustomSurfaceRenderer,
        onAction: @escaping (String) -> Void
    ) throws {
        self.imageResolver = imageResolver
        self.customSurfaceRenderer = customSurfaceRenderer
        self.onAction = onAction
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("extension.node.host")

        let content = try makeView(for: node, parentAxis: nil)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func installProceedContent(_ content: NSView) -> Bool {
        guard let proceedPlaceholder else { return false }
        proceedPlaceholder.install(content)
        return true
    }

    private func makeView(
        for node: ExtensionNode,
        parentAxis: ExtensionAxis?
    ) throws -> NSView {
        switch node {
        case .text(let text, let role):
            return makeText(text, role: role)

        case .image(let reference, let role, let accessibilityLabel):
            return makeImage(
                reference,
                role: role,
                accessibilityLabel: accessibilityLabel
            )

        case .button(let id, let title, let role, let isEnabled):
            let button = ThemedButton(
                title: title,
                target: self,
                action: #selector(buttonPressed)
            )
            button.isProminent = role == .primary
            button.isEnabled = isEnabled
            button.setAccessibilityIdentifier("extension.action.\(id)")
            if role == .destructive {
                button.setAccessibilityHelp(L10n.string("Destructive action"))
            }
            actionsByButton[ObjectIdentifier(button)] = id
            return button

        case .status(let text, let role):
            let label = NSTextField(labelWithString: text)
            label.applyFont(.control)
            label.textColor = statusColor(for: role)
            label.lineBreakMode = .byTruncatingTail
            label.setAccessibilityIdentifier("extension.status")
            return label

        case .proceed:
            let placeholder = ExtensionProceedPlaceholderView()
            proceedPlaceholder = placeholder
            return placeholder

        case .overlay(let base, let overlay):
            return ExtensionOverlayNodeView(
                base: try makeView(for: base, parentAxis: nil),
                overlay: try makeView(for: overlay, parentAxis: nil)
            )

        case .customSurface(let surface, let accessibilityLabel):
            guard let view = customSurfaceRenderer(surface) else {
                throw ExtensionNodeRenderer.RenderError.customSurfaceUnavailable
            }
            view.translatesAutoresizingMaskIntoConstraints = false
            view.setAccessibilityIdentifier("extension.custom-surface.\(surface.kind.rawValue)")
            if let accessibilityLabel {
                view.setAccessibilityLabel(accessibilityLabel)
            } else {
                view.setAccessibilityElement(false)
            }
            return view

        case .divider:
            return SeparatorView(parentAxis == .horizontal ? .vertical : .horizontal)

        case .spacer(let spacing):
            let spacer = NSView()
            spacer.translatesAutoresizingMaskIntoConstraints = false
            let value = spacingValue(spacing)
            switch parentAxis {
            case .horizontal:
                spacer.widthAnchor.constraint(equalToConstant: value).isActive = true
            case .vertical:
                spacer.heightAnchor.constraint(equalToConstant: value).isActive = true
            case nil:
                spacer.widthAnchor.constraint(equalToConstant: value).isActive = true
                spacer.heightAnchor.constraint(equalToConstant: value).isActive = true
            }
            return spacer

        case .flexibleSpacer:
            let spacer = NSView()
            spacer.translatesAutoresizingMaskIntoConstraints = false
            if parentAxis != .vertical {
                spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
                spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            }
            if parentAxis != .horizontal {
                spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
                spacer.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
            }
            spacer.setAccessibilityIdentifier("extension.flexible-spacer")
            return spacer

        case .stack(let axis, let spacing, let children):
            let views = try children.map { try makeView(for: $0, parentAxis: axis) }
            let stack = NSStackView(views: views)
            stack.orientation = axis == .horizontal ? .horizontal : .vertical
            stack.alignment = axis == .horizontal ? .centerY : .leading
            stack.spacing = spacingValue(spacing)

            for (node, view) in zip(children, views) {
                guard case .divider = node else { continue }
                if axis == .horizontal {
                    view.heightAnchor.constraint(equalTo: stack.heightAnchor).isActive = true
                } else {
                    view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
                }
            }
            return stack
        }
    }

    private func makeText(
        _ text: String,
        role: ExtensionTextRole
    ) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.textColor = role == .detail ? Design.Text.secondary : Design.Text.label

        switch role {
        case .heading:
            label.applyFont(.heading)
        case .body:
            label.applyFont(.body)
        case .detail:
            label.applyFont(.detail())
        case .code:
            label.applyFont(.code())
        case .compactBody:
            label.applyFont(.control)
            label.maximumNumberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
        case .compactDetail:
            label.applyFont(.detail())
            label.maximumNumberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
        }

        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setAccessibilityIdentifier("extension.text.\(role.rawValue)")
        return label
    }

    private func makeImage(
        _ reference: ExtensionImageReference,
        role: ExtensionImageRole,
        accessibilityLabel: String?
    ) -> NSImageView {
        let imageView = NSImageView()
        imageView.image = imageResolver(reference)
        imageView.imageScaling = .scaleProportionallyDown
        imageView.translatesAutoresizingMaskIntoConstraints = false

        let side: CGFloat
        switch role {
        case .identity:
            side = 18
        case .icon:
            side = 14
        case .decoration:
            side = 12
        }

        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: side),
            imageView.heightAnchor.constraint(equalToConstant: side)
        ])

        if let accessibilityLabel {
            imageView.setAccessibilityLabel(accessibilityLabel)
        } else {
            imageView.setAccessibilityElement(false)
        }
        imageView.setAccessibilityIdentifier("extension.image.\(role.rawValue)")
        return imageView
    }

    private func statusColor(for role: ExtensionStatusRole) -> NSColor {
        switch role {
        case .neutral: Design.Text.secondary
        case .positive: Design.Status.positive
        case .warning: Design.Status.warning
        case .negative: Design.Status.negative
        }
    }

    private func spacingValue(_ spacing: ExtensionSpacing) -> CGFloat {
        switch spacing {
        case .none: 0
        case .tight: Design.Spacing.tight
        case .small: Design.Spacing.small
        case .medium: Design.Spacing.medium
        case .large: Design.Spacing.large
        }
    }

    @objc private func buttonPressed(_ sender: ThemedButton) {
        guard let action = actionsByButton[ObjectIdentifier(sender)] else { return }
        onAction(action)
    }
}

@MainActor
final class ExtensionProceedPlaceholderView: NSView {
    private var installed: NSView?
    private var installedConstraints: [NSLayoutConstraint] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("extension.proceed")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func install(_ view: NSView) {
        NSLayoutConstraint.deactivate(installedConstraints)
        installed?.removeFromSuperview()
        installed = view
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        installedConstraints = [
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor)
        ]
        NSLayoutConstraint.activate(installedConstraints)
    }
}

@MainActor
private final class ExtensionOverlayNodeView: NSView {
    init(base: NSView, overlay: NSView) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        base.translatesAutoresizingMaskIntoConstraints = false
        overlay.translatesAutoresizingMaskIntoConstraints = false
        addSubview(base)
        addSubview(overlay, positioned: .above, relativeTo: base)
        NSLayoutConstraint.activate([
            base.topAnchor.constraint(equalTo: topAnchor),
            base.bottomAnchor.constraint(equalTo: bottomAnchor),
            base.leadingAnchor.constraint(equalTo: leadingAnchor),
            base.trailingAnchor.constraint(equalTo: trailingAnchor),
            overlay.topAnchor.constraint(equalTo: topAnchor),
            overlay.bottomAnchor.constraint(equalTo: bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
        overlay.setContentHuggingPriority(.defaultLow, for: .horizontal)
        overlay.setContentHuggingPriority(.defaultLow, for: .vertical)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

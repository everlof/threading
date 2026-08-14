import AppKit
import ThreadingExtensionKit

/// Turns an extension's semantic UI values into Threading-owned AppKit views.
///
/// This is the rendering boundary: extensions choose meaning, while Threading chooses concrete
/// controls, colours, typography, focus, accessibility, geometry, and live-theme behaviour.
/// No view supplied by an extension crosses this boundary.
@MainActor
enum ExtensionNodeRenderer {
    typealias ImageResolver = @MainActor (ExtensionImageReference) -> NSImage?
    typealias CustomSurfaceRenderer = @MainActor (ExtensionCustomSurface) -> NSView?
    /// Builds — or reuses — the host-owned player for one media document.
    ///
    /// A *factory*, not a view: playback survives a panel replacement keyed on the document's id,
    /// so the surface hosting the tree owns the player and this hands back the one that already
    /// exists for that id. A row rebuilt because a label changed must not restart the animation.
    typealias MediaPlayerFactory = @MainActor (ExtensionMediaDocument) -> NSView?

    enum RenderError: Error, Equatable, LocalizedError {
        case tooDeep(maximum: Int)
        case tooManyNodes(maximum: Int)
        case tooManyRenderedElements(maximum: Int)
        case customSurfaceUnavailable
        case mediaPlayerUnavailable

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
            case .tooManyRenderedElements(let maximum):
                return L10n.format(
                    "Extension UI exceeds the aggregate rendered-element count of %lld.",
                    Int64(maximum)
                )
            case .customSurfaceUnavailable:
                return L10n.string("The extension custom surface could not be created.")
            case .mediaPlayerUnavailable:
                return L10n.string("This surface cannot play media documents.")
            }
        }
    }

    private enum Limits {
        static let depth = ExtensionPanel.nodeConstraints.maximumDepth
        static let nodes = ExtensionPanel.nodeConstraints.maximumNodes
        static let renderedElements = ExtensionPanel.nodeConstraints.maximumRenderedElements
    }

    static func render(
        _ node: ExtensionNode,
        imageResolver: @escaping ImageResolver = defaultImageResolver,
        customSurfaceRenderer: @escaping CustomSurfaceRenderer = { _ in nil },
        mediaPlayerFactory: @escaping MediaPlayerFactory = { _ in nil },
        onAction: @escaping (String) -> Void
    ) throws -> ExtensionNodeHostView {
        try render(
            node,
            imageResolver: imageResolver,
            customSurfaceRenderer: customSurfaceRenderer,
            mediaPlayerFactory: mediaPlayerFactory,
            onEvent: { actionID, _ in onAction(actionID) }
        )
    }

    static func render(
        _ node: ExtensionNode,
        imageResolver: @escaping ImageResolver = defaultImageResolver,
        customSurfaceRenderer: @escaping CustomSurfaceRenderer = { _ in nil },
        mediaPlayerFactory: @escaping MediaPlayerFactory = { _ in nil },
        onEvent: @escaping (String, ExtensionJSONValue?) -> Void
    ) throws -> ExtensionNodeHostView {
        try validate(node)
        return try ExtensionNodeHostView(
            node: node,
            imageResolver: imageResolver,
            customSurfaceRenderer: customSurfaceRenderer,
            mediaPlayerFactory: mediaPlayerFactory,
            onEvent: onEvent
        )
    }

    /// Validates the complete semantic value before a virtual panel starts materializing rows.
    /// A viewport boundary changes view ownership, not the extension contract: invalid content is
    /// rejected atomically rather than appearing valid until the user happens to scroll to it.
    static func validate(_ node: ExtensionNode) throws {
        var count = 0
        var renderedElementCount = 0
        try validate(
            node,
            depth: 0,
            count: &count,
            renderedElementCount: &renderedElementCount
        )
    }

    /// Renders one already-validated child of a vertical semantic stack.
    ///
    /// Parent axis remains part of rendering because it decides divider orientation and spacer
    /// geometry. The host itself fills its table cell; `fillsContentWidth` preserves the original
    /// stack's `.leading` alignment for intrinsic controls while text inputs, scenes and dividers
    /// continue to span the readable width.
    static func renderValidatedRow(
        _ node: ExtensionNode,
        parentAxis: ExtensionAxis?,
        fillsContentWidth: Bool,
        imageResolver: @escaping ImageResolver = defaultImageResolver,
        customSurfaceRenderer: @escaping CustomSurfaceRenderer = { _ in nil },
        mediaPlayerFactory: @escaping MediaPlayerFactory = { _ in nil },
        onEvent: @escaping (String, ExtensionJSONValue?) -> Void
    ) throws -> ExtensionNodeHostView {
        try ExtensionNodeHostView(
            node: node,
            parentAxis: parentAxis,
            fillsContentWidth: fillsContentWidth,
            imageResolver: imageResolver,
            customSurfaceRenderer: customSurfaceRenderer,
            mediaPlayerFactory: mediaPlayerFactory,
            onEvent: onEvent
        )
    }

    private static func defaultImageResolver(_ reference: ExtensionImageReference) -> NSImage? {
        guard case .systemSymbol(let name) = reference else { return nil }
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    private static func validate(
        _ node: ExtensionNode,
        depth: Int,
        count: inout Int,
        renderedElementCount: inout Int
    ) throws {
        guard depth <= Limits.depth else {
            throw RenderError.tooDeep(maximum: Limits.depth)
        }

        count += 1
        renderedElementCount += 1
        guard count <= Limits.nodes else {
            throw RenderError.tooManyNodes(maximum: Limits.nodes)
        }
        guard renderedElementCount <= Limits.renderedElements else {
            throw RenderError.tooManyRenderedElements(maximum: Limits.renderedElements)
        }

        switch node {
        case .picker(_, _, let options, _, _):
            renderedElementCount += options.count
            guard renderedElementCount <= Limits.renderedElements else {
                throw RenderError.tooManyRenderedElements(maximum: Limits.renderedElements)
            }
        case .scene(let scene):
            renderedElementCount += scene.items.count
            guard renderedElementCount <= Limits.renderedElements else {
                throw RenderError.tooManyRenderedElements(maximum: Limits.renderedElements)
            }
        case .stack(_, _, let children):
            for child in children {
                try validate(
                    child,
                    depth: depth + 1,
                    count: &count,
                    renderedElementCount: &renderedElementCount
                )
            }
        case .overlay(let base, let overlay):
            try validate(
                base,
                depth: depth + 1,
                count: &count,
                renderedElementCount: &renderedElementCount
            )
            try validate(
                overlay,
                depth: depth + 1,
                count: &count,
                renderedElementCount: &renderedElementCount
            )
        case .disclosure(_, let summary, let detail):
            // Both levels are built in this pass, so both spend the renderer's own budget. The
            // contract's separate budget for a revealed level is a *narrower* limit stated per
            // surface, not a licence to hand this renderer an unbounded tree.
            try validate(
                summary,
                depth: depth + 1,
                count: &count,
                renderedElementCount: &renderedElementCount
            )
            for child in detail {
                try validate(
                    child,
                    depth: depth + 1,
                    count: &count,
                    renderedElementCount: &renderedElementCount
                )
            }
        default:
            break
        }
    }
}

/// The one view an extension panel hands to the rest of Threading.
///
/// It owns the target/action bridge for every button in its tree. Retaining that bridge here
/// matters: AppKit's `target` is weak, so a renderer-local proxy would disappear before the
/// first click.
@MainActor
final class ExtensionNodeHostView: NSView, ThemedComponent {

    private let imageResolver: ExtensionNodeRenderer.ImageResolver
    private let customSurfaceRenderer: ExtensionNodeRenderer.CustomSurfaceRenderer
    private let mediaPlayerFactory: ExtensionNodeRenderer.MediaPlayerFactory
    private let onEvent: (String, ExtensionJSONValue?) -> Void
    private var actionsByButton: [ObjectIdentifier: String] = [:]
    private var actionsByTextInput: [ObjectIdentifier: String] = [:]
    private var actionsByPicker: [ObjectIdentifier: String] = [:]
    private(set) var proceedPlaceholder: ExtensionProceedPlaceholderView?

    init(
        node: ExtensionNode,
        parentAxis: ExtensionAxis? = nil,
        fillsContentWidth: Bool = true,
        imageResolver: @escaping ExtensionNodeRenderer.ImageResolver,
        customSurfaceRenderer: @escaping ExtensionNodeRenderer.CustomSurfaceRenderer,
        mediaPlayerFactory: @escaping ExtensionNodeRenderer.MediaPlayerFactory = { _ in nil },
        onEvent: @escaping (String, ExtensionJSONValue?) -> Void
    ) throws {
        self.imageResolver = imageResolver
        self.customSurfaceRenderer = customSurfaceRenderer
        self.mediaPlayerFactory = mediaPlayerFactory
        self.onEvent = onEvent
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("extension.node.host")

        let content = try makeView(for: node, parentAxis: parentAxis)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        var constraints = [
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor)
        ]
        if fillsContentWidth {
            constraints.append(content.trailingAnchor.constraint(equalTo: trailingAnchor))
        }
        NSLayoutConstraint.activate(constraints)
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

        case .textInput(
            let id,
            let value,
            let placeholder,
            let accessibilityLabel,
            let role,
            let isEnabled
        ):
            let field: ThemedTextField = role == .search
                ? ThemedSearchField(frame: .zero)
                : ThemedTextField(frame: .zero)
            field.stringValue = value
            field.placeholderString = placeholder
            field.isEnabled = isEnabled
            field.target = self
            field.action = #selector(textInputSubmitted)
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            field.setAccessibilityIdentifier("extension.input.\(id)")
            field.setAccessibilityLabel(accessibilityLabel)
            actionsByTextInput[ObjectIdentifier(field)] = id
            return field

        case .picker(let id, let selection, let options, let accessibilityLabel, let isEnabled):
            let picker = ThemedPopUp(frame: .zero)
            for option in options {
                picker.addItem(
                    ThemedMenuItem(
                        title: option.title,
                        representedValue: option.value,
                        isEnabled: option.isEnabled
                    )
                )
            }
            if let selection,
               let index = options.firstIndex(where: { $0.value == selection }) {
                picker.selectItem(at: index)
            } else {
                picker.selectItem(at: -1)
            }
            picker.isEnabled = isEnabled
            picker.target = self
            picker.action = #selector(pickerChanged)
            picker.setAccessibilityIdentifier("extension.picker.\(id)")
            picker.setAccessibilityLabel(accessibilityLabel)
            actionsByPicker[ObjectIdentifier(picker)] = id
            return picker

        case .scene(let scene):
            return makeScene(scene)

        case .media(let document):
            // A surface that was not given a factory has no player, which is a refusal rather
            // than a blank rectangle: a canvas that draws nothing looks like a broken document.
            guard let view = mediaPlayerFactory(document) else {
                throw ExtensionNodeRenderer.RenderError.mediaPlayerUnavailable
            }
            view.translatesAutoresizingMaskIntoConstraints = false
            view.setAccessibilityIdentifier("extension.media.\(document.id)")
            return view

        case .status(let text, let role):
            let label = NSTextField(labelWithString: text)
            label.applyFont(.control)
            label.textColor = statusColor(for: role)
            label.lineBreakMode = .byTruncatingTail
            // A compact horizontal reading conventionally puts a name on the left and a state
            // on the right. AppKit's label cell can report a width a few points short once tail
            // truncation is enabled, so a flexible spacer then keeps the slack while a short
            // value such as “In progress” draws as “In progre…”. Preserve bounded states from
            // the font's actual advance; longer prose still truncates instead of widening an
            // extension surface without limit, and low-resistance compact text yields first.
            let font = label.font!
            let measuredWidth = ceil(
                (text as NSString).size(withAttributes: [.font: font]).width
            ) + Design.Spacing.tight
            let readableWidth = label.widthAnchor.constraint(
                greaterThanOrEqualToConstant: min(measuredWidth, 120)
            )
            readableWidth.priority = .defaultHigh
            readableWidth.isActive = true
            label.setAccessibilityIdentifier("extension.status")
            return label

        case .disclosure(let id, let summary, let detail):
            // Built in one pass with the summary, so every button in the revealed level is
            // registered against *this* view's action bridge — see `ExtensionDisclosureNodeView`.
            return ExtensionDisclosureNodeView(
                id: id,
                summary: try makeView(for: summary, parentAxis: parentAxis),
                detail: try detail.map { try makeView(for: $0, parentAxis: .vertical) }
            )

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
            if axis == .vertical {
                for (node, view) in zip(children, views) {
                    switch node {
                    case .textInput, .scene:
                        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
                    default:
                        break
                    }
                }
            }
            return stack
        }
    }

    private func makeScene(_ scene: ExtensionScene) -> SemanticSceneView {
        let items = scene.items.map { item in
            SemanticSceneView.Item(
                id: item.id,
                normalizedFrame: NSRect(
                    x: item.frame.x,
                    y: item.frame.y,
                    width: item.frame.width,
                    height: item.frame.height
                ),
                shape: sceneShape(item.shape),
                color: sceneColor(item.color),
                label: item.label,
                detail: item.detail,
                accessibilityLabel: item.accessibilityLabel ?? item.label ?? item.id,
                accessibilityValue: item.accessibilityValue ?? item.detail,
                isEnabled: item.isEnabled,
                isSelected: item.isSelected,
                onActivate: item.actionID.map { actionID in
                    { [weak self] in
                        self?.onEvent(actionID, .string(item.id))
                    }
                }
            )
        }
        let view = SemanticSceneView(
            accessibilityLabel: scene.accessibilityLabel,
            items: items
        )
        view.heightAnchor.constraint(
            equalTo: view.widthAnchor,
            multiplier: 1 / scene.preferredAspectRatio
        ).isActive = true
        view.setAccessibilityIdentifier("extension.scene")
        return view
    }

    private func sceneShape(_ shape: ExtensionSceneShape) -> SemanticSceneView.Item.Shape {
        switch shape {
        case .rectangle: .rectangle
        case .roundedRectangle: .roundedRectangle
        case .ellipse: .ellipse
        }
    }

    private func sceneColor(_ color: ExtensionSceneColorRole) -> SemanticSceneView.Item.Color {
        switch color {
        case .neutral: .neutral
        case .accent: .accent
        case .positive: .positive
        case .warning: .warning
        case .negative: .negative
        case .category1: .category(0)
        case .category2: .category(1)
        case .category3: .category(2)
        case .category4: .category(3)
        case .category5: .category(4)
        case .category6: .category(5)
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
        onEvent(action, nil)
    }

    @objc private func textInputSubmitted(_ sender: ThemedTextField) {
        guard let action = actionsByTextInput[ObjectIdentifier(sender)] else { return }
        onEvent(action, .string(sender.stringValue))
    }

    @objc private func pickerChanged(_ sender: ThemedPopUp) {
        guard let action = actionsByPicker[ObjectIdentifier(sender)],
              let value = sender.selectedItem?.representedValue as? String else { return }
        onEvent(action, .string(value))
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

import AppKit

/// A host-rendered scene for bounded, semantic data visualizations.
///
/// Callers supply normalized geometry and meaning, never drawing code. The same component can
/// render treemaps, heatmaps, bars, timeline blocks, scatter points and bubbles while the design
/// system owns colour, type, hover, focus, pointer behavior and accessibility.
@MainActor
final class SemanticSceneView: NSView, ThemedComponent {

    struct Item {
        enum Shape {
            case rectangle
            case roundedRectangle
            case ellipse
        }

        enum Color {
            case neutral
            case accent
            case positive
            case warning
            case negative
            case category(Int)
        }

        let id: String
        let parentID: String?
        let normalizedFrame: NSRect
        let shape: Shape
        let color: Color
        let label: String?
        let detail: String?
        let accessibilityLabel: String
        let accessibilityValue: String?
        let isEnabled: Bool
        let isSelected: Bool
        let onActivate: (() -> Void)?

        init(
            id: String,
            parentID: String? = nil,
            normalizedFrame: NSRect,
            shape: Shape,
            color: Color,
            label: String?,
            detail: String?,
            accessibilityLabel: String,
            accessibilityValue: String?,
            isEnabled: Bool,
            isSelected: Bool,
            onActivate: (() -> Void)?
        ) {
            self.id = id
            self.parentID = parentID
            self.normalizedFrame = normalizedFrame
            self.shape = shape
            self.color = color
            self.label = label
            self.detail = detail
            self.accessibilityLabel = accessibilityLabel
            self.accessibilityValue = accessibilityValue
            self.isEnabled = isEnabled
            self.isSelected = isSelected
            self.onActivate = onActivate
        }
    }

    private enum Layout {
        static let itemGap: CGFloat = 2
    }

    private var themeRedraw: ThemeRedraw?
    private let markViews: [SemanticSceneMarkControl]

    override var isFlipped: Bool { true }

    init(accessibilityLabel: String, items: [Item]) {
        markViews = items.map(SemanticSceneMarkControl.init(item:))
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        themeRedraw = ThemeRedraw(self)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(accessibilityLabel)
        setAccessibilityIdentifier("semantic-scene")

        for mark in markViews {
            addSubview(mark)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        for mark in markViews {
            let normalized = mark.item.normalizedFrame
            let frame = NSRect(
                x: normalized.minX * bounds.width,
                y: normalized.minY * bounds.height,
                width: normalized.width * bounds.width,
                height: normalized.height * bounds.height
            )
            let inset = min(
                Layout.itemGap / 2,
                max(0, min(frame.width, frame.height) / 4)
            )
            mark.frame = frame.insetBy(dx: inset, dy: inset)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        ThemedSurface.draw(
            bounds,
            fill: Design.Surface.panel,
            border: Design.Surface.border,
            radius: Design.Radius.panel
        )
    }
}

/// A semantic scene whose marks form one rooted hierarchy.
///
/// The producer still supplies normalized geometry; this host component owns navigation through
/// it. A directory-like mark zooms locally without a process round trip, the current branch is a
/// native breadcrumb, and activating a leaf keeps the ordinary scene action contract.
@MainActor
final class SemanticHierarchySceneView: NSView, ThemedComponent {

    private let accessibilityTitle: String
    private let rootID: String
    private let items: [SemanticSceneView.Item]
    private let itemByID: [String: SemanticSceneView.Item]
    private let childrenByParent: [String: [String]]
    private let content = NSStackView()
    private let breadcrumb = NSStackView()
    private let canvasHost = NSView()
    private var canvas: SemanticSceneView?
    private var focusID: String
    private var breadcrumbTargets: [ObjectIdentifier: String] = [:]

    override var acceptsFirstResponder: Bool { true }

    init(
        accessibilityLabel: String,
        rootID: String,
        preferredAspectRatio: Double,
        items: [SemanticSceneView.Item]
    ) {
        self.accessibilityTitle = accessibilityLabel
        self.rootID = rootID
        self.items = items
        self.itemByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        self.childrenByParent = Dictionary(grouping: items.compactMap { item in
            item.parentID.map { ($0, item.id) }
        }, by: \.0).mapValues { $0.map(\.1) }
        self.focusID = rootID
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(accessibilityLabel)
        setAccessibilityIdentifier("semantic-scene.hierarchy")

        breadcrumb.orientation = .horizontal
        breadcrumb.alignment = .centerY
        breadcrumb.spacing = Design.Spacing.tight
        breadcrumb.setContentHuggingPriority(.defaultHigh, for: .vertical)

        canvasHost.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = Design.Spacing.small
        content.addArrangedSubview(breadcrumb)
        content.addArrangedSubview(canvasHost)
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            breadcrumb.widthAnchor.constraint(equalTo: content.widthAnchor),
            canvasHost.widthAnchor.constraint(equalTo: content.widthAnchor),
            canvasHost.heightAnchor.constraint(
                equalTo: canvasHost.widthAnchor,
                multiplier: 1 / preferredAspectRatio
            )
        ])
        renderFocus(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func keyDown(with event: NSEvent) {
        let isBack = event.keyCode == 53 || event.keyCode == 123
        if isBack, let parentID = itemByID[focusID]?.parentID {
            focus(on: parentID)
        } else {
            super.keyDown(with: event)
        }
    }

    private func renderFocus(animated: Bool) {
        guard let focus = itemByID[focusID] else { return }
        let visible = items.enumerated().compactMap { index, item -> (Int, Int, SemanticSceneView.Item)? in
            guard let depth = descendantDepth(of: item.id, from: focusID) else { return nil }
            return (depth, index, transformed(item, relativeTo: focus, depth: depth))
        }.sorted {
            $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0
        }.map(\.2)

        let replacement = SemanticSceneView(
            accessibilityLabel: accessibilityTitle,
            items: visible
        )
        replacement.translatesAutoresizingMaskIntoConstraints = false
        canvasHost.addSubview(replacement)
        NSLayoutConstraint.activate([
            replacement.topAnchor.constraint(equalTo: canvasHost.topAnchor),
            replacement.bottomAnchor.constraint(equalTo: canvasHost.bottomAnchor),
            replacement.leadingAnchor.constraint(equalTo: canvasHost.leadingAnchor),
            replacement.trailingAnchor.constraint(equalTo: canvasHost.trailingAnchor)
        ])

        let outgoing = canvas
        canvas = replacement
        rebuildBreadcrumb()
        guard animated, Design.Motion.standard > 0 else {
            outgoing?.removeFromSuperview()
            return
        }
        replacement.alphaValue = 0
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Design.Motion.standard
            replacement.animator().alphaValue = 1
            outgoing?.animator().alphaValue = 0
        }, completionHandler: {
            outgoing?.removeFromSuperview()
        })
    }

    private func transformed(
        _ item: SemanticSceneView.Item,
        relativeTo focus: SemanticSceneView.Item,
        depth: Int
    ) -> SemanticSceneView.Item {
        let frame = item.normalizedFrame
        let focusFrame = focus.normalizedFrame
        let normalized = NSRect(
            x: (frame.minX - focusFrame.minX) / focusFrame.width,
            y: (frame.minY - focusFrame.minY) / focusFrame.height,
            width: frame.width / focusFrame.width,
            height: frame.height / focusFrame.height
        )
        let hasChildren = childrenByParent[item.id]?.isEmpty == false
        let parentID = item.parentID
        let activation: (() -> Void)?
        if item.id == focusID {
            activation = parentID.map { parentID in
                { [weak self] in self?.focus(on: parentID) }
            }
        } else if hasChildren {
            activation = { [weak self] in self?.focus(on: item.id) }
        } else {
            activation = item.onActivate
        }
        // Keep all descendant geometry visible, but label only this focus's immediate children.
        // Deeper names arrive on hover and become full labels after zooming that branch. Painting
        // every ancestry level at once makes a correct circle packing read like overprinted text.
        let showsVisualLabel = depth == 1
        return SemanticSceneView.Item(
            id: item.id,
            parentID: item.parentID,
            normalizedFrame: normalized,
            shape: item.shape,
            color: item.color,
            label: showsVisualLabel ? item.label : nil,
            detail: showsVisualLabel ? item.detail : nil,
            accessibilityLabel: item.accessibilityLabel,
            accessibilityValue: item.accessibilityValue,
            isEnabled: item.isEnabled,
            isSelected: item.isSelected || item.id == focusID,
            onActivate: activation
        )
    }

    private func descendantDepth(of itemID: String, from ancestorID: String) -> Int? {
        var cursor = itemID
        var depth = 0
        for _ in 0...items.count {
            if cursor == ancestorID { return depth }
            guard let parentID = itemByID[cursor]?.parentID else { return nil }
            cursor = parentID
            depth += 1
        }
        return nil
    }

    private func focus(on itemID: String) {
        guard itemID != focusID, itemByID[itemID] != nil else { return }
        focusID = itemID
        renderFocus(animated: true)
        window?.makeFirstResponder(self)
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    private func rebuildBreadcrumb() {
        breadcrumb.arrangedSubviews.forEach {
            breadcrumb.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        breadcrumbTargets.removeAll(keepingCapacity: true)

        for (index, item) in focusPath().enumerated() {
            if index > 0 {
                let separator = NSTextField(labelWithString: "›")
                separator.applyFont(.detail())
                separator.textColor = Design.Text.tertiary
                separator.setAccessibilityElement(false)
                breadcrumb.addArrangedSubview(separator)
            }
            if item.id == focusID {
                let label = NSTextField(labelWithString: item.label ?? item.accessibilityLabel)
                label.applyFont(.control)
                label.textColor = Design.Text.label
                label.lineBreakMode = .byTruncatingMiddle
                label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                label.setAccessibilityIdentifier("semantic-scene.breadcrumb.current")
                breadcrumb.addArrangedSubview(label)
            } else {
                let button = ThemedButton(
                    title: item.label ?? item.accessibilityLabel,
                    target: self,
                    action: #selector(breadcrumbPressed(_:))
                )
                button.emphasis = .tertiary
                button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                button.setAccessibilityIdentifier("semantic-scene.breadcrumb.\(item.id)")
                breadcrumbTargets[ObjectIdentifier(button)] = item.id
                breadcrumb.addArrangedSubview(button)
            }
        }
    }

    private func focusPath() -> [SemanticSceneView.Item] {
        var result: [SemanticSceneView.Item] = []
        var cursor: String? = focusID
        for _ in 0...items.count {
            guard let id = cursor, let item = itemByID[id] else { break }
            result.append(item)
            cursor = item.parentID
        }
        return result.reversed()
    }

    @objc private func breadcrumbPressed(_ sender: ThemedButton) {
        guard let itemID = breadcrumbTargets[ObjectIdentifier(sender)] else { return }
        focus(on: itemID)
    }
}

/// One scene mark is a real native control when it can act, and a real accessibility element
/// when it cannot. It deliberately owns no extension types; the renderer translates the public
/// wire vocabulary at the boundary.
@MainActor
private final class SemanticSceneMarkControl: ThemedControl {

    fileprivate let item: SemanticSceneView.Item
    private var isPressed = false {
        didSet { needsDisplay = true }
    }

    override var acceptsFirstResponder: Bool {
        item.onActivate != nil && isEnabled
    }

    init(item: SemanticSceneView.Item) {
        self.item = item
        super.init(frame: .zero)
        isEnabled = item.isEnabled
        setAccessibilityIdentifier("semantic-scene.item.\(item.id)")
        setAccessibilityLabel(item.accessibilityLabel)
        if let value = item.accessibilityValue {
            setAccessibilityValue(value)
        }
        setAccessibilitySelected(item.isSelected)
        toolTip = [
            item.label ?? item.accessibilityLabel,
            item.detail ?? item.accessibilityValue
        ].compactMap { $0 }.joined(separator: "\n")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// A mark that acts is pressable geometry rather than a control's plate, so it takes the
    /// hand; one that does not act is still opaque, so it takes the arrow. See `PointerClaiming`.
    override var restingPointer: NSCursor? {
        item.onActivate != nil && isEnabled ? .pointingHand : .arrow
    }

    override func mouseDown(with event: NSEvent) {
        guard item.onActivate != nil, isEnabled else { return }
        isPressed = true
        window?.makeFirstResponder(self)
    }

    override func mouseDragged(with event: NSEvent) {
        guard item.onActivate != nil, isEnabled else { return }
        isPressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        let shouldActivate = isPressed
            && bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        if shouldActivate { _ = performPrimaryAction() }
    }

    override func performPrimaryAction() -> Bool {
        guard let onActivate = item.onActivate, isEnabled else { return false }
        onActivate()
        return true
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        item.onActivate == nil ? .group : .button
    }

    override func accessibilityPerformPress() -> Bool {
        performPrimaryAction()
    }

    override func draw(_ dirtyRect: NSRect) {
        let base = color(for: item.color)
        let emphasized = item.isSelected || isHovered || isPressed || hasKeyboardFocus
        let fillAlpha: CGFloat = emphasized ? 0.28 : 0.16
        let borderAlpha: CGFloat = emphasized ? 0.95 : 0.58
        let path = shapePath()

        base.withAlphaComponent(isEnabled ? fillAlpha : fillAlpha * 0.45).setFill()
        path.fill()
        base.withAlphaComponent(isEnabled ? borderAlpha : borderAlpha * 0.45).setStroke()
        path.lineWidth = item.isSelected ? 2 : Design.Radius.border
        path.stroke()

        drawLabels()
        drawKeyboardFocus(
            around: ThemedSurface.Shape(
                rect: bounds,
                radius: cornerRadius
            ),
            color: base
        )
    }

    private var cornerRadius: CGFloat {
        switch item.shape {
        case .rectangle:
            0
        case .roundedRectangle:
            Design.Radius.control(fitting: bounds.size)
        case .ellipse:
            min(bounds.width, bounds.height) / 2
        }
    }

    private func shapePath() -> NSBezierPath {
        switch item.shape {
        case .rectangle:
            NSBezierPath(rect: bounds)
        case .roundedRectangle:
            NSBezierPath(
                roundedRect: bounds,
                xRadius: cornerRadius,
                yRadius: cornerRadius
            )
        case .ellipse:
            NSBezierPath(ovalIn: bounds)
        }
    }

    private func color(for role: SemanticSceneView.Item.Color) -> NSColor {
        switch role {
        case .neutral:
            Design.Text.secondary
        case .accent:
            Design.Surface.accent
        case .positive:
            Design.Status.positive
        case .warning:
            Design.Status.warning
        case .negative:
            Design.Status.negative
        case .category(let index):
            Design.Categorical.hue(at: index).color
        }
    }

    private func drawLabels() {
        guard bounds.width >= 34, bounds.height >= 22, let label = item.label else { return }
        let inset = min(Design.Spacing.small, max(3, min(bounds.width, bounds.height) / 8))
        let textRect = bounds.insetBy(dx: inset, dy: inset)
        guard textRect.width > 0, textRect.height > 0 else { return }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let labelFont = Design.Typography.control()
        let labelHeight = ceil(labelFont.boundingRectForFont.height)
        let labelRect = NSRect(
            x: textRect.minX,
            y: textRect.maxY - labelHeight,
            width: textRect.width,
            height: min(labelHeight, textRect.height)
        )
        (label as NSString).draw(
            in: labelRect,
            withAttributes: [
                .font: labelFont,
                .foregroundColor: Design.Text.label,
                .paragraphStyle: paragraph
            ]
        )

        guard let detail = item.detail,
              bounds.height >= 42,
              textRect.height > labelHeight + 2 else { return }
        let detailFont = Design.Typography.detail()
        let detailHeight = ceil(detailFont.boundingRectForFont.height)
        let detailRect = NSRect(
            x: textRect.minX,
            y: labelRect.minY - detailHeight - 2,
            width: textRect.width,
            height: detailHeight
        )
        (detail as NSString).draw(
            in: detailRect,
            withAttributes: [
                .font: detailFont,
                .foregroundColor: Design.Text.secondary,
                .paragraphStyle: paragraph
            ]
        )
    }
}

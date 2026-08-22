import AppKit

/// A host-rendered scene for bounded, semantic data visualizations.
///
/// Callers supply normalized geometry and meaning, never drawing code. The same component can
/// render treemaps, heatmaps, bars, timeline blocks, scatter points and bubbles while the design
/// system owns colour, type, hover, focus, pointer behavior and accessibility.
///
/// An ordinary scene has tens of marks and the public contract permits 500. Marks therefore stay
/// values drawn by one control rather than becoming one AppKit view, layer and tracking area each.
/// Accessibility keeps one native virtual element per mark, created only when AppKit asks for the
/// scene's children. Pointer movement consults a fixed spatial index instead of scanning the scene.
@MainActor
final class SemanticSceneView: ThemedControl {

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

    private var items: [Item]
    private var markFrames: [NSRect]
    private var hitIndex: SemanticSceneHitIndex
    private var actionableIndices: [Int]
    private var accessibilityMarks: [SemanticSceneAccessibilityMark]?
    private var movementTrackingArea: NSTrackingArea?
    private var hoveredIndex: Int? {
        didSet {
            guard hoveredIndex != oldValue else { return }
            toolTip = hoveredIndex.map(tooltip(at:))
            refreshPointerClaims()
            needsDisplay = true
        }
    }
    private var pressedIndex: Int? {
        didSet {
            if pressedIndex != oldValue { needsDisplay = true }
        }
    }
    private var pressOriginIndex: Int?
    private var keyboardIndex: Int? {
        didSet {
            if keyboardIndex != oldValue { needsDisplay = true }
        }
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { firstActionableIndex != nil }
    override var restingPointer: NSCursor? {
        guard let hoveredIndex, isActionable(hoveredIndex) else { return .arrow }
        return .pointingHand
    }

    init(accessibilityLabel: String, items: [Item]) {
        self.items = items
        self.markFrames = Array(repeating: .zero, count: items.count)
        self.hitIndex = SemanticSceneHitIndex(items: items)
        self.actionableIndices = items.indices.filter {
            items[$0].isEnabled && items[$0].onActivate != nil
        }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(accessibilityLabel)
        setAccessibilityIdentifier("semantic-scene")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        markFrames = items.map { item in
            let normalized = item.normalizedFrame
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
            return frame.insetBy(dx: inset, dy: inset)
        }
        if hoveredIndex != nil {
            guard isPointerInside, !isPointerCovered, let window else {
                hoveredIndex = nil
                return
            }
            hoveredIndex = markIndex(at: convert(window.mouseLocationOutsideOfEventStream, from: nil))
        }
    }

    func update(items: [Item]) {
        self.items = items
        markFrames = Array(repeating: .zero, count: items.count)
        hitIndex = SemanticSceneHitIndex(items: items)
        actionableIndices = items.indices.filter {
            items[$0].isEnabled && items[$0].onActivate != nil
        }
        accessibilityMarks = nil
        hoveredIndex = nil
        pressedIndex = nil
        pressOriginIndex = nil
        keyboardIndex = nil
        needsLayout = true
        needsDisplay = true
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let movementTrackingArea { removeTrackingArea(movementTrackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        movementTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        guard let point = uncoveredPointerLocation(in: event) else {
            hoveredIndex = nil
            return
        }
        hoveredIndex = markIndex(at: point)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoveredIndex = nil
        pressedIndex = nil
    }

    override func mouseDown(with event: NSEvent) {
        let index = markIndex(at: convert(event.locationInWindow, from: nil))
        guard let index, isActionable(index) else { return }
        keyboardIndex = index
        pressOriginIndex = index
        pressedIndex = index
        window?.makeFirstResponder(self)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressOriginIndex else { return }
        let point = convert(event.locationInWindow, from: nil)
        pressedIndex = markFrames[pressOriginIndex].contains(point) ? pressOriginIndex : nil
    }

    override func mouseUp(with event: NSEvent) {
        guard let pressOriginIndex else { return }
        let point = convert(event.locationInWindow, from: nil)
        self.pressOriginIndex = nil
        self.pressedIndex = nil
        if markFrames[pressOriginIndex].contains(point) {
            _ = activate(at: pressOriginIndex)
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case String(UnicodeScalar(NSLeftArrowFunctionKey)!),
             String(UnicodeScalar(NSUpArrowFunctionKey)!):
            moveKeyboardFocus(by: -1)
        case String(UnicodeScalar(NSRightArrowFunctionKey)!),
             String(UnicodeScalar(NSDownArrowFunctionKey)!):
            moveKeyboardFocus(by: 1)
        default:
            super.keyDown(with: event)
        }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted, keyboardIndex == nil { keyboardIndex = firstActionableIndex }
        return accepted
    }

    override func performPrimaryAction() -> Bool {
        guard let index = keyboardIndex ?? firstActionableIndex else { return false }
        return activate(at: index)
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityPerformPress() -> Bool { performPrimaryAction() }

    override func accessibilityChildren() -> [Any]? {
        if accessibilityMarks == nil {
            accessibilityMarks = items.indices.map {
                SemanticSceneAccessibilityMark(owner: self, index: $0)
            }
        }
        return accessibilityMarks
    }

    override func draw(_ dirtyRect: NSRect) {
        ThemedSurface.draw(
            bounds,
            fill: Design.Surface.panel,
            border: Design.Surface.border,
            radius: Design.Radius.panel
        )
        for index in items.indices where markFrames.indices.contains(index) {
            drawMark(at: index)
        }
    }

    fileprivate func accessibilityFrame(at index: Int) -> NSRect {
        guard markFrames.indices.contains(index), let window else { return .zero }
        let frameInWindow = convert(markFrames[index], to: nil)
        return window.convertToScreen(frameInWindow)
    }

    fileprivate func accessibilityItem(at index: Int) -> Item? {
        items.indices.contains(index) ? items[index] : nil
    }

    fileprivate func accessibilityActivate(at index: Int) -> Bool {
        keyboardIndex = index
        return activate(at: index)
    }

    private var firstActionableIndex: Int? {
        actionableIndices.first
    }

    private func isActionable(_ index: Int) -> Bool {
        items.indices.contains(index) && items[index].isEnabled && items[index].onActivate != nil
    }

    private func activate(at index: Int) -> Bool {
        guard isActionable(index), let action = items[index].onActivate else { return false }
        action()
        return true
    }

    private func moveKeyboardFocus(by delta: Int) {
        guard !actionableIndices.isEmpty else { return }
        guard let keyboardIndex,
              let position = actionableIndices.firstIndex(of: keyboardIndex) else {
            self.keyboardIndex = actionableIndices[
                delta < 0 ? actionableIndices.count - 1 : 0
            ]
            return
        }
        let next = min(max(position + delta, 0), actionableIndices.count - 1)
        self.keyboardIndex = actionableIndices[next]
    }

    private func markIndex(at point: NSPoint) -> Int? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let normalized = NSPoint(x: point.x / bounds.width, y: point.y / bounds.height)
        for index in hitIndex.candidates(at: normalized).reversed()
        where markFrames.indices.contains(index) && markFrames[index].contains(point) {
            return index
        }
        return nil
    }

    private func tooltip(at index: Int) -> String {
        let item = items[index]
        return [
            item.label ?? item.accessibilityLabel,
            item.detail ?? item.accessibilityValue
        ].compactMap { $0 }.joined(separator: "\n")
    }

    private func drawMark(at index: Int) {
        let item = items[index]
        let frame = markFrames[index]
        let base = color(for: item.color)
        let emphasized = item.isSelected
            || hoveredIndex == index
            || pressedIndex == index
            || (hasKeyboardFocus && keyboardIndex == index)
        let fillAlpha: CGFloat = emphasized ? 0.28 : 0.16
        let borderAlpha: CGFloat = emphasized ? 0.95 : 0.58
        let path = shapePath(for: item.shape, in: frame)

        base.withAlphaComponent(item.isEnabled ? fillAlpha : fillAlpha * 0.45).setFill()
        path.fill()
        base.withAlphaComponent(item.isEnabled ? borderAlpha : borderAlpha * 0.45).setStroke()
        path.lineWidth = item.isSelected ? 2 : Design.Radius.border
        path.stroke()

        drawLabels(for: item, in: frame)
        if keyboardIndex == index {
            drawKeyboardFocus(
                around: ThemedSurface.Shape(
                    rect: frame,
                    radius: cornerRadius(for: item.shape, in: frame)
                ),
                color: base
            )
        }
    }

    private func cornerRadius(for shape: Item.Shape, in frame: NSRect) -> CGFloat {
        switch shape {
        case .rectangle:
            0
        case .roundedRectangle:
            Design.Radius.control(fitting: frame.size)
        case .ellipse:
            min(frame.width, frame.height) / 2
        }
    }

    private func shapePath(for shape: Item.Shape, in frame: NSRect) -> NSBezierPath {
        switch shape {
        case .rectangle:
            NSBezierPath(rect: frame)
        case .roundedRectangle:
            NSBezierPath(
                roundedRect: frame,
                xRadius: cornerRadius(for: shape, in: frame),
                yRadius: cornerRadius(for: shape, in: frame)
            )
        case .ellipse:
            NSBezierPath(ovalIn: frame)
        }
    }

    private func color(for role: Item.Color) -> NSColor {
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

    private func drawLabels(for item: Item, in frame: NSRect) {
        guard frame.width >= 34, frame.height >= 22, let label = item.label else { return }
        let inset = min(Design.Spacing.small, max(3, min(frame.width, frame.height) / 8))
        let textRect = frame.insetBy(dx: inset, dy: inset)
        guard textRect.width > 0, textRect.height > 0 else { return }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let labelFont = Design.Typography.control()
        let labelHeight = ceil(labelFont.boundingRectForFont.height)
        let labelRect = NSRect(
            x: textRect.minX,
            y: textRect.minY,
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
              frame.height >= 42,
              textRect.height > labelHeight + 2 else { return }
        let detailFont = Design.Typography.detail()
        let detailHeight = ceil(detailFont.boundingRectForFont.height)
        let detailRect = NSRect(
            x: textRect.minX,
            y: labelRect.maxY + 2,
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
    private let hierarchyIndex: SemanticSceneHierarchyIndex
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
        self.hierarchyIndex = SemanticSceneHierarchyIndex(items: items)
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
        let visible = hierarchyIndex.traversal(focusedOn: focusID).visibleItems.map {
            transformed(items[$0.index], relativeTo: focus, depth: $0.depth)
        }

        let renderedCanvas: SemanticSceneView
        if let canvas {
            canvas.update(items: visible)
            renderedCanvas = canvas
        } else {
            let newCanvas = SemanticSceneView(
                accessibilityLabel: accessibilityTitle,
                items: visible
            )
            newCanvas.translatesAutoresizingMaskIntoConstraints = false
            canvasHost.addSubview(newCanvas)
            NSLayoutConstraint.activate([
                newCanvas.topAnchor.constraint(equalTo: canvasHost.topAnchor),
                newCanvas.bottomAnchor.constraint(equalTo: canvasHost.bottomAnchor),
                newCanvas.leadingAnchor.constraint(equalTo: canvasHost.leadingAnchor),
                newCanvas.trailingAnchor.constraint(equalTo: canvasHost.trailingAnchor)
            ])
            canvas = newCanvas
            renderedCanvas = newCanvas
        }
        rebuildBreadcrumb()
        guard animated, Design.Motion.standard > 0 else { return }
        // Navigation changes the value model on the one retained canvas. A quiet fade confirms
        // the zoom without retaining the outgoing 500-mark tree beside its replacement.
        renderedCanvas.alphaValue = 0.72
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Design.Motion.standard
            renderedCanvas.animator().alphaValue = 1
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
        let hasChildren = hierarchyIndex.hasChildren(item.id)
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

/// Fixed normalized-space buckets keep pointer movement proportional to the marks near the
/// pointer. Buckets are a candidate index, not hit geometry; the canvas applies the exact inset
/// frame before accepting a mark. Array order is retained so the last painted mark still wins.
@MainActor
private struct SemanticSceneHitIndex {
    private static let dimension = 16
    private var buckets: [[Int]]

    init(items: [SemanticSceneView.Item]) {
        buckets = Array(repeating: [], count: Self.dimension * Self.dimension)
        for (index, item) in items.enumerated() {
            let frame = item.normalizedFrame
            let minimumColumn = Self.cell(for: frame.minX)
            let maximumColumn = Self.cell(for: frame.maxX)
            let minimumRow = Self.cell(for: frame.minY)
            let maximumRow = Self.cell(for: frame.maxY)
            for row in minimumRow...maximumRow {
                for column in minimumColumn...maximumColumn {
                    buckets[row * Self.dimension + column].append(index)
                }
            }
        }
    }

    func candidates(at point: NSPoint) -> [Int] {
        guard (0...1).contains(point.x), (0...1).contains(point.y) else { return [] }
        let column = Self.cell(for: point.x)
        let row = Self.cell(for: point.y)
        return buckets[row * Self.dimension + column]
    }

    private static func cell(for coordinate: CGFloat) -> Int {
        min(max(Int(floor(coordinate * CGFloat(dimension))), 0), dimension - 1)
    }
}

/// The hierarchy's value index. Focus changes are explicit navigation rather than a hot callback,
/// but the 500-mark stress case still gets one child traversal plus one source-order scan. The old
/// implementation walked every mark's full ancestor path, making a deep hierarchy quadratic.
@MainActor
struct SemanticSceneHierarchyIndex {
    struct VisibleItem {
        let index: Int
        let depth: Int
    }

    struct Traversal {
        let visibleItems: [VisibleItem]
        /// The exact number of item-sized steps, exposed so the stress test pins linear work.
        let workCount: Int
    }

    private let items: [SemanticSceneView.Item]
    private let indexByID: [String: Int]
    private let childrenByParent: [String: [Int]]

    init(items: [SemanticSceneView.Item]) {
        self.items = items
        self.indexByID = Dictionary(uniqueKeysWithValues: items.enumerated().map {
            ($0.element.id, $0.offset)
        })
        self.childrenByParent = Dictionary(grouping: items.enumerated().compactMap {
            index, item in item.parentID.map { ($0, index) }
        }, by: \.0).mapValues { $0.map(\.1) }
    }

    func hasChildren(_ itemID: String) -> Bool {
        childrenByParent[itemID]?.isEmpty == false
    }

    func traversal(focusedOn focusID: String) -> Traversal {
        guard let focusIndex = indexByID[focusID] else {
            return Traversal(visibleItems: [], workCount: 0)
        }
        var depths = Array(repeating: -1, count: items.count)
        var stack = [(focusIndex, 0)]
        var traversed = 0
        var maximumDepth = 0

        while let (index, depth) = stack.popLast() {
            guard depths[index] < 0 else { continue }
            depths[index] = depth
            maximumDepth = max(maximumDepth, depth)
            traversed += 1
            let children = childrenByParent[items[index].id] ?? []
            for child in children.reversed() {
                stack.append((child, depth + 1))
            }
        }

        var byDepth = Array(repeating: [VisibleItem](), count: maximumDepth + 1)
        for index in items.indices {
            let depth = depths[index]
            if depth >= 0 { byDepth[depth].append(VisibleItem(index: index, depth: depth)) }
        }
        let visible = byDepth.flatMap { $0 }
        return Traversal(
            visibleItems: visible,
            workCount: traversed + items.count + visible.count
        )
    }
}

/// A mark stays individually native to VoiceOver without becoming an AppKit view. Static semantic
/// fields are captured when the canvas exposes its children; geometry remains live across layout.
@MainActor
private final class SemanticSceneAccessibilityMark: NSAccessibilityElement {
    private weak var owner: SemanticSceneView?
    private let index: Int

    init(owner: SemanticSceneView, index: Int) {
        self.owner = owner
        self.index = index
        super.init()
        if let item = owner.accessibilityItem(at: index) {
            setAccessibilityParent(owner)
            setAccessibilityRole(item.onActivate == nil ? .group : .button)
            setAccessibilityIdentifier("semantic-scene.item.\(item.id)")
            setAccessibilityLabel(item.accessibilityLabel)
            setAccessibilityValue(item.accessibilityValue)
            setAccessibilityEnabled(item.isEnabled)
            setAccessibilitySelected(item.isSelected)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override nonisolated func accessibilityFrame() -> NSRect {
        MainActor.assumeIsolated {
            owner?.accessibilityFrame(at: index) ?? .zero
        }
    }

    override nonisolated func accessibilityPerformPress() -> Bool {
        MainActor.assumeIsolated {
            owner?.accessibilityActivate(at: index) ?? false
        }
    }
}

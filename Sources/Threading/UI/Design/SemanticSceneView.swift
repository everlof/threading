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

        enum Color: Hashable {
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
        /// Nil for ordinary scenes; zero is the focused hierarchy circle.
        let hierarchyDepth: Int?
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
            hierarchyDepth: Int? = nil,
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
            self.hierarchyDepth = hierarchyDepth
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
            invalidateMarks(oldValue, hoveredIndex)
        }
    }
    private var pressedIndex: Int? {
        didSet {
            guard pressedIndex != oldValue else { return }
            invalidateMarks(oldValue, pressedIndex)
        }
    }
    private var pressOriginIndex: Int?
    /// Hierarchy fills for the draw in progress. Every mark at the same depth, colour, enabled
    /// and emphasis state paints the identical colour, and deriving one costs three surface
    /// composites and two Oklab round trips inside an appearance push — so a 500-mark scene was
    /// paying that five hundred times per repaint, and the pointer crossing one mark repainted
    /// the lot. Cleared at the top of `draw(_:)`, which is the only place it is read, so a theme
    /// or appearance change cannot leave a stale colour behind for the next frame to use.
    private var hierarchyFills: [HierarchyFillKey: NSColor] = [:]
    /// How many of those the last `draw(_:)` had to derive rather than reuse. Exposed for the
    /// same reason `SemanticSceneHierarchyIndex.Traversal.workCount` is: a bound argued for only
    /// in a comment is a bound that quietly stops holding.
    private(set) var derivedHierarchyFillCount = 0
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
        pressedIndex = markContains(point, at: pressOriginIndex) ? pressOriginIndex : nil
    }

    override func mouseUp(with event: NSEvent) {
        guard let pressOriginIndex else { return }
        let point = convert(event.locationInWindow, from: nil)
        self.pressOriginIndex = nil
        self.pressedIndex = nil
        if markContains(point, at: pressOriginIndex) {
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
        hierarchyFills.removeAll(keepingCapacity: true)
        derivedHierarchyFillCount = 0
        ThemedSurface.draw(
            bounds,
            fill: Design.Surface.panel,
            border: Design.Surface.border,
            radius: Design.Radius.panel
        )
        // Marks keep their order, so a partial repaint layers exactly as a whole one does: a
        // parent still paints before the children sitting inside it, and both are clipped to the
        // same dirty rectangle. Anything a mark draws stays inside its own frame, so a mark that
        // does not meet the rectangle has nothing to contribute to it.
        let visible = visibleMarkIndices(in: dirtyRect)
        for index in visible {
            drawMark(at: index)
        }
        // A hierarchy's immediate-child label names the whole region, not whichever empty patch
        // happened to remain after its descendants were packed. Paint those labels as an overlay
        // pass so later child fills cannot erase them. Ordinary scenes keep their mark-local
        // labels because their draw order may itself carry meaning.
        for index in visible where items[index].hierarchyDepth != nil {
            drawLabels(for: items[index], in: markFrames[index])
        }
    }

    private func visibleMarkIndices(in dirtyRect: NSRect) -> [Int] {
        items.indices.filter {
            markFrames.indices.contains($0) && markFrames[$0].intersects(dirtyRect)
        }
    }

    /// Repaint the marks whose appearance changed, and no others. A scene may hold five hundred,
    /// and the pointer crossing from one mark to its neighbour is not a reason to redraw the
    /// other four hundred and ninety-eight. Widened a little because a mark's border is stroked
    /// on its outline, so it lies half outside the frame.
    private func invalidateMarks(_ indices: Int?...) {
        for index in indices.compactMap({ $0 }) where markFrames.indices.contains(index) {
            setNeedsDisplay(markFrames[index].insetBy(dx: -3, dy: -3))
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
        where markContains(point, at: index) {
            return index
        }
        return nil
    }

    /// Whether a mark is under this point — asked of the shape that was painted, not of the
    /// rectangle it was painted in.
    private func markContains(_ point: NSPoint, at index: Int) -> Bool {
        guard items.indices.contains(index), markFrames.indices.contains(index) else {
            return false
        }
        return items[index].shape.contains(point, in: markFrames[index])
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
        if let hierarchyDepth = item.hierarchyDepth {
            drawHierarchyMark(item, depth: hierarchyDepth, at: index, in: frame)
            return
        }
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

    /// Hierarchical circles read as nested opaque regions, not translucent bubbles laid over one
    /// another. The semantic hue survives, but it is mixed into the panel once before painting;
    /// parent and child fills therefore never create a third accidental colour where they meet.
    /// A strong neutral perimeter names the current focus, while internal boundaries stay quiet.
    private func drawHierarchyMark(
        _ item: Item,
        depth: Int,
        at index: Int,
        in frame: NSRect
    ) {
        let base = color(for: item.color)
        let isFocusedBoundary = depth == 0
        // A producer's own selection counts, the way it does for an ordinary mark. Without it a
        // branch the extension marked selected drew identically to every unselected sibling
        // while accessibility went on reporting it as chosen. The focus circle is selected by
        // construction and takes its emphasis from its perimeter instead, so this only ever
        // changes a mark below the focus.
        let isEmphasized = item.isSelected
            || hoveredIndex == index
            || pressedIndex == index
            || (hasKeyboardFocus && keyboardIndex == index)
        let fill = hierarchyFill(
            color: item.color,
            depth: depth,
            isEnabled: item.isEnabled,
            isEmphasized: isEmphasized
        )
        // The reference grammar uses ink-dark construction lines. Black remains the quiet edge
        // on paper and on every lifted region; only an authored near-black fill switches to white
        // so a theme cannot make a branch boundary disappear completely.
        let internalStroke: NSColor = ThemeContrast.ratio(.black, fill) >= 1.28
            ? .black
            : .white
        let stroke = isFocusedBoundary ? Design.Text.label : internalStroke
        let path = shapePath(for: item.shape, in: frame)

        fill.setFill()
        path.fill()
        stroke.setStroke()
        path.lineWidth = isFocusedBoundary
            ? max(2.25, Design.Radius.border)
            : max(item.isSelected ? 1.75 : 1.15, Design.Radius.border)
        path.stroke()

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

    /// Mix hierarchy colours in Oklab so lightness and colourfulness can be controlled
    /// independently. A straight alpha or sRGB blend left Cyberpunk's blue and magenta parents
    /// looking like chart series; the inspiration uses brighter-but-muted parent land masses and
    /// lets the smaller leaves carry most of the colour.
    private func hierarchyFill(
        color: Item.Color,
        depth: Int,
        isEnabled: Bool,
        isEmphasized: Bool
    ) -> NSColor {
        // Every mark sharing these four answers paints the identical colour, so derive it once
        // per repaint. The key buckets depth the way the shares below do: past the second level
        // the treatment stops changing, and a deep branch must not mint a fresh entry per level.
        let key = HierarchyFillKey(
            color: color,
            depth: min(depth, 2),
            isEnabled: isEnabled,
            isEmphasized: isEmphasized
        )
        if let cached = hierarchyFills[key] { return cached }
        let resolved = derivedHierarchyFill(key: key, base: self.color(for: color))
        hierarchyFills[key] = resolved
        derivedHierarchyFillCount += 1
        return resolved
    }

    private struct HierarchyFillKey: Hashable {
        let color: Item.Color
        let depth: Int
        let isEnabled: Bool
        let isEmphasized: Bool
    }

    private func derivedHierarchyFill(key: HierarchyFillKey, base: NSColor) -> NSColor {
        let depth = key.depth
        let isEnabled = key.isEnabled
        let isEmphasized = key.isEmphasized
        // `panel` and the semantic palette can both be dynamic System colours. Oklab conversion
        // resolves a dynamic NSColor against the *current drawing* appearance, which is not
        // necessarily this view's appearance during an offscreen evidence render. Resolve the
        // whole derivation explicitly or light and dark captures can exchange their fills.
        var resolved = NSColor.clear
        effectiveAppearance.performAsCurrentDrawingAppearance {
            // System's panel is a low-alpha label wash. Measure the opaque colour AppKit
            // actually paints, rather than treating that wash's white/black RGB payload as the
            // panel itself and accidentally inverting the hierarchy between appearances.
            let ground = Design.Surface.ground
            let surface = Design.Surface.background.composited(over: ground)
            let panel = Design.Surface.panel.composited(over: surface).oklab
            let semantic = base.oklab
            let restingShares: (lightness: CGFloat, colour: CGFloat)
            switch depth {
            case 0:
                restingShares = (0.20, 0.32)
            case 1:
                restingShares = (0.46, 0.10)
            default:
                restingShares = (0.72, 0.54)
            }
            let enabledShare: CGFloat = isEnabled ? 1 : 0.52
            let emphasis: CGFloat = isEmphasized && depth > 0 ? 0.08 : 0
            let lightnessShare = min(1, restingShares.lightness * enabledShare + emphasis)
            let colourShare = min(1, restingShares.colour * enabledShare + emphasis)

            resolved = NSColor.oklab(
                Oklab(
                    lightness: panel.lightness
                        + (semantic.lightness - panel.lightness) * lightnessShare,
                    a: panel.a + (semantic.a - panel.a) * colourShare,
                    b: panel.b + (semantic.b - panel.b) * colourShare
                )
            )
        }
        return resolved
    }

    private func cornerRadius(for shape: Item.Shape, in frame: NSRect) -> CGFloat {
        shape.cornerRadius(in: frame)
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
        if item.hierarchyDepth != nil {
            drawHierarchyLabels(label: label, detail: item.detail, in: frame)
            return
        }
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

    private func drawHierarchyLabels(label: String, detail: String?, in frame: NSRect) {
        guard frame.width >= 48, frame.height >= 34 else { return }
        let inset = min(Design.Spacing.small, max(4, min(frame.width, frame.height) / 9))
        let textRect = frame.insetBy(dx: inset, dy: inset)
        guard textRect.width > 0, textRect.height > 0 else { return }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let labelFont = Design.Typography.control()
        let labelHeight = ceil(labelFont.boundingRectForFont.height)
        let detailFont = Design.Typography.detail()
        let detailHeight = detail == nil ? 0 : ceil(detailFont.boundingRectForFont.height)
        let detailGap: CGFloat = detail == nil ? 0 : 2
        let blockHeight = min(textRect.height, labelHeight + detailGap + detailHeight)
        let labelRect = NSRect(
            x: textRect.minX,
            y: textRect.midY - blockHeight / 2,
            width: textRect.width,
            height: min(labelHeight, blockHeight)
        )
        (label as NSString).draw(
            in: labelRect,
            withAttributes: [
                .font: labelFont,
                .foregroundColor: Design.Text.label.withAlphaComponent(0.72),
                .paragraphStyle: paragraph
            ]
        )

        guard let detail, blockHeight > labelHeight + detailGap else { return }
        let detailRect = NSRect(
            x: textRect.minX,
            y: labelRect.maxY + detailGap,
            width: textRect.width,
            height: min(detailHeight, textRect.maxY - labelRect.maxY - detailGap)
        )
        (detail as NSString).draw(
            in: detailRect,
            withAttributes: [
                .font: detailFont,
                .foregroundColor: Design.Text.secondary.withAlphaComponent(0.58),
                .paragraphStyle: paragraph
            ]
        )
    }
}

/// The geometry of a mark, kept apart from the control so it can be asserted directly.
///
/// Main-actor because a corner radius is a theme reading, and the theme is main-actor state.
/// Every caller — layout, drawing, hit testing, the tests — is already there.
@MainActor
extension SemanticSceneView.Item.Shape {

    /// The corner radius this shape draws with in `frame`. One owner, because the fill, the
    /// keyboard focus ring and the hit test all have to agree on the same outline.
    func cornerRadius(in frame: NSRect) -> CGFloat {
        switch self {
        case .rectangle:
            0
        case .roundedRectangle:
            min(Design.Radius.control(fitting: frame.size), min(frame.width, frame.height) / 2)
        case .ellipse:
            min(frame.width, frame.height) / 2
        }
    }

    /// Whether `point` is inside the mark this shape draws in `frame`.
    ///
    /// A bounding rectangle is not a mark. A circle covers π/4 of its box, so better than a
    /// fifth of every round mark's rectangle is somewhere the mark is not — and in a hierarchy's
    /// circle packing, where sibling circles are tangent and boxes therefore overlap, those
    /// corners are exactly where the *neighbouring* circles and the parent are the thing on
    /// screen. Testing the rectangle gave the hover highlight, the pointing-hand cursor and the
    /// click to a mark the pointer was demonstrably not over. The packing rule the scene
    /// contract now enforces is about circles; so is this.
    func contains(_ point: NSPoint, in frame: NSRect) -> Bool {
        guard frame.contains(point) else { return false }
        switch self {
        case .rectangle:
            return true
        case .roundedRectangle:
            return isInsideCorners(point, in: frame, radius: cornerRadius(in: frame))
        case .ellipse:
            let semiWidth = frame.width / 2
            let semiHeight = frame.height / 2
            guard semiWidth > 0, semiHeight > 0 else { return false }
            let x = (point.x - frame.midX) / semiWidth
            let y = (point.y - frame.midY) / semiHeight
            return x * x + y * y <= 1
        }
    }

    /// Only the four corner squares can exclude a point from a rounded rectangle: everything
    /// else is in the cross the two inset rectangles make. So the test is the distance from the
    /// nearest point of the inner rectangle the corner arcs are struck from.
    private func isInsideCorners(
        _ point: NSPoint,
        in frame: NSRect,
        radius: CGFloat
    ) -> Bool {
        guard radius > 0 else { return true }
        let inner = frame.insetBy(dx: radius, dy: radius)
        guard inner.width >= 0, inner.height >= 0 else { return true }
        let x = point.x - min(max(point.x, inner.minX), inner.maxX)
        let y = point.y - min(max(point.y, inner.minY), inner.maxY)
        return x * x + y * y <= radius * radius
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
            hierarchyDepth: depth,
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
/// pointer. Buckets are a candidate index, not hit geometry; the canvas applies the mark's own
/// drawn shape before accepting it. Array order is retained so the last painted mark still wins.
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
    /// AppKit's accessibility overrides are imported nonisolated even though it invokes them on
    /// the main thread. The owner is UI state and is only dereferenced inside `assumeIsolated`.
    nonisolated(unsafe) private weak var owner: SemanticSceneView?
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
        let owner = owner
        let index = index
        return MainActor.assumeIsolated {
            owner?.accessibilityFrame(at: index) ?? .zero
        }
    }

    override nonisolated func accessibilityPerformPress() -> Bool {
        let owner = owner
        let index = index
        return MainActor.assumeIsolated {
            owner?.accessibilityActivate(at: index) ?? false
        }
    }
}

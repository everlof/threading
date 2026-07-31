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
        toolTip = [item.label, item.detail].compactMap { $0 }.joined(separator: "\n")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func resetCursorRects() {
        guard item.onActivate != nil, isEnabled else { return }
        addCursorRect(bounds, cursor: .pointingHand)
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

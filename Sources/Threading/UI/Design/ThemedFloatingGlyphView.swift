import AppKit

/// A semantic glyph shared by app-owned floating content.
///
/// Modern themes keep SF Symbols. Period popover materials select the deliberately simpler
/// one-bit marks below, so feature controllers name folder/branch/status instead of branching
/// on a theme or carrying a second set of artwork. Popovers and in-pane floating cards share it.
@MainActor
final class ThemedFloatingGlyphView: NSView, ThemedComponent {

    enum ClassicGlyph {
        case folder
        case branch
        case handoff
        case status
        case changes
        case model
        case plan
        case speed
    }

    private var systemSymbolName: String
    private var classicGlyph: ClassicGlyph
    private var pointSize: CGFloat
    private let appEvents = AppEventObservations()
    var tintColor: NSColor? {
        didSet { needsDisplay = true }
    }
    private(set) var semanticDescription: String?

    init(
        systemSymbolName: String,
        classicGlyph: ClassicGlyph,
        pointSize: CGFloat = Design.Symbol.control,
        accessibilityDescription: String? = nil
    ) {
        self.systemSymbolName = systemSymbolName
        self.classicGlyph = classicGlyph
        self.pointSize = pointSize
        semanticDescription = accessibilityDescription
        super.init(frame: .zero)
        appEvents.observe(AppThemeDidChange.self) { [weak self] _ in
            self?.needsDisplay = true
        }
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        // The host row owns the air around a semantic mark. Inflating the glyph's own box by a
        // token makes it taller than one line of the same point size, so a mark silently changes
        // the card's rhythm merely by being present.
        let side = ceil(pointSize)
        return NSSize(width: side, height: side)
    }

    func setSymbol(
        _ systemSymbolName: String,
        classicGlyph: ClassicGlyph,
        accessibilityDescription: String? = nil
    ) {
        self.systemSymbolName = systemSymbolName
        self.classicGlyph = classicGlyph
        semanticDescription = accessibilityDescription
        needsDisplay = true
    }

    func setPointSize(_ pointSize: CGFloat) {
        guard pointSize != self.pointSize else { return }
        self.pointSize = pointSize
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let style = AppThemePalette.current.material(for: effectiveAppearance).popoverStyle
        if style.glyphStyle == .system {
            drawSystemSymbol()
        } else {
            drawClassicGlyph()
        }
    }

    private func drawSystemSymbol() {
        let slot = min(bounds.width, bounds.height)
        guard let image = Design.Symbol.image(
            systemSymbolName,
            slot: slot,
            pointSize: pointSize
        ) else { return }
        let proposed = NSRect(
            x: bounds.midX - image.size.width / 2,
            y: bounds.midY - image.size.height / 2,
            width: image.size.width,
            height: image.size.height
        )
        let aligned = backingAlignedRect(proposed, options: .alignAllEdgesInward)
        TemplateImageDrawing.draw(image, in: aligned, tint: tintColor ?? Design.Text.secondary)
    }

    private func drawClassicGlyph() {
        guard let graphics = NSGraphicsContext.current else { return }
        let side = min(bounds.width, bounds.height, pointSize + 2)
        let rect = backingAlignedRect(
            NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2,
                   width: side, height: side),
            options: .alignAllEdgesInward
        )
        let context = graphics.cgContext
        context.saveGState()
        defer { context.restoreGState() }
        context.setShouldAntialias(false)
        let tint = tintColor ?? Design.Text.secondary
        context.setStrokeColor(tint.cgColor)
        context.setFillColor(tint.cgColor)
        context.setLineWidth(max(1, 1 / (window?.backingScaleFactor ?? 2)))

        switch classicGlyph {
        case .folder:
            let tabY = rect.maxY - rect.height * 0.30
            context.move(to: CGPoint(x: rect.minX, y: tabY))
            context.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            context.addLine(to: CGPoint(x: rect.midX - 1, y: rect.maxY))
            context.addLine(to: CGPoint(x: rect.midX + 1, y: tabY))
            context.addLine(to: CGPoint(x: rect.maxX, y: tabY))
            context.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            context.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            context.closePath()
            context.strokePath()

        case .branch:
            let node: CGFloat = 3
            context.move(to: CGPoint(x: rect.minX + node / 2, y: rect.maxY - node))
            context.addLine(to: CGPoint(x: rect.minX + node / 2, y: rect.minY + node / 2))
            context.addLine(to: CGPoint(x: rect.maxX - node / 2, y: rect.minY + node / 2))
            context.move(to: CGPoint(x: rect.minX + node / 2, y: rect.midY))
            context.addLine(to: CGPoint(x: rect.maxX - node / 2, y: rect.midY))
            context.strokePath()
            for point in [
                CGPoint(x: rect.minX, y: rect.maxY - node),
                CGPoint(x: rect.maxX - node, y: rect.midY - node / 2),
                CGPoint(x: rect.maxX - node, y: rect.minY)
            ] {
                context.fill(CGRect(origin: point, size: CGSize(width: node, height: node)))
            }

        case .handoff:
            let upper = rect.midY + 2
            let lower = rect.midY - 2
            context.move(to: CGPoint(x: rect.minX, y: upper))
            context.addLine(to: CGPoint(x: rect.maxX, y: upper))
            context.addLine(to: CGPoint(x: rect.maxX - 3, y: upper + 3))
            context.move(to: CGPoint(x: rect.maxX, y: lower))
            context.addLine(to: CGPoint(x: rect.minX, y: lower))
            context.addLine(to: CGPoint(x: rect.minX + 3, y: lower - 3))
            context.strokePath()

        case .status:
            let mark = rect.insetBy(dx: 3, dy: 3)
            context.fill(mark)

        case .changes:
            let leftX = rect.minX + rect.width * 0.28
            let rightX = rect.maxX - rect.width * 0.28
            let middleY = rect.midY
            let arm = max(2, rect.width * 0.18)
            context.move(to: CGPoint(x: leftX - arm, y: middleY))
            context.addLine(to: CGPoint(x: leftX + arm, y: middleY))
            context.move(to: CGPoint(x: leftX, y: middleY - arm))
            context.addLine(to: CGPoint(x: leftX, y: middleY + arm))
            context.move(to: CGPoint(x: rightX - arm, y: middleY))
            context.addLine(to: CGPoint(x: rightX + arm, y: middleY))
            context.strokePath()

        case .model:
            let chip = rect.insetBy(dx: 3, dy: 3)
            context.stroke(chip)
            let pin = max(1, rect.width * 0.12)
            for fraction in [CGFloat(0.32), 0.68] {
                let x = chip.minX + chip.width * fraction
                context.move(to: CGPoint(x: x, y: rect.minY))
                context.addLine(to: CGPoint(x: x, y: chip.minY))
                context.move(to: CGPoint(x: x, y: chip.maxY))
                context.addLine(to: CGPoint(x: x, y: min(rect.maxY, chip.maxY + pin)))
                let y = chip.minY + chip.height * fraction
                context.move(to: CGPoint(x: rect.minX, y: y))
                context.addLine(to: CGPoint(x: chip.minX, y: y))
                context.move(to: CGPoint(x: chip.maxX, y: y))
                context.addLine(to: CGPoint(x: min(rect.maxX, chip.maxX + pin), y: y))
            }
            context.strokePath()

        case .plan:
            let box = max(3, rect.width * 0.25)
            for y in [rect.midY + box * 0.65, rect.midY - box * 0.65] {
                context.stroke(CGRect(x: rect.minX, y: y - box / 2, width: box, height: box))
                context.move(to: CGPoint(x: rect.minX + box + 2, y: y))
                context.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
            context.strokePath()

        case .speed:
            // Filled rather than stroked, alone among the marks here. A bolt is read by its
            // silhouette and nothing else, and its arms are narrower than the box: outlined at
            // one hairline with antialiasing off, the two halves close up into a smudge at the
            // 14-point size the corner card sets. The vertices are fractions of the box so the
            // shape survives the point size moving with the app's text scale.
            let bolt: [(CGFloat, CGFloat)] = [
                (0.60, 1.00), (0.15, 0.42), (0.42, 0.42),
                (0.30, 0.00), (0.85, 0.55), (0.55, 0.55)
            ]
            context.beginPath()
            for (index, point) in bolt.enumerated() {
                let place = CGPoint(
                    x: rect.minX + rect.width * point.0,
                    y: rect.minY + rect.height * point.1
                )
                if index == 0 {
                    context.move(to: place)
                } else {
                    context.addLine(to: place)
                }
            }
            context.closePath()
            context.fillPath()
        }
    }
}

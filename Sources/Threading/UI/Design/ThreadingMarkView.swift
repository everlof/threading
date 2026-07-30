import AppKit

// MARK: - Threading Mark Geometry

/// The Threading mark stated as normalized geometry: the hexagonal shield, six thread strands
/// curving into the middle, and the solid core they meet at.
///
/// The same silhouette `Brand/ThreadingMark.svg` and `GeneratedAppIcon.drawThreadingMark`
/// state — coordinates in 0...1 with y up, so one set of numbers draws any size. Stated here
/// as `CGPath`s because this copy exists to *animate*: the icon draws once into a bitmap,
/// while the sidebar's mark strokes itself in on launch, and a `CAShapeLayer` needs each
/// strand as its own path.
enum ThreadingMarkGeometry {

    /// The display SVG's stroke weights on its 128pt canvas.
    static let outlineStrokeRatio: CGFloat = 7.0 / 128.0
    static let strandStrokeRatio: CGFloat = 7.5 / 128.0

    static let strandCount = 6

    /// The shield: six quadratic edges from the top vertex, stated as (end, control) pairs.
    private static let outlineStart = CGPoint(x: 0.5, y: 0.921875)
    private static let outlineEdges: [(end: CGPoint, control: CGPoint)] = [
        (CGPoint(x: 0.865390625, y: 0.7109375), CGPoint(x: 0.667109375, y: 0.789375)),
        (CGPoint(x: 0.865390625, y: 0.2890625), CGPoint(x: 0.834140625, y: 0.5)),
        (CGPoint(x: 0.5, y: 0.078125), CGPoint(x: 0.667109375, y: 0.210625)),
        (CGPoint(x: 0.134609375, y: 0.2890625), CGPoint(x: 0.332890625, y: 0.210625)),
        (CGPoint(x: 0.134609375, y: 0.7109375), CGPoint(x: 0.165859375, y: 0.5)),
        (CGPoint(x: 0.5, y: 0.921875), CGPoint(x: 0.332890625, y: 0.789375))
    ]

    /// One strand, outer end first — so a stroke-end animation draws it *inward*, which is
    /// the stitch the launch animation wants.
    private static let strandStart = CGPoint(x: 0.5, y: 0.90625)
    private static let strandControl1 = CGPoint(x: 0.515625, y: 0.7734375)
    private static let strandControl2 = CGPoint(x: 0.5234375, y: 0.6640625)
    private static let strandEnd = CGPoint(x: 0.45703125, y: 0.54296875)

    /// Slightly larger than the SVG's junction, for the same reason the app icon's is: it has
    /// to cover the strands' endpoints so the centre reads genuinely solid.
    private static let coreVertices: [CGPoint] = [
        CGPoint(x: 0.5, y: 0.575),
        CGPoint(x: 0.5649519, y: 0.5375),
        CGPoint(x: 0.5649519, y: 0.4625),
        CGPoint(x: 0.5, y: 0.425),
        CGPoint(x: 0.4350481, y: 0.4625),
        CGPoint(x: 0.4350481, y: 0.5375)
    ]

    static func outlinePath(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        path.move(to: point(outlineStart, rect))
        for edge in outlineEdges {
            path.addQuadCurve(to: point(edge.end, rect), control: point(edge.control, rect))
        }
        path.closeSubpath()
        return path
    }

    /// The six strands as separate paths, so each can draw in on its own beat.
    static func strandPaths(in rect: CGRect) -> [CGPath] {
        (0..<strandCount).map { turn in
            let path = CGMutablePath()
            path.move(to: point(rotated(strandStart, turns: turn), rect))
            path.addCurve(
                to: point(rotated(strandEnd, turns: turn), rect),
                control1: point(rotated(strandControl1, turns: turn), rect),
                control2: point(rotated(strandControl2, turns: turn), rect)
            )
            return path
        }
    }

    static func corePath(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        path.move(to: point(coreVertices[0], rect))
        for vertex in coreVertices.dropFirst() {
            path.addLine(to: point(vertex, rect))
        }
        path.closeSubpath()
        return path
    }

    // MARK: - Private Methods

    private static func rotated(_ value: CGPoint, turns: Int) -> CGPoint {
        let angle = -CGFloat(turns) * .pi / 3
        let dx = value.x - 0.5
        let dy = value.y - 0.5
        return CGPoint(
            x: 0.5 + dx * cos(angle) - dy * sin(angle),
            y: 0.5 + dx * sin(angle) + dy * cos(angle)
        )
    }

    private static func point(_ normalized: CGPoint, _ rect: CGRect) -> CGPoint {
        CGPoint(
            x: rect.minX + rect.width * normalized.x,
            y: rect.minY + rect.height * normalized.y
        )
    }
}

// MARK: - Threading Mark View

/// The Threading mark, drawn live — and able to stitch itself in.
///
/// Layers rather than `draw(_:)` because the launch animation strokes each strand in on its
/// own beat, which is what `CAShapeLayer.strokeEnd` exists for; the colours are re-applied on
/// every redraw exactly as `ThemedSpinner`'s are, because a shape layer's `strokeColor` is a
/// frozen `CGColor` — see that view for the rule.
///
/// Ink follows the same split the Dock icon draws: under the identity theme the mark wears the
/// brand's own thread-oranges, because System *is* the brand's home dress; under a style it
/// takes the theme's accent held legible against the sidebar's ground, so Cyberpunk's sidebar
/// is not the one corner of the window still shouting orange. A theme that wants neither ships
/// its own logo asset through `SidebarStyle.Brand`.
///
/// Decorative: the brand row beside it carries the accessible name, so this view deliberately
/// is not an accessibility element.
final class ThreadingMarkView: NSView, ThemedComponent {

    // MARK: - Properties

    private enum Layout {
        /// The sidebar brand slot. A `ThreadingMarkView` is always square; hosts that want
        /// another size constrain it themselves.
        static let defaultSide: CGFloat = 20
    }

    /// The brand's own threads, for the identity theme. sRGB restatements of
    /// `Brand/ThreadingMark.svg` — artwork constants behind this one named boundary, the same
    /// narrow exception the agent brand icons already hold.
    private enum BrandInk {
        static let shield = NSColor(srgbRed: 0.788, green: 0.341, blue: 0.149, alpha: 1)   // #C95726
        static let thread = NSColor(srgbRed: 0.949, green: 0.541, blue: 0.212, alpha: 1)   // #F28A36
        static let core = NSColor(srgbRed: 1.0, green: 0.604, blue: 0.239, alpha: 1)       // #FF9A3D
        /// On a dark ground the deep shield rim loses itself; the mono mark's single orange
        /// is the SVG's own answer for one-colour surfaces.
        static let mono = thread
    }

    private let outline = CAShapeLayer()
    private var strands: [CAShapeLayer] = []
    private let core = CAShapeLayer()
    private var themeRedraw: ThemeRedraw?

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        outline.fillColor = nil
        outline.lineCap = .round
        outline.lineJoin = .round
        layer?.addSublayer(outline)

        strands = (0..<ThreadingMarkGeometry.strandCount).map { _ in
            let strand = CAShapeLayer()
            strand.fillColor = nil
            strand.lineCap = .round
            strand.lineJoin = .round
            layer?.addSublayer(strand)
            return strand
        }

        layer?.addSublayer(core)

        themeRedraw = ThemeRedraw(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Layout.defaultSide, height: Layout.defaultSide)
    }

    override func isAccessibilityElement() -> Bool { false }

    // MARK: - Layout & Drawing

    override func layout() {
        super.layout()

        // The mark is square whatever the view is: fit the largest centred square, inset by
        // half the heaviest stroke so round caps are not clipped at the vertices.
        let side = min(bounds.width, bounds.height)
        let strandWidth = side * ThreadingMarkGeometry.strandStrokeRatio
        let box = CGRect(
            x: bounds.midX - side / 2,
            y: bounds.midY - side / 2,
            width: side,
            height: side
        ).insetBy(dx: strandWidth / 2, dy: strandWidth / 2)

        outline.frame = bounds
        outline.path = ThreadingMarkGeometry.outlinePath(in: box)
        outline.lineWidth = side * ThreadingMarkGeometry.outlineStrokeRatio

        for (strand, path) in zip(strands, ThreadingMarkGeometry.strandPaths(in: box)) {
            strand.frame = bounds
            strand.path = path
            strand.lineWidth = strandWidth
        }

        core.frame = bounds
        core.path = ThreadingMarkGeometry.corePath(in: box)
    }

    /// Colours re-applied per redraw, never trusted to survive a theme switch on the layer.
    override func draw(_ dirtyRect: NSRect) {
        let ink = resolvedInk()
        outline.strokeColor = ink.shield.cgColor
        for strand in strands {
            strand.strokeColor = ink.thread.cgColor
        }
        core.fillColor = ink.core.cgColor
    }

    // MARK: - Launch Animation

    /// Stitches the mark in: shield first, the six strands on staggered beats, the core
    /// landing last. One-shot. Under Reduce Motion every duration is zero and this does
    /// nothing — the mark is simply there, which is the honest reduced form of "it arrived".
    func playDrawIn() {
        guard !Design.Motion.reducesMotion else { return }
        layoutSubtreeIfNeeded()

        let now = CACurrentMediaTime()
        let outlineDuration = Design.Motion.brandOutlineDraw
        let strandDuration = Design.Motion.brandStrandDraw
        let stagger = Design.Motion.brandStrandStagger
        // The strands begin while the shield is still closing — a stitch through a hoop that
        // is not finished being a hoop reads as one gesture rather than two steps.
        let strandsBegin = now + outlineDuration * 0.4
        let coreBegins = strandsBegin
            + stagger * Double(strands.count - 1)
            + strandDuration * 0.8

        addStrokeIn(to: outline, beginTime: now, duration: outlineDuration)
        for (index, strand) in strands.enumerated() {
            addStrokeIn(
                to: strand,
                beginTime: strandsBegin + stagger * Double(index),
                duration: strandDuration
            )
        }

        let pop = CAAnimationGroup()
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.4
        scale.toValue = 1
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        pop.animations = [scale, fade]
        pop.beginTime = coreBegins
        pop.duration = Design.Motion.brandCorePop
        pop.timingFunction = CAMediaTimingFunction(name: .easeOut)
        pop.fillMode = .backwards
        // Scale about the core's own centre, not the layer frame's corner.
        if let box = core.path?.boundingBox {
            core.anchorPoint = CGPoint(
                x: box.midX / core.bounds.width,
                y: box.midY / core.bounds.height
            )
            core.position = CGPoint(x: box.midX, y: box.midY)
            core.bounds = core.bounds
        }
        core.add(pop, forKey: "drawIn")
    }

    private func addStrokeIn(to shape: CAShapeLayer, beginTime: CFTimeInterval, duration: TimeInterval) {
        let stroke = CABasicAnimation(keyPath: "strokeEnd")
        stroke.fromValue = 0
        stroke.toValue = 1
        stroke.beginTime = beginTime
        stroke.duration = duration
        stroke.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        // Backwards fill holds the stroke at zero until its beat arrives; the model value
        // stays 1 throughout, so a skipped or finished animation both land on the whole mark.
        stroke.fillMode = .backwards
        shape.add(stroke, forKey: "drawIn")
    }

    // MARK: - Private Methods

    private func resolvedInk() -> (shield: NSColor, thread: NSColor, core: NSColor) {
        if AppThemePalette.current.isSystem {
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return dark
                ? (BrandInk.mono, BrandInk.mono, BrandInk.mono)
                : (BrandInk.shield, BrandInk.thread, BrandInk.core)
        }
        // The Dock icon's rule, at sidebar scale: the theme's accent, floored legible against
        // the ground it actually sits on.
        let ink = Design.Surface.accent.legible(on: Design.Surface.background)
        return (ink, ink, ink)
    }
}

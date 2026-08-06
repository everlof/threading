import AppKit

/// The three ways the Threading mark can become a particle field. They share one geometry and
/// differ only in how its points travel, so a host can choose a cadence without acquiring a
/// second drawing of the logo.
enum ThreadingMarkParticleMotion: String, CaseIterable {
    /// Dots run around the shield and from each strand's outer end into the knot.
    case weave
    /// The whole field draws inward and returns, with neighbouring dots answering in sequence.
    case breathe
    /// The field turns continuously by one of the mark's six indistinguishable strand steps.
    case orbit
}

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

    enum ParticleRole: Equatable {
        case outline
        case strand(Int)
        case core
    }

    struct ParticleSeed: Equatable {
        let point: CGPoint
        let role: ParticleRole
        /// Position on the path, from its outer/start point to its inner/end point. It is also
        /// the phase offset that keeps a run of dots evenly distributed while it travels.
        let progress: CGFloat
    }

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

    /// An adaptive dotted statement of the canonical mark. The counts are chosen by the view:
    /// the sidebar needs fewer, larger points than the gallery's inspection size, but neither
    /// invents geometry here. Core returns its six vertices plus the knot at their centre.
    static func particleSeeds(outlineCount: Int, strandCount: Int) -> [ParticleSeed] {
        let safeOutlineCount = max(outlineEdges.count, outlineCount)
        let safeStrandCount = max(2, strandCount)

        let outline = (0..<safeOutlineCount).map { index in
            let progress = CGFloat(index) / CGFloat(safeOutlineCount)
            return ParticleSeed(
                point: outlinePoint(at: progress),
                role: .outline,
                progress: progress
            )
        }

        let strands = (0..<self.strandCount).flatMap { turn in
            (0..<safeStrandCount).map { index in
                // The moving field is periodic: including both 0 and 1 would place two dots
                // on the same outer endpoint as soon as the animation wraps. The core's own
                // seven points close the tiny gap at the inner end.
                let progress = CGFloat(index) / CGFloat(safeStrandCount)
                return ParticleSeed(
                    point: strandPoint(turn: turn, at: progress),
                    role: .strand(turn),
                    progress: progress
                )
            }
        }

        let core = coreVertices.enumerated().map { index, vertex in
            ParticleSeed(
                point: vertex,
                role: .core,
                progress: CGFloat(index) / CGFloat(coreVertices.count)
            )
        } + [ParticleSeed(point: CGPoint(x: 0.5, y: 0.5), role: .core, progress: 1)]

        return outline + strands + core
    }

    static func particlePoint(for seed: ParticleSeed, progress: CGFloat, in rect: CGRect) -> CGPoint {
        let wrapped = progress - floor(progress)
        let normalized: CGPoint
        switch seed.role {
        case .outline:
            normalized = outlinePoint(at: wrapped)
        case .strand(let turn):
            normalized = strandPoint(turn: turn, at: min(max(progress, 0), 1))
        case .core:
            normalized = seed.point
        }
        return point(normalized, rect)
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

    private static func outlinePoint(at progress: CGFloat) -> CGPoint {
        let wrapped = progress - floor(progress)
        let scaled = wrapped * CGFloat(outlineEdges.count)
        let index = min(outlineEdges.count - 1, Int(scaled))
        let local = scaled - CGFloat(index)
        let start = index == 0 ? outlineStart : outlineEdges[index - 1].end
        let edge = outlineEdges[index]
        return quadratic(from: start, control: edge.control, to: edge.end, at: local)
    }

    private static func strandPoint(turn: Int, at progress: CGFloat) -> CGPoint {
        rotated(
            cubic(
                from: strandStart,
                control1: strandControl1,
                control2: strandControl2,
                to: strandEnd,
                at: min(max(progress, 0), 1)
            ),
            turns: turn
        )
    }

    private static func quadratic(
        from start: CGPoint,
        control: CGPoint,
        to end: CGPoint,
        at progress: CGFloat
    ) -> CGPoint {
        let remaining = 1 - progress
        return CGPoint(
            x: remaining * remaining * start.x
                + 2 * remaining * progress * control.x
                + progress * progress * end.x,
            y: remaining * remaining * start.y
                + 2 * remaining * progress * control.y
                + progress * progress * end.y
        )
    }

    private static func cubic(
        from start: CGPoint,
        control1: CGPoint,
        control2: CGPoint,
        to end: CGPoint,
        at progress: CGFloat
    ) -> CGPoint {
        let remaining = 1 - progress
        return CGPoint(
            x: remaining * remaining * remaining * start.x
                + 3 * remaining * remaining * progress * control1.x
                + 3 * remaining * progress * progress * control2.x
                + progress * progress * progress * end.x,
            y: remaining * remaining * remaining * start.y
                + 3 * remaining * remaining * progress * control1.y
                + 3 * remaining * progress * progress * control2.y
                + progress * progress * progress * end.y
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
/// Three gestures, one geometry: it stitches itself in once at launch, lifts under the pointer,
/// and turns a sixth of a circle when pressed. The host says when — `SidebarBrandView` tracks
/// the whole brand row, because a 24pt logo is too small a thing to ask a pointer to find.
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

        /// Used only before the view has a window or a screen to ask. Retina rather than 1x
        /// because guessing low is the case that ships blurry.
        static let assumedBackingScale: CGFloat = 2

        /// How far the mark lifts under the pointer.
        static let hoverScale: CGFloat = 1.08
        /// How far the core swells inside that lift, so the knot reads as catching the light
        /// rather than the whole logo simply being bigger.
        static let hoverCoreScale: CGFloat = 1.3
        /// The dip a press takes before the turn — the tug before the thread moves.
        static let pressScale: CGFloat = 0.9
        /// One strand-step. The mark has six-fold symmetry, so a turn of exactly this lands
        /// the shield, all six strands and the core back on themselves: the eye reads a notch
        /// turning, and nothing is left rotated when the animation is removed.
        static let pressTurn: CGFloat = .pi / 3

        /// At sidebar size, points must stay large enough to survive one display pixel. Larger
        /// inspection marks add density rather than scaling the same sparse constellation up.
        static let minimumOutlineParticles = 18
        static let minimumStrandParticles = 4
        static let outlineParticlesPerPoint: CGFloat = 0.44
        static let strandParticlesPerPoint: CGFloat = 0.105
        static let vectorOpacityWhileParticle: Float = 0.14
        static let particleBreathInset: CGFloat = 0.1
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
    private var particleContainer: CALayer?
    private var particles: [(layer: CAShapeLayer, seed: ThreadingMarkGeometry.ParticleSeed)] = []
    private var particleBox = CGRect.zero
    private var particleDensity: (outline: Int, strand: Int)?
    private var particlePresentationPhase: CGFloat?
    private var themeRedraw: ThemeRedraw?
    /// Whether the mark is currently held lifted, so a press knows what it is scaling from and
    /// a repeated enter does not re-trigger the core's one beat.
    private var isHovered = false
    /// `nil` keeps the plain vector mark. This is the default for passive appearances such as
    /// the composer hero; the sidebar opts into `.weave` because its host owns pointer state.
    var particleMotion: ThreadingMarkParticleMotion? {
        didSet {
            guard oldValue != particleMotion else { return }
            configureParticles()
        }
    }

    /// Every layer the mark is made of, in draw order. The animations move all of them
    /// together, so the one list is what stops a new part being left behind by a turn.
    private var shapes: [CAShapeLayer] { [outline] + strands + [core] }

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
        applyContentsScale()

        themeRedraw = ThemeRedraw(self)
    }

    convenience init(particleMotion: ThreadingMarkParticleMotion) {
        self.init(frame: .zero)
        // Property observers do not run while a convenience initializer is still completing.
        // Build explicitly here; later assignments continue to flow through `didSet`.
        self.particleMotion = particleMotion
        configureParticles()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Layout.defaultSide, height: Layout.defaultSide)
    }

    override func isAccessibilityElement() -> Bool { false }

    // MARK: - Backing Store

    /// A shape layer added by hand does not inherit its host view's `contentsScale` — only the
    /// backing layer AppKit makes for the view is given one. So every one of these rasterised
    /// its path at 1x and had the compositor scale it up, which on a Retina display is exactly
    /// the soft, half-a-point-of-fuzz mark this was reported as: a 1.1pt stroke drawn at 1x
    /// and enlarged is a two-pixel grey smear rather than a line.
    ///
    /// Re-asked rather than set once, because the answer changes when the window moves between
    /// displays of different scales — the same rule `ThemeRedraw` follows for ink.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyContentsScale()
        // The stroke widths are snapped to this display's pixel grid (see `layout()`), so a
        // move between displays is a remeasure, not only a re-rasterise.
        needsLayout = true
    }

    private var backingScale: CGFloat {
        window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? Layout.assumedBackingScale
    }

    private func applyContentsScale() {
        // The hover lift scales the *raster*: Core Animation rasterises a shape layer's path
        // at `contentsScale` and the compositor transforms that bitmap, so a lifted mark is a
        // bitmap enlarged 8% — visibly soft on 1×. While lifted, the raster is held at the
        // lifted density instead, so full lift is pixel-exact; at rest the plain scale keeps
        // the resting mark crisp, which is where it spends nearly all of its time.
        let scale = backingScale * (isHovered ? Layout.hoverScale : 1)
        layer?.contentsScale = scale
        for shape in shapes {
            shape.contentsScale = scale
        }
        particleContainer?.contentsScale = scale
        for particle in particles {
            particle.layer.contentsScale = scale
        }
    }

    // MARK: - Layout & Drawing

    override func layout() {
        super.layout()

        // The mark is square whatever the view is: fit the largest centred square, inset by
        // half the heaviest stroke so round caps are not clipped at the vertices.
        //
        // Strokes are snapped to the display's pixel grid. The ratios come from a 128pt SVG
        // canvas, and in the sidebar's 20pt slot they land at 1.09 and 1.17 — which on a 1×
        // display is one antialiased pixel straddling two rows. A whole-pixel stroke is the
        // same drawing with its edges on the grid; at 2× the rounding is a sixteenth of a
        // point and invisible. The box is aligned for the same reason: curves antialias
        // regardless, but the shield's extremes land on pixel columns instead of between two.
        let scale = backingScale
        let side = min(bounds.width, bounds.height)
        let strandWidth = snapped(side * ThreadingMarkGeometry.strandStrokeRatio, to: scale)
        let box = backingAlignedRect(
            CGRect(
                x: bounds.midX - side / 2,
                y: bounds.midY - side / 2,
                width: side,
                height: side
            ).insetBy(dx: strandWidth / 2, dy: strandWidth / 2),
            options: .alignAllEdgesInward
        )

        // A view with no area yet — a gallery story laid out once before its constraints give it
        // a size — asks `backingAlignedRect` to align a zero-sized rect inward, and gets
        // `CGRect.null` back. Its origin is infinite, so every particle position computed from it
        // is infinite, and AppKit *raises* on a NaN `CALayer.position` rather than ignoring it:
        // seven component-gallery tests died taking the whole test host with them, with no failed
        // assertion to say why. Nothing can be drawn in zero area, so there is nothing to skip.
        guard side > 0,
              box.width > 0, box.height > 0,
              box.origin.x.isFinite, box.origin.y.isFinite else { return }

        outline.frame = bounds
        outline.path = ThreadingMarkGeometry.outlinePath(in: box)
        outline.lineWidth = snapped(side * ThreadingMarkGeometry.outlineStrokeRatio, to: scale)

        for (strand, path) in zip(strands, ThreadingMarkGeometry.strandPaths(in: box)) {
            strand.frame = bounds
            strand.path = path
            strand.lineWidth = strandWidth
        }

        core.frame = bounds
        core.path = ThreadingMarkGeometry.corePath(in: box)

        layoutParticles(in: box, side: side)
    }

    /// The nearest whole number of device pixels, and never fewer than one.
    private func snapped(_ width: CGFloat, to scale: CGFloat) -> CGFloat {
        max(1 / scale, (width * scale).rounded() / scale)
    }

    /// Colours re-applied per redraw, never trusted to survive a theme switch on the layer.
    override func draw(_ dirtyRect: NSRect) {
        let ink = resolvedInk()
        outline.strokeColor = ink.shield.cgColor
        for strand in strands {
            strand.strokeColor = ink.thread.cgColor
        }
        core.fillColor = ink.core.cgColor
        applyParticleInk(ink)
    }

    // MARK: - Particle Geometry

    private func configureParticles() {
        stopParticleMotion()
        particles.removeAll()
        particleContainer?.removeFromSuperlayer()
        particleContainer = nil
        particleDensity = nil
        particlePresentationPhase = nil

        guard particleMotion != nil else { return }
        let container = CALayer()
        container.name = "ThreadingMarkParticles"
        container.opacity = 0
        layer?.addSublayer(container)
        particleContainer = container
        applyContentsScale()
        needsLayout = true
        needsDisplay = true
    }

    private func layoutParticles(in box: CGRect, side: CGFloat) {
        guard let container = particleContainer else { return }
        container.frame = bounds
        particleBox = box

        let density = (
            outline: max(
                Layout.minimumOutlineParticles,
                Int((side * Layout.outlineParticlesPerPoint).rounded())
            ),
            strand: max(
                Layout.minimumStrandParticles,
                Int((side * Layout.strandParticlesPerPoint).rounded())
            )
        )
        if particleDensity?.outline != density.outline
            || particleDensity?.strand != density.strand {
            rebuildParticles(outlineCount: density.outline, strandCount: density.strand)
            particleDensity = density
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for particle in particles {
            let diameter = particleDiameter(for: particle.seed, side: side)
            particle.layer.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
            particle.layer.path = CGPath(ellipseIn: particle.layer.bounds, transform: nil)
            particle.layer.position = ThreadingMarkGeometry.particlePoint(
                for: particle.seed,
                progress: particle.seed.progress,
                in: box
            )
        }
        CATransaction.commit()

        if let particlePresentationPhase {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            applyParticleFrame(at: particlePresentationPhase)
            CATransaction.commit()
        } else if isHovered, Design.Motion.reducesMotion == false {
            startParticleMotion()
        }
    }

    private func rebuildParticles(outlineCount: Int, strandCount: Int) {
        guard let container = particleContainer else { return }
        container.sublayers?.forEach { $0.removeFromSuperlayer() }
        particles = ThreadingMarkGeometry.particleSeeds(
            outlineCount: outlineCount,
            strandCount: strandCount
        ).map { seed in
            let dot = CAShapeLayer()
            dot.name = particleName(for: seed)
            dot.contentsScale = backingScale * (isHovered ? Layout.hoverScale : 1)
            container.addSublayer(dot)
            return (dot, seed)
        }
        applyParticleInk(resolvedInk())
    }

    private func particleDiameter(
        for seed: ThreadingMarkGeometry.ParticleSeed,
        side: CGFloat
    ) -> CGFloat {
        let ratio: CGFloat
        switch seed.role {
        case .outline:
            ratio = 0.042
        case .strand:
            ratio = 0.048
        case .core:
            ratio = seed.progress == 1 ? 0.082 : 0.058
        }
        return max(1 / backingScale, snapped(side * ratio, to: backingScale))
    }

    private func particleName(for seed: ThreadingMarkGeometry.ParticleSeed) -> String {
        switch seed.role {
        case .outline:
            return "ThreadingMarkParticle.outline"
        case .strand(let index):
            return "ThreadingMarkParticle.strand.\(index)"
        case .core:
            return "ThreadingMarkParticle.core"
        }
    }

    private func applyParticleInk(
        _ ink: (shield: NSColor, thread: NSColor, core: NSColor)
    ) {
        guard !particles.isEmpty else { return }
        for particle in particles {
            let seed = particle.seed
            let base: NSColor
            switch seed.role {
            case .outline:
                base = blended(ink.shield, toward: ink.thread, amount: seed.progress * 0.28)
            case .strand(let index):
                // Each of the six threads owns a slightly different point on the same ramp;
                // progress then warms it as it approaches the core. Every dot therefore keeps
                // an addressable colour without turning the logo into six unrelated hues.
                let strandBeat = CGFloat(index) / CGFloat(ThreadingMarkGeometry.strandCount - 1)
                base = blended(
                    ink.thread,
                    toward: ink.core,
                    amount: min(0.72, seed.progress * 0.52 + strandBeat * 0.2)
                )
            case .core:
                base = ink.core
            }
            let shimmer = 0.82 + 0.18 * (0.5 + 0.5 * cos(seed.progress * .pi * 2))
            particle.layer.fillColor = base.withAlphaComponent(shimmer).cgColor
        }
    }

    private func blended(_ color: NSColor, toward other: NSColor, amount: CGFloat) -> NSColor {
        color.blended(withFraction: min(max(amount, 0), 1), of: other) ?? color
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

    // MARK: - Pointer Animation

    /// The pointer arriving: the mark lifts a little, and the core swells once inside the lift.
    ///
    /// The lift is a *model* change, so it holds for as long as the pointer is over the row and
    /// settles back on its own; only the core's swell is a beat. That split is what keeps a slow
    /// pass across the sidebar from reading as the logo inflating — the thing that moves twice
    /// is the knot, and it does it once.
    func setHovered(_ hovered: Bool) {
        guard !Design.Motion.reducesMotion, hovered != isHovered else { return }
        isHovered = hovered
        // The raster follows the lift — see `applyContentsScale`.
        applyContentsScale()
        layoutSubtreeIfNeeded()

        let scale = hovered ? Layout.hoverScale : 1
        CATransaction.begin()
        CATransaction.setAnimationDuration(Design.Motion.quick)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        for shape in shapes {
            shape.transform = CATransform3DMakeScale(scale, scale, 1)
            shape.opacity = hovered && particleContainer != nil
                ? Layout.vectorOpacityWhileParticle
                : 1
        }
        if let particleContainer {
            particleContainer.transform = CATransform3DMakeScale(scale, scale, 1)
            particleContainer.opacity = hovered ? 1 : 0
        }
        CATransaction.commit()

        guard hovered else {
            // The pointer has left; a swell still in flight would go on pulsing a mark that has
            // already settled, and land on the lifted scale it was written against.
            core.removeAnimation(forKey: "hover")
            stopParticleMotion()
            return
        }

        startParticleMotion()
        guard particleContainer == nil else { return }
        core.add(
            keyframe(
                [pose(scale), pose(scale * Layout.hoverCoreScale), pose(scale)],
                at: [0, 0.45, 1],
                over: Design.Motion.standard
            ),
            forKey: "hover"
        )
    }

    /// The press: one strand-step of turn, with a tug at the start.
    ///
    /// A sixth of a turn is the only rotation this mark can make and still be itself — see
    /// `Layout.pressTurn` — so the gesture reads as a notch snapping over rather than a logo
    /// spinning, and the model value never has to move: when the animation is removed the mark
    /// is already exactly where the turn left it.
    func playPress() {
        guard !Design.Motion.reducesMotion else { return }
        layoutSubtreeIfNeeded()

        let scale = isHovered ? Layout.hoverScale : 1
        // Stated as whole transforms rather than as two animations on `transform.rotation.z`
        // and `transform.scale`: those are sub-properties of one property, and two animations
        // arguing over it is how a turn comes out either flat or unscaled.
        let press = keyframe(
            [
                pose(scale),
                pose(scale * Layout.pressScale, turn: -Layout.pressTurn * 0.2),
                pose(scale, turn: -Layout.pressTurn)
            ],
            at: [0, 0.3, 1],
            over: Design.Motion.brandStrandDraw
        )

        var turningLayers: [CALayer] = shapes
        if let particleContainer, particleContainer.opacity > 0 {
            turningLayers.append(particleContainer)
            playParticlePressPulse()
        }
        for turningLayer in turningLayers {
            turningLayer.add(press, forKey: "press")
        }
    }

    /// A deterministic frame of the particle treatment for the component gallery and render
    /// tests. Production pointer interaction uses `setHovered`; this seam lets visual review
    /// compare all three motions without racing Core Animation's wall clock.
    func setParticlePresentation(phase: CGFloat?) {
        guard let particleContainer, particleMotion != nil else { return }
        particlePresentationPhase = phase.map { $0 - floor($0) }
        layoutSubtreeIfNeeded()
        stopParticleMotion()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let phase = particlePresentationPhase {
            for shape in shapes {
                shape.opacity = Layout.vectorOpacityWhileParticle
                shape.transform = CATransform3DIdentity
            }
            particleContainer.opacity = 1
            particleContainer.transform = CATransform3DIdentity
            applyParticleFrame(at: phase)
        } else {
            for shape in shapes {
                shape.opacity = 1
                shape.transform = CATransform3DIdentity
            }
            particleContainer.opacity = 0
            particleContainer.transform = CATransform3DIdentity
            for particle in particles {
                particle.layer.position = ThreadingMarkGeometry.particlePoint(
                    for: particle.seed,
                    progress: particle.seed.progress,
                    in: particleBox
                )
                particle.layer.transform = CATransform3DIdentity
            }
        }
        CATransaction.commit()
    }

    private func applyParticleFrame(at phase: CGFloat) {
        guard let particleMotion, let particleContainer else { return }
        let centre = CGPoint(x: particleBox.midX, y: particleBox.midY)

        switch particleMotion {
        case .weave:
            for particle in particles {
                var progress: CGFloat
                switch particle.seed.role {
                case .outline:
                    progress = particle.seed.progress + phase * 0.28
                case .strand:
                    progress = particle.seed.progress + phase
                    progress -= floor(progress)
                case .core:
                    progress = particle.seed.progress
                }
                particle.layer.position = ThreadingMarkGeometry.particlePoint(
                    for: particle.seed,
                    progress: progress,
                    in: particleBox
                )
                let coreBeat = particle.seed.role == .core
                    ? 1 + 0.22 * sin((phase + particle.seed.progress) * .pi * 2)
                    : 1
                particle.layer.transform = CATransform3DMakeScale(coreBeat, coreBeat, 1)
            }
        case .breathe:
            for particle in particles {
                let resting = ThreadingMarkGeometry.particlePoint(
                    for: particle.seed,
                    progress: particle.seed.progress,
                    in: particleBox
                )
                let wave = 0.5 - 0.5 * cos(
                    (phase + particle.seed.progress * 0.16) * .pi * 2
                )
                let radialScale = 1 - Layout.particleBreathInset * wave
                particle.layer.position = CGPoint(
                    x: centre.x + (resting.x - centre.x) * radialScale,
                    y: centre.y + (resting.y - centre.y) * radialScale
                )
                let dotScale = 0.82 + 0.28 * wave
                particle.layer.transform = CATransform3DMakeScale(dotScale, dotScale, 1)
            }
        case .orbit:
            for particle in particles {
                particle.layer.position = ThreadingMarkGeometry.particlePoint(
                    for: particle.seed,
                    progress: particle.seed.progress,
                    in: particleBox
                )
                let dotBeat = 0.86 + 0.2 * (
                    0.5 + 0.5 * sin((phase + particle.seed.progress) * .pi * 2)
                )
                particle.layer.transform = CATransform3DMakeScale(dotBeat, dotBeat, 1)
            }
            particleContainer.transform = CATransform3DMakeRotation(
                -Layout.pressTurn * phase,
                0, 0, 1
            )
        }
    }

    private func startParticleMotion() {
        guard let particleMotion,
              let particleContainer,
              !Design.Motion.reducesMotion,
              !particleBox.isEmpty,
              !particles.isEmpty else { return }
        stopParticleMotion()

        switch particleMotion {
        case .weave:
            startWeaveMotion()
        case .breathe:
            startBreathMotion()
        case .orbit:
            startOrbitMotion(on: particleContainer)
        }
    }

    private func startWeaveMotion() {
        let cycle = Design.Motion.brandParticleWeaveCycle
        let now = CACurrentMediaTime()
        let strandPaths = ThreadingMarkGeometry.strandPaths(in: particleBox)

        for particle in particles {
            switch particle.seed.role {
            case .outline:
                addTravel(
                    along: ThreadingMarkGeometry.outlinePath(in: particleBox),
                    to: particle.layer,
                    cycle: cycle * 2.15,
                    phase: particle.seed.progress,
                    now: now
                )
            case .strand(let index):
                addTravel(
                    along: strandPaths[index],
                    to: particle.layer,
                    cycle: cycle,
                    phase: particle.seed.progress,
                    now: now
                )
            case .core:
                addParticlePulse(
                    to: particle.layer,
                    cycle: cycle * 0.86,
                    phase: particle.seed.progress,
                    now: now
                )
            }
        }
    }

    private func startBreathMotion() {
        let cycle = Design.Motion.brandParticleBreathCycle
        let now = CACurrentMediaTime()
        let centre = CGPoint(x: particleBox.midX, y: particleBox.midY)

        for particle in particles {
            let resting = particle.layer.position
            let inward = CGPoint(
                x: centre.x + (resting.x - centre.x) * (1 - Layout.particleBreathInset),
                y: centre.y + (resting.y - centre.y) * (1 - Layout.particleBreathInset)
            )
            let breath = CAKeyframeAnimation(keyPath: "position")
            breath.values = [NSValue(point: resting), NSValue(point: inward), NSValue(point: resting)]
            breath.keyTimes = [0, 0.5, 1]
            breath.duration = cycle
            breath.repeatCount = .infinity
            breath.beginTime = now
            breath.timeOffset = cycle * Double(particle.seed.progress) * 0.16
            breath.timingFunctions = [
                CAMediaTimingFunction(name: .easeInEaseOut),
                CAMediaTimingFunction(name: .easeInEaseOut)
            ]
            particle.layer.add(breath, forKey: "particle.position")
            addParticlePulse(
                to: particle.layer,
                cycle: cycle,
                phase: particle.seed.progress * 0.16,
                now: now
            )
        }
    }

    private func startOrbitMotion(on container: CALayer) {
        let cycle = Design.Motion.brandParticleOrbitCycle
        let now = CACurrentMediaTime()
        let orbit = CABasicAnimation(keyPath: "transform.rotation.z")
        orbit.fromValue = 0
        orbit.toValue = -Layout.pressTurn
        orbit.duration = cycle
        orbit.repeatCount = .infinity
        orbit.timingFunction = CAMediaTimingFunction(name: .linear)
        container.add(orbit, forKey: "particle.orbit")

        for particle in particles {
            addParticlePulse(
                to: particle.layer,
                cycle: cycle * 0.72,
                phase: particle.seed.progress,
                now: now
            )
        }
    }

    private func addTravel(
        along path: CGPath,
        to particle: CAShapeLayer,
        cycle: TimeInterval,
        phase: CGFloat,
        now: CFTimeInterval
    ) {
        let travel = CAKeyframeAnimation(keyPath: "position")
        travel.path = path
        travel.calculationMode = .paced
        travel.duration = cycle
        travel.repeatCount = .infinity
        travel.beginTime = now
        travel.timeOffset = cycle * Double(phase)
        travel.timingFunction = CAMediaTimingFunction(name: .linear)
        particle.add(travel, forKey: "particle.position")
    }

    private func addParticlePulse(
        to particle: CAShapeLayer,
        cycle: TimeInterval,
        phase: CGFloat,
        now: CFTimeInterval
    ) {
        let pulse = CAKeyframeAnimation(keyPath: "transform.scale")
        pulse.values = [0.86, 1.12, 0.86]
        pulse.keyTimes = [0, 0.5, 1]
        pulse.duration = cycle
        pulse.repeatCount = .infinity
        pulse.beginTime = now
        pulse.timeOffset = cycle * Double(phase)
        pulse.timingFunctions = [
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .easeInEaseOut)
        ]
        particle.add(pulse, forKey: "particle.scale")
    }

    private func playParticlePressPulse() {
        guard !particleBox.isEmpty else { return }
        let now = CACurrentMediaTime()
        let centre = CGPoint(x: particleBox.midX, y: particleBox.midY)
        let maximumRadius = max(particleBox.width, particleBox.height) * 0.5

        for particle in particles {
            let dx = particle.layer.position.x - centre.x
            let dy = particle.layer.position.y - centre.y
            let radius = min(1, hypot(dx, dy) / maximumRadius)
            let pulse = CAKeyframeAnimation(keyPath: "transform.scale")
            pulse.values = [1, 1.65, 0.78, 1]
            pulse.keyTimes = [0, 0.28, 0.62, 1]
            pulse.duration = Design.Motion.brandCorePop
            pulse.beginTime = now
                + Design.Motion.brandParticlePressCascade * Double(1 - radius)
            pulse.timingFunctions = Array(
                repeating: CAMediaTimingFunction(name: .easeInEaseOut),
                count: 3
            )
            particle.layer.add(pulse, forKey: "pressPulse")
        }
    }

    private func stopParticleMotion() {
        particleContainer?.removeAnimation(forKey: "particle.orbit")
        for particle in particles {
            particle.layer.removeAnimation(forKey: "particle.position")
            particle.layer.removeAnimation(forKey: "particle.scale")
            particle.layer.removeAnimation(forKey: "pressPulse")
        }
    }

    /// One frame of a pointer animation: a scale about the mark's centre, then a turn about it.
    private func pose(_ scale: CGFloat, turn: CGFloat = 0) -> NSValue {
        NSValue(caTransform3D: CATransform3DRotate(
            CATransform3DMakeScale(scale, scale, 1),
            turn,
            0, 0, 1
        ))
    }

    private func keyframe(
        _ poses: [NSValue],
        at times: [NSNumber],
        over duration: TimeInterval
    ) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: "transform")
        animation.values = poses
        animation.keyTimes = times
        animation.duration = duration
        animation.timingFunctions = Array(
            repeating: CAMediaTimingFunction(name: .easeInEaseOut),
            count: max(0, poses.count - 1)
        )
        return animation
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

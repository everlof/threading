import AppKit
import QuartzCore

/// A decoded theme sprite, as every particle renderer receives it.
typealias ThemeParticleSprite = SidebarAppearance.Background.Particles.Sprite

// MARK: - Placement

/// Where a theme's particles are being drawn, which decides where they are born, how far they
/// travel, and how many may be alive at once. The theme states *what* (`ThemeParticles`); the
/// placement is the host's.
enum ThemeParticlePlacement: Equatable {
    /// Moving under a ground for as long as it is on screen — the sidebar's column, a pane.
    case ambient
    /// Given off from one point — a logo's neck — as a stream or a burst.
    case point(CGPoint)
    /// Crossing a whole window once, during a switch into the theme.
    case transition(duration: TimeInterval)
}

// MARK: - Budgets

/// How many particles each placement may keep alive, and how fast a point may give them off.
///
/// These are the bounds that make a theme-authored field a fixed cost rather than a
/// data-dependent one: every rate is derived from the region and the density and then
/// clamped so `rate × lifetime` stays under the ceiling, whatever the document says.
/// Core Animation simulates and draws the particles in the render server, so what these bound
/// is GPU fill and the number of sprites composited per frame — the main thread only
/// configures the emitter, which is O(inks).
enum ThemeParticleBudget {
    /// A column or a pane: enough for a glass of bubbles, not a snowstorm under the text.
    static let ambientMaximumAlive = 120
    /// A logo's stream at full density while hovered or while every agent works.
    static let pointMaximumRate = 40.0
    /// One burst from a logo.
    static let burstMaximumCount = 48
    /// A whole window for a second or two — the one placement meant to cover what is beneath.
    static let transitionMaximumAlive = 700
    /// A moment's shower crosses the same window but must not cover it.
    static let momentMaximumAlive = ThemeMomentLimits.maximumAlive
    /// Ambient fields cross their region in at most this long, so a tall pane never keeps a
    /// particle alive for a minute.
    static let maximumAmbientLifetime: Float = 24
}

// MARK: - Emitter

/// Configures a `CAEmitterLayer` from a theme's particles at a placement.
///
/// Stateless: every call states the whole emitter — cells, source, rate — so a theme switch,
/// an appearance flip or a resize is the same one call, and nothing a previous theme set can
/// survive on the layer. The sprites come from `ThemeParticleArtwork` and are drawn in white;
/// each ink is a cell of its own whose `color` tints them, so an adaptive theme's second
/// variant is a new set of cells rather than new artwork.
///
/// Measured shape of the source: a `.line` emitter in `.outline` mode left its particles
/// piled at the edge they were born on, while a one-point-tall `.rectangle` in `.volume` mode
/// sends them across the region as authored — so every "from below" or "from above" source is
/// the latter.
enum ThemeParticleEmitter {

    /// States the whole emitter. `rate` is particles per second across every cell, already
    /// within the placement's budget (see `ambientRate`, `transitionRate`); `up` is +1 when the
    /// layer's y axis points up the screen and -1 when an ancestor flipped it.
    ///
    /// One cell per picture per ink: the style's shape (or each tinted sprite) in every ink, and
    /// each full-colour sprite once in its own colours. The rate is shared across them, so a
    /// block naming four sprites in four inks keeps exactly the budget one shape in one ink had.
    static func configure(
        _ emitter: CAEmitterLayer,
        particles: ThemeParticles,
        colors: [NSColor],
        sprites: [ThemeParticleSprite] = [],
        placement: ThemeParticlePlacement,
        region: CGRect,
        scale: CGFloat,
        rate: Double,
        opacity: Double,
        up: CGFloat
    ) {
        let motion = ThemeParticleMotion(
            particles: particles,
            placement: placement,
            region: region.size
        )
        let pictures = ThemeParticleArtwork.cellPictures(
            particles: particles,
            colors: colors,
            sprites: sprites,
            points: motion.size,
            scale: scale
        )

        place(emitter, motion: motion, region: region, up: up)

        let perCell = Float(max(0, rate) / Double(max(pictures.count, 1)))
        emitter.emitterCells = pictures.enumerated().map { index, picture in
            let ink = picture.ink
            let cell = CAEmitterCell()
            cell.name = "cell\(index)"
            cell.contents = picture.image
            cell.contentsScale = scale
            cell.birthRate = perCell
            cell.lifetime = motion.lifetime
            cell.lifetimeRange = motion.lifetime * 0.15
            cell.velocity = motion.velocity
            cell.velocityRange = motion.velocity * motion.velocitySpread
            cell.xAcceleration = motion.xAcceleration
            cell.yAcceleration = motion.yAcceleration * up
            cell.emissionLongitude = motion.headingUp ? .pi / 2 * up : -.pi / 2 * up
            cell.emissionRange = motion.emissionRange
            cell.spin = motion.spin
            cell.spinRange = motion.spinRange
            cell.scale = 1
            cell.scaleRange = motion.scaleRange
            cell.scaleSpeed = motion.scaleSpeed
            cell.alphaRange = motion.alphaRange
            cell.alphaSpeed = motion.alphaSpeed
            let srgb = ink.usingColorSpace(.sRGB) ?? ink
            // Restated on every configure — a cell's colour is a frozen value like any
            // layer colour, and this call is how the theme sweep reaches it.
            cell.color = srgb.withAlphaComponent(
                srgb.alphaComponent * CGFloat(max(0, min(1, opacity)))
            ).cgColor
            return cell
        }
    }

    /// Puts the emitter's source where a style's particles are born over `region`: a
    /// one-point-tall strip just past the edge they travel from, the whole region for styles
    /// that twinkle in place, or a single point. Split out so a resize can move the source
    /// without re-deriving the cells.
    static func place(
        _ emitter: CAEmitterLayer,
        motion: ThemeParticleMotion,
        region: CGRect,
        up: CGFloat
    ) {
        switch motion.source {
        case .below:
            emitter.emitterShape = .rectangle
            emitter.emitterMode = .volume
            emitter.emitterPosition = CGPoint(
                x: region.midX,
                y: up > 0 ? region.minY - motion.size : region.maxY + motion.size
            )
            emitter.emitterSize = CGSize(width: region.width, height: 1)
        case .above:
            emitter.emitterShape = .rectangle
            emitter.emitterMode = .volume
            emitter.emitterPosition = CGPoint(
                x: region.midX,
                y: up > 0 ? region.maxY + motion.size : region.minY - motion.size
            )
            emitter.emitterSize = CGSize(width: region.width, height: 1)
        case .area:
            emitter.emitterShape = .rectangle
            emitter.emitterMode = .volume
            emitter.emitterPosition = CGPoint(x: region.midX, y: region.midY)
            emitter.emitterSize = region.size
        case .point(let point):
            emitter.emitterShape = .point
            emitter.emitterMode = .volume
            emitter.emitterPosition = point
            emitter.emitterSize = .zero
        }
    }

    /// Particles per second for an ambient field over `region` at the theme's density, clamped
    /// so the field never keeps more than `ThemeParticleBudget.ambientMaximumAlive` alive.
    static func ambientRate(for particles: ThemeParticles, region: CGSize) -> Double {
        let motion = ThemeParticleMotion(particles: particles, placement: .ambient, region: region)
        let density = max(0, min(1, particles.density))
        let wanted: Double
        switch motion.source {
        case .area:
            wanted = density * Double(region.width * region.height) / 9_000
        case .below, .above, .point:
            wanted = density * Double(region.width) / 26
        }
        let ceiling = Double(ThemeParticleBudget.ambientMaximumAlive) / Double(max(motion.lifetime, 0.1))
        return min(wanted, ceiling)
    }

    /// Particles per second at a transition's peak, clamped to
    /// `ThemeParticleBudget.transitionMaximumAlive`.
    static func transitionRate(
        for particles: ThemeParticles,
        region: CGSize,
        duration: TimeInterval
    ) -> Double {
        let motion = ThemeParticleMotion(
            particles: particles,
            placement: .transition(duration: duration),
            region: region
        )
        let density = 0.4 + 0.6 * max(0, min(1, particles.density))
        let wanted: Double
        switch motion.source {
        case .area:
            wanted = density * Double(region.width * region.height) / 2_500
        case .below, .above, .point:
            wanted = density * Double(region.width) / 4
        }
        let ceiling = Double(ThemeParticleBudget.transitionMaximumAlive) / Double(max(motion.lifetime, 0.1))
        return min(wanted, ceiling)
    }

    /// A logo's stream: `intensity` 0…1 scales it between nothing and the density's rate.
    static func streamRate(for particles: ThemeParticles, intensity: Double) -> Double {
        let density = max(0, min(1, particles.density))
        let wanted = (4 + 18 * density) * max(0, min(1, intensity))
        return min(wanted, ThemeParticleBudget.pointMaximumRate)
    }

    /// How many particles one burst from a logo gives off.
    static func burstCount(for particles: ThemeParticles) -> Int {
        let density = max(0, min(1, particles.density))
        return min(Int(10 + 30 * density), ThemeParticleBudget.burstMaximumCount)
    }

    /// Whether a layer's y axis points up the screen — false beneath a flipped ancestor, which
    /// is what the emitter's headings and accelerations are signed by.
    static func upSign(of layer: CALayer) -> CGFloat {
        layer.contentsAreFlipped() ? -1 : 1
    }
}

// MARK: - Motion

/// The numbers a style means at a placement: where particles are born, how they move, how
/// long they live and how big they are. Speeds scale with the theme's `speed`; sizes default
/// per style and follow the theme's `size` when it states one.
struct ThemeParticleMotion {

    enum Source: Equatable {
        case below
        case above
        case area
        case point(CGPoint)
    }

    let source: Source
    /// Points across a particle at rest.
    let size: CGFloat
    let velocity: CGFloat
    /// The share of `velocity` a particle may differ by.
    let velocitySpread: CGFloat
    /// True for styles that travel up the screen; the emitter signs the heading.
    let headingUp: Bool
    let emissionRange: CGFloat
    let xAcceleration: CGFloat
    /// Positive means *toward the heading's up*; the emitter signs it for flipped layers.
    let yAcceleration: CGFloat
    let lifetime: Float
    let spin: CGFloat
    let spinRange: CGFloat
    let scaleRange: CGFloat
    let scaleSpeed: CGFloat
    let alphaRange: Float
    let alphaSpeed: Float

    init(particles: ThemeParticles, placement: ThemeParticlePlacement, region: CGSize) {
        let speed = CGFloat(max(0.25, min(3, particles.speed)))
        let stated = particles.size.map { CGFloat($0) }

        switch placement {
        case .ambient:
            self.init(ambient: particles.style, speed: speed, size: stated, region: region)
        case .point(let point):
            self.init(point: point, style: particles.style, speed: speed, size: stated)
        case .transition(let duration):
            self.init(
                transition: particles.style,
                speed: speed,
                size: stated.map { $0 * 1.6 },
                region: region,
                duration: CGFloat(max(0.4, duration))
            )
        }
    }

    private init(
        source: Source,
        size: CGFloat,
        velocity: CGFloat,
        velocitySpread: CGFloat,
        headingUp: Bool,
        emissionRange: CGFloat,
        xAcceleration: CGFloat = 0,
        yAcceleration: CGFloat = 0,
        lifetime: Float,
        spin: CGFloat = 0,
        spinRange: CGFloat = 0,
        scaleRange: CGFloat,
        scaleSpeed: CGFloat = 0,
        alphaRange: Float,
        alphaSpeed: Float
    ) {
        self.source = source
        self.size = size
        self.velocity = velocity
        self.velocitySpread = velocitySpread
        self.headingUp = headingUp
        self.emissionRange = emissionRange
        self.xAcceleration = xAcceleration
        self.yAcceleration = yAcceleration
        self.lifetime = lifetime
        self.spin = spin
        self.spinRange = spinRange
        self.scaleRange = scaleRange
        self.scaleSpeed = scaleSpeed
        self.alphaRange = alphaRange
        self.alphaSpeed = alphaSpeed
    }

    /// Seconds for a particle leaving one edge to clear the other, with a margin, bounded.
    private static func crossing(
        distance: CGFloat,
        velocity: CGFloat,
        acceleration: CGFloat,
        margin: CGFloat
    ) -> Float {
        let travel = distance + margin * 2
        let seconds: CGFloat
        if acceleration > 0.001 {
            seconds = (-velocity + sqrt(velocity * velocity + 2 * acceleration * travel)) / acceleration
        } else {
            seconds = travel / max(velocity, 1)
        }
        return min(Float(seconds * 1.1), ThemeParticleBudget.maximumAmbientLifetime)
    }

    // MARK: Ambient

    private init(ambient style: ThemeParticles.Style, speed: CGFloat, size: CGFloat?, region: CGSize) {
        switch style {
        case .fizz:
            let size = size ?? 9
            let velocity = 38 * speed
            let acceleration = 9 * speed
            self.init(
                source: .below, size: size, velocity: velocity, velocitySpread: 0.42,
                headingUp: true, emissionRange: .pi / 14, yAcceleration: acceleration,
                lifetime: Self.crossing(
                    distance: region.height, velocity: velocity,
                    acceleration: acceleration, margin: size
                ),
                scaleRange: 0.45, scaleSpeed: 0.03, alphaRange: 0.3, alphaSpeed: -0.03
            )
        case .snow:
            let size = size ?? 8
            let velocity = 24 * speed
            self.init(
                source: .above, size: size, velocity: velocity, velocitySpread: 0.4,
                headingUp: false, emissionRange: .pi / 8, xAcceleration: 2.5 * speed,
                lifetime: Self.crossing(
                    distance: region.height, velocity: velocity, acceleration: 0, margin: size
                ),
                spin: 0.3, spinRange: 1.2, scaleRange: 0.5, alphaRange: 0.35, alphaSpeed: -0.02
            )
        case .sparkle:
            self.init(
                source: .area, size: size ?? 8, velocity: 4 * speed, velocitySpread: 1,
                headingUp: true, emissionRange: .pi * 2, lifetime: Float(1.8 / speed),
                spin: 0.6, spinRange: 1, scaleRange: 0.5, scaleSpeed: -0.25 * speed,
                alphaRange: 0.2, alphaSpeed: Float(-0.55 * speed)
            )
        case .confetti:
            let size = size ?? 7
            let velocity = 30 * speed
            let acceleration = 6 * speed
            self.init(
                source: .above, size: size, velocity: velocity, velocitySpread: 0.4,
                headingUp: false, emissionRange: .pi / 6, yAcceleration: -acceleration,
                lifetime: Self.crossing(
                    distance: region.height, velocity: velocity,
                    acceleration: acceleration, margin: size
                ),
                spin: 2.4, spinRange: 3, scaleRange: 0.3, alphaRange: 0.2, alphaSpeed: -0.02
            )
        case .embers:
            let size = size ?? 5
            let velocity = 20 * speed
            let acceleration = 5 * speed
            let lifetime = Self.crossing(
                distance: region.height, velocity: velocity,
                acceleration: acceleration, margin: size
            ) * 0.65
            self.init(
                source: .below, size: size, velocity: velocity, velocitySpread: 0.5,
                headingUp: true, emissionRange: .pi / 8, yAcceleration: acceleration,
                lifetime: lifetime, scaleRange: 0.6, scaleSpeed: -0.02,
                alphaRange: 0.3, alphaSpeed: -1 / max(lifetime, 1)
            )
        }
    }

    // MARK: Point

    private init(point: CGPoint, style: ThemeParticles.Style, speed: CGFloat, size: CGFloat?) {
        switch style {
        case .fizz:
            self.init(
                source: .point(point), size: size ?? 5, velocity: 28 * speed, velocitySpread: 0.36,
                headingUp: true, emissionRange: .pi / 5, yAcceleration: 26 * speed,
                lifetime: 1.3, scaleRange: 0.4, scaleSpeed: 0.15, alphaRange: 0.2,
                alphaSpeed: -0.55
            )
        case .snow:
            self.init(
                source: .point(point), size: size ?? 5, velocity: 22 * speed, velocitySpread: 0.45,
                headingUp: true, emissionRange: .pi / 2.2, yAcceleration: -30 * speed,
                lifetime: 1.6, spin: 0.8, spinRange: 1.4, scaleRange: 0.4, alphaRange: 0.2,
                alphaSpeed: -0.5
            )
        case .sparkle:
            self.init(
                source: .point(point), size: size ?? 6, velocity: 16 * speed, velocitySpread: 0.6,
                headingUp: true, emissionRange: .pi * 2, lifetime: 0.9, spin: 1, spinRange: 2,
                scaleRange: 0.4, scaleSpeed: -0.5, alphaRange: 0.1, alphaSpeed: -1
            )
        case .confetti:
            self.init(
                source: .point(point), size: size ?? 5, velocity: 70 * speed, velocitySpread: 0.36,
                headingUp: true, emissionRange: .pi / 2.6, yAcceleration: -160 * speed,
                lifetime: 1.5, spin: 4, spinRange: 5, scaleRange: 0.3, alphaRange: 0.1,
                alphaSpeed: -0.5
            )
        case .embers:
            self.init(
                source: .point(point), size: size ?? 4, velocity: 18 * speed, velocitySpread: 0.45,
                headingUp: true, emissionRange: .pi / 7, yAcceleration: 14 * speed,
                lifetime: 1.6, scaleRange: 0.5, scaleSpeed: -0.1, alphaRange: 0.3,
                alphaSpeed: -0.6
            )
        }
    }

    // MARK: Transition

    private init(
        transition style: ThemeParticles.Style,
        speed: CGFloat,
        size: CGFloat?,
        region: CGSize,
        duration: CGFloat
    ) {
        let lifetime = Float(duration * 0.85)
        switch style {
        case .fizz:
            let velocity = region.height / (duration * 0.6) * speed
            self.init(
                source: .below, size: size ?? 13, velocity: velocity, velocitySpread: 0.3,
                headingUp: true, emissionRange: .pi / 14, yAcceleration: velocity,
                lifetime: lifetime, scaleRange: 0.5, scaleSpeed: 0.1, alphaRange: 0.2,
                alphaSpeed: -0.2
            )
        case .snow:
            let velocity = region.height / (duration * 0.65) * speed
            self.init(
                source: .above, size: size ?? 11, velocity: velocity, velocitySpread: 0.3,
                headingUp: false, emissionRange: .pi / 9, xAcceleration: 30,
                lifetime: lifetime, spin: 0.6, spinRange: 2, scaleRange: 0.5, alphaRange: 0.2,
                alphaSpeed: -0.2
            )
        case .sparkle:
            self.init(
                source: .area, size: size ?? 14, velocity: 20 * speed, velocitySpread: 1,
                headingUp: true, emissionRange: .pi * 2, lifetime: 0.6, spin: 1.2, spinRange: 2,
                scaleRange: 0.5, scaleSpeed: -0.6, alphaRange: 0.1, alphaSpeed: -1.4
            )
        case .confetti:
            let velocity = region.height / (duration * 0.7) * speed
            self.init(
                source: .above, size: size ?? 10, velocity: velocity, velocitySpread: 0.3,
                headingUp: false, emissionRange: .pi / 5, yAcceleration: -velocity * 0.6,
                lifetime: lifetime, spin: 5, spinRange: 6, scaleRange: 0.3, alphaRange: 0.1,
                alphaSpeed: -0.15
            )
        case .embers:
            let velocity = region.height / (duration * 0.7) * speed
            self.init(
                source: .below, size: size ?? 7, velocity: velocity, velocitySpread: 0.4,
                headingUp: true, emissionRange: .pi / 8, yAcceleration: velocity / 2,
                lifetime: lifetime, scaleRange: 0.5, scaleSpeed: -0.05, alphaRange: 0.2,
                alphaSpeed: -1 / max(lifetime, 0.4)
            )
        }
    }
}

// MARK: - Artwork

/// The sprites every theme's particles are drawn with. The host draws them — a document names
/// a shape, never supplies code or a raster — in white, so one sprite serves every ink.
enum ThemeParticleArtwork {

    /// `NSCache` is documented thread-safe, so the unchecked opt-out states a fact rather than
    /// a hope; sprites are only ever drawn from the main actor today.
    nonisolated(unsafe) private static let cache = NSCache<NSString, CGImage>()
    /// Rasterised theme sprites, keyed by stored file, tint and pixel size. The entry keeps the
    /// picture it was drawn from, so a file replaced under the same name is drawn afresh rather
    /// than served from a raster of its predecessor.
    nonisolated(unsafe) private static let spriteCache = NSCache<NSString, SpriteRaster>()

    private final class SpriteRaster {
        let source: CGImage
        let raster: CGImage

        init(source: CGImage, raster: CGImage) {
            self.source = source
            self.raster = raster
        }
    }

    /// One emitter cell's picture and the ink it is drawn in.
    struct CellPicture {
        let image: CGImage?
        let ink: NSColor
    }

    /// The cells a block draws: the style's shape in every ink, or each tinted sprite in every
    /// ink and each full-colour sprite once. The pictures are white (tinted) or their own
    /// colours, and the cell's colour does the rest.
    static func cellPictures(
        particles: ThemeParticles,
        colors: [NSColor],
        sprites: [ThemeParticleSprite],
        points: CGFloat,
        scale: CGFloat
    ) -> [CellPicture] {
        let inks = colors.isEmpty ? [NSColor.white] : colors
        guard !sprites.isEmpty else {
            let image = sprite(particles.resolvedShape, points: points, scale: scale)
            return inks.map { CellPicture(image: image, ink: $0) }
        }
        return sprites.flatMap { sprite -> [CellPicture] in
            let image = raster(sprite, points: points, scale: scale)
            return sprite.tinted
                ? inks.map { CellPicture(image: image, ink: $0) }
                : [CellPicture(image: image, ink: .white)]
        }
    }

    /// A theme sprite at `points` on its long side, rasterised for `scale` — a white
    /// silhouette when tinted, its own colours otherwise — cached per stored file.
    static func raster(_ sprite: ThemeParticleSprite, points: CGFloat, scale: CGFloat) -> CGImage? {
        let pixels = max(2, Int((points * scale).rounded(.up)))
        let key = "\(sprite.key)|\(sprite.tinted)|\(pixels)" as NSString
        if let cached = spriteCache.object(forKey: key), cached.source === sprite.image {
            return cached.raster
        }
        guard let context = CGContext(
            data: nil,
            width: pixels,
            height: pixels,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        draw(
            sprite,
            in: CGRect(x: 0, y: 0, width: pixels, height: pixels),
            color: CGColor(gray: 1, alpha: 1),
            context: context
        )
        guard let image = context.makeImage() else { return nil }
        spriteCache.setObject(SpriteRaster(source: sprite.image, raster: image), forKey: key)
        return image
    }

    /// Draws a theme sprite fitted into `rect`: as a silhouette in `color` when tinted, in its
    /// own colours at `color`'s alpha otherwise.
    static func draw(
        _ sprite: ThemeParticleSprite,
        in rect: CGRect,
        color: CGColor,
        context: CGContext
    ) {
        let width = CGFloat(sprite.image.width)
        let height = CGFloat(sprite.image.height)
        guard width > 0, height > 0, rect.width > 0, rect.height > 0 else { return }
        let fit = min(rect.width / width, rect.height / height)
        let size = CGSize(width: width * fit, height: height * fit)
        let target = CGRect(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        context.saveGState()
        defer { context.restoreGState() }
        if sprite.tinted {
            // The picture's coverage, filled with the ink: the one paw print in any colour.
            context.beginTransparencyLayer(in: target, auxiliaryInfo: nil)
            context.draw(sprite.image, in: target)
            context.setBlendMode(.sourceIn)
            context.setFillColor(color)
            context.fill(target)
            context.endTransparencyLayer()
        } else {
            context.setAlpha(color.alpha)
            context.draw(sprite.image, in: target)
        }
    }

    /// Stamps the `index`th particle of a block — its shape, or the sprite it would be born
    /// with — the way a still frame or a preview plume does.
    static func stamp(
        _ index: Int,
        particles: ThemeParticles,
        sprites: [ThemeParticleSprite],
        in rect: CGRect,
        color: CGColor,
        context: CGContext
    ) {
        guard !sprites.isEmpty else {
            draw(particles.resolvedShape, in: rect, color: color, context: context)
            return
        }
        draw(sprites[index % sprites.count], in: rect, color: color, context: context)
    }

    /// The shape at `points`, rasterised for `scale`, cached by both.
    static func sprite(_ shape: ThemeParticles.Shape, points: CGFloat, scale: CGFloat) -> CGImage? {
        let pixels = max(2, Int((points * scale).rounded(.up)))
        let key = "\(shape.rawValue)-\(pixels)" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        guard let context = CGContext(
            data: nil,
            width: pixels,
            height: pixels,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        draw(
            shape,
            in: CGRect(x: 0, y: 0, width: pixels, height: pixels),
            color: CGColor(gray: 1, alpha: 1),
            context: context
        )
        guard let image = context.makeImage() else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    /// Draws one particle filling `rect` in `color` — the sprite's own drawing, and what a still
    /// frame stamps where a live emitter would have put one.
    static func draw(
        _ shape: ThemeParticles.Shape,
        in rect: CGRect,
        color: CGColor,
        context: CGContext
    ) {
        let side = min(rect.width, rect.height)
        let square = CGRect(
            x: rect.midX - side / 2,
            y: rect.midY - side / 2,
            width: side,
            height: side
        )
        context.saveGState()
        defer { context.restoreGState() }

        switch shape {
        case .bubble:
            let line = max(1, side * 0.09)
            let ring = square.insetBy(dx: line / 2, dy: line / 2)
            context.setFillColor(color.copy(alpha: color.alpha * 0.14) ?? color)
            context.fillEllipse(in: ring)
            context.setStrokeColor(color.copy(alpha: color.alpha * 0.95) ?? color)
            context.setLineWidth(line)
            context.strokeEllipse(in: ring)
            // The glint that makes a ring read as a bubble rather than a hole: high and to the
            // leading side, where light through a glass would catch it.
            context.setFillColor(color.copy(alpha: color.alpha * 0.9) ?? color)
            context.fillEllipse(in: CGRect(
                x: square.minX + side * 0.26,
                y: square.minY + side * 0.56,
                width: side * 0.2,
                height: side * 0.2
            ))

        case .dot:
            let colors = [color, color.copy(alpha: 0) ?? color] as CFArray
            guard let gradient = CGGradient(
                colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                colors: colors,
                locations: [0.35, 1]
            ) else { return }
            context.drawRadialGradient(
                gradient,
                startCenter: CGPoint(x: square.midX, y: square.midY),
                startRadius: 0,
                endCenter: CGPoint(x: square.midX, y: square.midY),
                endRadius: side / 2,
                options: []
            )

        case .spark:
            let center = CGPoint(x: square.midX, y: square.midY)
            let outer = side / 2
            let inner = side * 0.12
            let path = CGMutablePath()
            for step in 0..<8 {
                let angle = CGFloat(step) * .pi / 4 + .pi / 2
                let radius = step.isMultiple(of: 2) ? outer : inner
                let point = CGPoint(
                    x: center.x + cos(angle) * radius,
                    y: center.y + sin(angle) * radius
                )
                if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            path.closeSubpath()
            context.setFillColor(color)
            context.addPath(path)
            context.fillPath()

        case .flake:
            let center = CGPoint(x: square.midX, y: square.midY)
            let arm = side * 0.46
            let branch = side * 0.16
            context.setStrokeColor(color)
            context.setLineWidth(max(1, side * 0.09))
            context.setLineCap(.round)
            for step in 0..<6 {
                let angle = CGFloat(step) * .pi / 3 + .pi / 2
                let tip = CGPoint(x: center.x + cos(angle) * arm, y: center.y + sin(angle) * arm)
                context.move(to: center)
                context.addLine(to: tip)
                let fork = CGPoint(
                    x: center.x + cos(angle) * arm * 0.6,
                    y: center.y + sin(angle) * arm * 0.6
                )
                for side in [-1.0, 1.0] {
                    let branchAngle = angle + CGFloat(side) * .pi / 4
                    context.move(to: fork)
                    context.addLine(to: CGPoint(
                        x: fork.x + cos(branchAngle) * branch,
                        y: fork.y + sin(branchAngle) * branch
                    ))
                }
            }
            context.strokePath()

        case .ribbon:
            let strip = CGRect(
                x: square.midX - side * 0.22,
                y: square.minY + side * 0.04,
                width: side * 0.44,
                height: side * 0.92
            )
            context.setFillColor(color)
            context.addPath(CGPath(
                roundedRect: strip,
                cornerWidth: side * 0.08,
                cornerHeight: side * 0.08,
                transform: nil
            ))
            context.fillPath()
        }
    }
}

// MARK: - Still Frame

/// A deterministic frame of a field — particles where a running emitter might have put them —
/// drawn once, on the CPU, into an image.
///
/// Two jobs. It is what an ambient field *is* while motion is off (Reduce Motion, the Theme
/// Motion setting, Low Power Mode): a scatter that keeps the theme's look without moving, the
/// way `backdropPattern` keeps a pane's texture. And it is how a render or a preview shows
/// particles at all, because an emitter's particles live only in the render server: neither
/// `cacheDisplay` nor an offscreen `CARenderer` draws them (measured — both return the ground
/// and not one sprite).
enum ThemeParticleStill {

    /// A seamless tile of an ambient field: particles crossing an edge are stamped again on the
    /// opposite one, so a pattern-tiled layer shows no seam.
    static func tile(
        particles: ThemeParticles,
        colors: [NSColor],
        sprites: [ThemeParticleSprite] = [],
        side: CGFloat,
        scale: CGFloat,
        opacity: Double,
        seed: UInt64 = 0x7A3E_11C9
    ) -> CGImage? {
        let pixels = max(8, Int((side * scale).rounded()))
        guard let context = CGContext(
            data: nil,
            width: pixels,
            height: pixels,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.scaleBy(x: scale, y: scale)

        let motion = ThemeParticleMotion(
            particles: particles,
            placement: .ambient,
            region: CGSize(width: side, height: side)
        )
        let density = max(0, min(1, particles.density))
        let count = Int((4 + 26 * density).rounded())
        let inks = colors.isEmpty ? [NSColor.white] : colors
        let styleIndex = ThemeParticles.Style.allCases.firstIndex(of: particles.style) ?? 0
        var random = SeededRandom(seed: seed ^ UInt64(styleIndex + 1))

        for index in 0..<count {
            let spread = random.unit() * 2 - 1
            let size = motion.size * (1 + CGFloat(spread) * motion.scaleRange)
            let point = CGPoint(x: CGFloat(random.unit()) * side, y: CGFloat(random.unit()) * side)
            let ink = (inks[index % inks.count].usingColorSpace(.sRGB) ?? inks[index % inks.count])
            let flicker = 0.55 + 0.45 * random.unit()
            let alpha = ink.alphaComponent * CGFloat(opacity * flicker)
            let color = ink.withAlphaComponent(alpha).cgColor
            for dx in [-side, 0, side] {
                for dy in [-side, 0, side] {
                    let rect = CGRect(
                        x: point.x + dx - size / 2,
                        y: point.y + dy - size / 2,
                        width: size,
                        height: size
                    )
                    guard rect.intersects(CGRect(x: 0, y: 0, width: side, height: side)) else {
                        continue
                    }
                    ThemeParticleArtwork.stamp(
                        index,
                        particles: particles,
                        sprites: sprites,
                        in: rect,
                        color: color,
                        context: context
                    )
                }
            }
        }
        return context.makeImage()
    }

    /// Particles given off from a point, frozen a moment after they left it — what a preview
    /// draws over a logo that would, live, be fizzing.
    static func plume(
        particles: ThemeParticles,
        colors: [NSColor],
        sprites: [ThemeParticleSprite] = [],
        origin: CGPoint,
        in context: CGContext,
        up: CGFloat,
        seed: UInt64 = 0x51F0_2BB3
    ) {
        let motion = ThemeParticleMotion(particles: particles, placement: .point(origin), region: .zero)
        let inks = colors.isEmpty ? [NSColor.white] : colors
        var random = SeededRandom(seed: seed)
        let count = 7
        for index in 0..<count {
            let progress = (Double(index) + random.unit()) / Double(count)
            let jitter = CGFloat(random.unit() * 2 - 1)
            let heading = (motion.headingUp ? CGFloat.pi / 2 : -CGFloat.pi / 2)
                + jitter * motion.emissionRange / 2
            let travel = CGFloat(progress) * motion.velocity * CGFloat(motion.lifetime) * 0.55
            let point = CGPoint(
                x: origin.x + cos(heading) * travel,
                y: origin.y + sin(heading) * travel * up
            )
            let size = motion.size * CGFloat(0.7 + 0.5 * progress)
            let ink = inks[index % inks.count].usingColorSpace(.sRGB) ?? inks[index % inks.count]
            let color = ink.withAlphaComponent(
                ink.alphaComponent * CGFloat(particles.opacity) * CGFloat(1 - 0.6 * progress)
            ).cgColor
            ThemeParticleArtwork.stamp(
                index,
                particles: particles,
                sprites: sprites,
                in: CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size),
                color: color,
                context: context
            )
        }
    }
}

// MARK: - Seeded Random

/// SplitMix64: the same scatter on every run, so a render is comparable to the last one.
struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }

    /// Uniform in 0..<1.
    mutating func unit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
}

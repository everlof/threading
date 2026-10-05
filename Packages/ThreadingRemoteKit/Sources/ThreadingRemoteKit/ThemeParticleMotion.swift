import Foundation
import CoreGraphics

public enum ThemeParticlePlacement: Equatable, Sendable {
    /// Moving under a ground for as long as it is on screen — the sidebar's column, a pane.
    case ambient
    /// Given off from one point — a logo's neck — as a stream or a burst.
    case point(CGPoint)
    /// Crossing a whole window once, during a switch into the theme.
    case transition(duration: TimeInterval)
}

public struct ThemeParticleMotion: Sendable {
    /// Ambient fields cross their region in at most this long, so a tall pane never keeps a
    /// particle alive for a minute. The Mac's emitter budget states the same bound from here.
    public static let maximumAmbientLifetime: Float = 24


    public enum Source: Equatable, Sendable {
        case below
        case above
        case area
        case point(CGPoint)
    }

    public let source: Source
    /// Points across a particle at rest.
    public let size: CGFloat
    public let velocity: CGFloat
    /// The share of `velocity` a particle may differ by.
    public let velocitySpread: CGFloat
    /// True for styles that travel up the screen; the emitter signs the heading.
    public let headingUp: Bool
    public let emissionRange: CGFloat
    public let xAcceleration: CGFloat
    /// Positive means *toward the heading's up*; the emitter signs it for flipped layers.
    public let yAcceleration: CGFloat
    public let lifetime: Float
    public let spin: CGFloat
    public let spinRange: CGFloat
    public let scaleRange: CGFloat
    public let scaleSpeed: CGFloat
    public let alphaRange: Float
    public let alphaSpeed: Float

    public init(style: RemoteThemeParticles.Style, speed: Double, size: Double?, placement: ThemeParticlePlacement, region: CGSize) {
        let speed = CGFloat(max(0.25, min(3, speed)))
        let stated = size.map { CGFloat($0) }

        switch placement {
        case .ambient:
            self.init(ambient: style, speed: speed, size: stated, region: region)
        case .point(let point):
            self.init(point: point, style: style, speed: speed, size: stated)
        case .transition(let duration):
            self.init(
                transition: style,
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
        return min(Float(seconds * 1.1), Self.maximumAmbientLifetime)
    }

    // MARK: Ambient

    private init(ambient style: RemoteThemeParticles.Style, speed: CGFloat, size: CGFloat?, region: CGSize) {
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

    private init(point: CGPoint, style: RemoteThemeParticles.Style, speed: CGFloat, size: CGFloat?) {
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
        transition style: RemoteThemeParticles.Style,
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

import Foundation
import CoreGraphics

/// Shared particle vocabulary and limits; renderers own layers, artwork and lifecycle.
public struct RemoteThemeParticles: Codable, Equatable, Sendable {
    public let style: Style
    public let shape: Shape?
    public let colors: [String]
    public let density: Double
    public let size: Double?
    public let speed: Double
    public let opacity: Double
    public let sprites: [String]?

    public init(style: Style, shape: Shape? = nil, colors: [String] = [],
                density: Double = 0.5, size: Double? = nil, speed: Double = 1,
                opacity: Double = 1, sprites: [String]? = nil) {
        self.style = style; self.shape = shape; self.colors = colors
        self.density = density; self.size = size; self.speed = speed
        self.opacity = opacity; self.sprites = sprites
    }

    public var isValid: Bool {
        colors.count <= 4 && colors.allSatisfy { $0.utf8.count <= 64 }
            && (sprites?.count ?? 0) <= 4
            && (sprites ?? []).allSatisfy { $0.utf8.count <= 128 }
            && density.isFinite && (0...1).contains(density)
            && speed.isFinite && (0.25...3).contains(speed)
            && opacity.isFinite && (0...1).contains(opacity)
            && size.map { $0.isFinite && (1...24).contains($0) } != false
    }

    public var resolvedShape: Shape { shape ?? style.defaultShape }

    public enum Style: String, Codable, CaseIterable, Sendable {
        /// Rising from below and quickening as it goes, the way carbonation does.
        case fizz
        /// Falling from above, swaying.
        case snow
        /// Twinkling in place: each spark swells and fades where it was born.
        case sparkle
        /// Thrown up, tumbling, and falling back under gravity.
        case confetti
        /// Drifting up slowly, flickering out before they arrive.
        case embers

        public var defaultShape: Shape {
            switch self {
            case .fizz: return .bubble
            case .snow: return .flake
            case .sparkle: return .spark
            case .confetti: return .ribbon
            case .embers: return .dot
            }
        }
    }

    // MARK: - Shape

    public enum Shape: String, Codable, CaseIterable, Sendable {
        /// A ring with a highlight — a bubble in a glass.
        case bubble
        /// A soft round dot.
        case dot
        /// A four-pointed star.
        case spark
        /// A six-armed snowflake.
        case flake
        /// A small strip of paper.
        case ribbon
    }
}

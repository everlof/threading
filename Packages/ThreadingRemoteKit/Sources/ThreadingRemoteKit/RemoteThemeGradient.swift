import CoreGraphics
import Foundation

/// A portable, resolved background recipe. It contains no assets, executable code or clock.
/// Both platforms animate locally; an older client simply ignores the optional backdrop.
public struct RemoteThemeGradient: Codable, Equatable, Sendable {
    public struct Stop: Codable, Equatable, Sendable {
        public let color: String
        public let position: Double

        public init(color: String, position: Double) {
            self.color = color
            self.position = position
        }
    }

    public let stops: [Stop]
    public let angleDegrees: Double
    public let drift: ThemeGradientDrift?

    public init(stops: [Stop], angleDegrees: Double, drift: ThemeGradientDrift? = nil) {
        self.stops = stops
        self.angleDegrees = angleDegrees
        self.drift = drift
    }

    /// Check before sorting, allocating colours or installing a layer. Colour decoding belongs
    /// to the native renderer; invalid optional decoration must never discard the theme palette.
    public var hasValidGeometry: Bool {
        (2...8).contains(stops.count) && angleDegrees.isFinite
            && stops.allSatisfy { (0...1).contains($0.position) && $0.color.utf8.count <= 9 }
    }
}

/// One deliberately small motion vocabulary: translate an axial gradient along its own axis.
/// Duration is a complete out-and-back cycle; distance is a fraction of the unit gradient.
/// The same bounds apply to custom documents, tools and both native renderers.
public struct ThemeGradientDrift: Codable, Equatable, Sendable {
    public static let durationRange = 8.0...120.0
    public static let distanceRange = 0.02...0.25
    public static let defaultDuration = 24.0
    public static let defaultDistance = 0.12

    public let duration: Double
    public let distance: Double

    public init(duration: Double = defaultDuration, distance: Double = defaultDistance) {
        self.duration = duration
        self.distance = distance
    }

    private enum CodingKeys: String, CodingKey { case duration, distance }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        duration = try container.decodeIfPresent(Double.self, forKey: .duration) ?? Self.defaultDuration
        distance = try container.decodeIfPresent(Double.self, forKey: .distance) ?? Self.defaultDistance
    }

    public var isValid: Bool {
        Self.durationRange.contains(duration) && Self.distanceRange.contains(distance)
    }

    /// Fixed-size keyframes. The compositor owns every frame between these values; neither
    /// client needs a timer, view invalidation or network message to move the background.
    public static let phases: [Double] = [0, 0.25, 0.5, 0.75, 1]
}

/// CSS-angle geometry shared by the AppKit and UIKit renderers, including their opposite Y axes.
public enum ThemeGradientGeometry {
    public static func endpoints(
        angleDegrees: Double,
        flipped: Bool,
        drift: ThemeGradientDrift? = nil,
        phase: Double = 0
    ) -> (start: CGPoint, end: CGPoint) {
        let angle = angleDegrees.isFinite ? angleDegrees.truncatingRemainder(dividingBy: 360) : 180
        let radians = angle * .pi / 180
        let x = sin(radians)
        let y = cos(radians) * (flipped ? -1 : 1)
        let offset = drift.flatMap { $0.isValid ? $0.distance : nil } ?? 0
        let unitPhase = phase.isFinite ? phase.truncatingRemainder(dividingBy: 1) : 0
        let travel = sin(unitPhase * 2 * .pi) * offset
        return (
            CGPoint(x: 0.5 + x * (travel - 0.5), y: 0.5 + y * (travel - 0.5)),
            CGPoint(x: 0.5 + x * (travel + 0.5), y: 0.5 + y * (travel + 0.5))
        )
    }
}

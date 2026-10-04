import CoreGraphics
import SwiftTerm

/// A phosphor glow: a soft halo beneath a terminal's text, in each run's own colour.
///
/// Optional on a palette and off unless stated, like a CRT that has to be asked to bloom. It is
/// carried by `TerminalTheme`, so it travels with the palette wherever the palette goes — a
/// custom terminal theme, an app theme variant's paired palette, and through Follow App Theme —
/// and `TerminalSession.applyProfile` hands it to SwiftTerm's `TerminalView.textGlow`.
///
/// The bounds are a reading budget as much as a look. A halo wider than 6 points sits on the
/// neighbouring rows' text at ordinary line heights, and one stronger than 0.8 stops reading as
/// light behind the text and starts reading as smudge; below 0.5 points or 0.05 nothing visible
/// is drawn for the cost. See `docs/architecture/themes.md` (2026-10-04).
public struct TerminalGlow: Codable, Equatable, Sendable {

    // MARK: - Properties

    /// How far the halo reaches from a glyph's ink, in points.
    public var radius: CGFloat
    /// The halo's strength, 0 to 1.
    public var opacity: Double

    /// The range a stated radius must fall in, in points.
    public static let radiusRange: ClosedRange<CGFloat> = 0.5...6
    /// The range a stated opacity must fall in.
    public static let opacityRange: ClosedRange<Double> = 0.05...0.8

    /// What a caller that states only one half of a new glow gets for the other: a halo that
    /// reads as a glow on a dark ground without softening the text it sits under.
    public static let standard = TerminalGlow(radius: 2.5, opacity: 0.45)

    // MARK: - Initialization

    public init(radius: CGFloat, opacity: Double) {
        self.radius = radius
        self.opacity = opacity
    }

    // MARK: - Public Methods

    /// Why this glow cannot be stored, naming `field` the way the caller wrote it, or nil when
    /// it is within bounds.
    public func validationError(field: String) -> String? {
        guard radius.isFinite, Self.radiusRange.contains(radius) else {
            return "\(field).radius must be between \(Self.format(Self.radiusRange.lowerBound)) and "
                + "\(Self.format(Self.radiusRange.upperBound)) points."
        }
        guard opacity.isFinite, Self.opacityRange.contains(opacity) else {
            return "\(field).opacity must be between \(Self.format(Self.opacityRange.lowerBound)) "
                + "and \(Self.format(Self.opacityRange.upperBound))."
        }
        return nil
    }

    /// The glow pulled into bounds. A stored document is validated when a tool writes it, but
    /// a hand-edited file is not, so the renderer is only ever handed this.
    public var clamped: TerminalGlow {
        TerminalGlow(
            radius: radius.isFinite
                ? min(max(radius, Self.radiusRange.lowerBound), Self.radiusRange.upperBound)
                : Self.standard.radius,
            opacity: opacity.isFinite
                ? min(max(opacity, Self.opacityRange.lowerBound), Self.opacityRange.upperBound)
                : Self.standard.opacity
        )
    }

    /// The renderer's form of this glow.
    public var textGlow: TerminalTextGlow {
        let bounded = clamped
        return TerminalTextGlow(radius: bounded.radius, opacity: CGFloat(bounded.opacity))
    }

    // MARK: - Private Methods

    private static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    private static func format(_ value: CGFloat) -> String {
        format(Double(value))
    }
}

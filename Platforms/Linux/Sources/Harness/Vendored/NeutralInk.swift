import Foundation

/// Neutral text over an already resolved sRGB ground, independent of AppKit and theme state.
///
/// The host supplies the existing legibility floors and step count. Four fixed rungs each test
/// at most `strengthSteps` stronger alphas (24 in production). Resolve once per actual ground,
/// not once per label in a repeated row. No cache or platform appearance is owned here.
struct NeutralInk: Equatable, Sendable {
    struct RGBA: Equatable, Sendable {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        let alpha: CGFloat

        private var normalized: Bool {
            [red, green, blue, alpha].allSatisfy { $0.isFinite && (0...1).contains($0) }
        }

        fileprivate var canResolve: Bool { normalized }

        fileprivate func withAlpha(_ value: CGFloat) -> Self {
            Self(red: red, green: green, blue: blue, alpha: value)
        }

        fileprivate func composited(over ground: Self) -> Self {
            guard alpha < 1 else { return self }
            func mix(_ top: CGFloat, _ bottom: CGFloat) -> CGFloat {
                top * alpha + bottom * (1 - alpha)
            }
            return Self(
                red: mix(red, ground.red), green: mix(green, ground.green),
                blue: mix(blue, ground.blue), alpha: ground.alpha
            )
        }

        fileprivate var luminance: CGFloat {
            // ThemeContrast's existing breakpoint, deliberately not the Oklab converter's.
            func linear(_ component: CGFloat) -> CGFloat {
                component <= 0.03928
                    ? component / 12.92
                    : pow((component + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }
    }

    enum Base: Equatable, Sendable { case white, black }

    struct Rung: Equatable, Sendable {
        let alpha: CGFloat
        /// The AppKit adapter keeps authored tiers in their original color representation.
        /// Strengthened tiers follow LabelLegibility's conversion to sRGB before changing alpha.
        let strengthened: Bool
    }

    let base: Base
    let label: Rung
    let secondary: Rung
    let tertiary: Rung
    let quaternary: Rung

    /// Nil keeps unsupported colors or a required perceptual fallback with the host's original
    /// implementation. Do not clamp an extended component or substitute an opaque ground.
    static func resolve(
        on ground: RGBA,
        increasedContrast: Bool,
        readingRatio: CGFloat,
        glanceRatio: CGFloat,
        strengthSteps: Int
    ) -> Self? {
        guard ground.canResolve, readingRatio.isFinite, glanceRatio.isFinite,
              readingRatio > 0, glanceRatio > 0, strengthSteps > 0 else { return nil }

        func ratio(_ first: RGBA, _ second: RGBA) -> CGFloat {
            let a = first.luminance
            let b = second.luminance
            return (max(a, b) + 0.05) / (min(a, b) + 0.05)
        }
        let white = RGBA(red: 1, green: 1, blue: 1, alpha: 1)
        let black = RGBA(red: 0, green: 0, blue: 0, alpha: 1)
        let light = ratio(white, ground) >= ratio(black, ground)
        let base = light ? white : black
        let glance = increasedContrast ? readingRatio : glanceRatio

        func rung(_ alpha: CGFloat, at floor: CGFloat, under ceiling: CGFloat = 1) -> Rung? {
            let tier = base.withAlpha(alpha)
            func reads(_ candidate: RGBA) -> Bool {
                ratio(candidate.composited(over: ground), ground) >= floor
            }
            if reads(tier) { return Rung(alpha: alpha, strengthened: false) }
            if alpha < ceiling {
                for step in 1...strengthSteps {
                    let strength = alpha + (ceiling - alpha) * CGFloat(step) / CGFloat(strengthSteps)
                    let candidate = base.withAlpha(strength)
                    if reads(candidate) { return Rung(alpha: strength, strengthened: true) }
                }
            }
            // LabelLegibility's next step uses the host's perceptual color engine. Refuse this
            // value path so the Mac adapter preserves that behavior instead of approximating it.
            return nil
        }

        guard let label = rung(increasedContrast ? 1 : (light ? 0.95 : 0.88), at: readingRatio),
              let secondary = rung(increasedContrast ? 0.82 : (light ? 0.70 : 0.62),
                                   at: readingRatio, under: label.alpha),
              let tertiary = rung(increasedContrast ? 0.68 : (light ? 0.50 : 0.44),
                                  at: readingRatio, under: secondary.alpha),
              let quaternary = rung(increasedContrast ? 0.54 : (light ? 0.32 : 0.28),
                                    at: glance, under: tertiary.alpha) else { return nil }
        return Self(base: light ? .white : .black, label: label, secondary: secondary,
                    tertiary: tertiary, quaternary: quaternary)
    }
}

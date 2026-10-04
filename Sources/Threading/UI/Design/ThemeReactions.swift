import Foundation

// MARK: - Theme Reactions

/// How strongly decoration answers what it reacts to — how busy the agents are and how loud the
/// music is — under the person's Threading-wide **Reaction strength** (Settings ▸ Motion).
///
/// Each theme and extension authors its own response: a logo that fizzes harder with work, a
/// mascot's stream, a shader's rain. What one person finds lively another finds busy, and asking
/// every author to ship a knob would scatter one preference across every theme. So the host owns
/// one scale and applies it where reactive readings enter decoration: 0 holds that decoration at
/// rest, 1 is as authored, 2 doubles it — a half-busy room then drives a full response.
///
/// **Decoration, never facts.** The scale is applied at the presentation boundary only: the
/// working counts, statuses, analyzers that state a workload and every signal an extension reads
/// as data stay true. Ambient time-driven motion is not a reaction and is not scaled; whether
/// anything moves at all stays `ThemeParticleHold`'s answer.
@MainActor
enum ThemeReactions {

    /// The ceiling a person may choose: twice what the theme authored.
    static let maximumStrength = 2.0

    /// The person's scale, `0…maximumStrength`.
    static var strength: Double {
        min(max(DesignSettings.current.themeReactionStrength, 0), maximumStrength)
    }

    /// A `0…1` reading — agent intensity, a music level or band — as decoration should answer it.
    static func scaled(_ reading: Double) -> Double {
        min(max(reading * strength, 0), 1)
    }

    /// A count — agents working — as decoration should answer it. Not capped: the binding that
    /// reads it states its own range.
    static func scaledCount(_ count: Double) -> Double {
        max(count * strength, 0)
    }

    /// A floor a reacting picture keeps while it reacts at all — a working mascot's minimum
    /// stream — so 0% leaves it still and anything above 100% does not raise the floor.
    static func scaledFloor(_ floor: Double) -> Double {
        floor * min(strength, 1)
    }
}

import Foundation

// MARK: - Theme Reactions

/// How strongly decoration answers what it reacts to — how busy the agents are and how loud the
/// music is — under the person's Threading-wide reaction settings (Settings ▸ Motion).
///
/// Each theme and extension authors its own response: a logo that fizzes harder with work, a
/// mascot's stream, a shader's rain. What one person finds lively another finds busy, and asking
/// every author to ship a knob would scatter one preference across every theme. So the host owns
/// the person's say over all of them, in three parts:
///
/// - **React to agent activity** (`themeReactsToActivity`) — whether work drives decoration at all.
///   Off, an activity reading is absent: a stream holds still, an extension input reads its idle
///   fallback, as though nothing were working.
/// - **Music-reactive themes** (`sharesThemeAudio`, owned by `AudioSpectrumService`) — whether
///   music does. Off, there is no capture and every audio reading is already unavailable, so this
///   owner has nothing to add.
/// - **Reaction strength** (`themeReactionStrength`) — how hard whichever of the two is on answers:
///   0 holds it at rest, 1 is as authored, 2 doubles it, so a half-busy room drives a full
///   response.
///
/// **Decoration, never facts.** All of it applies at the presentation boundary only: working
/// counts, statuses, analyzers that state a workload and every signal an extension reads as data
/// stay true. Ambient time-driven motion is not a reaction and is not scaled; whether anything
/// moves at all stays `ThemeParticleHold`'s answer.
@MainActor
enum ThemeReactions {

    /// The ceiling a person may choose: twice what the theme authored.
    static let maximumStrength = 2.0

    /// The person's scale, `0…maximumStrength`.
    static var strength: Double {
        min(max(DesignSettings.current.themeReactionStrength, 0), maximumStrength)
    }

    /// Whether agent activity may drive decoration at all.
    static var reactsToActivity: Bool {
        DesignSettings.current.themeReactsToActivity
    }

    // MARK: - Music

    /// A `0…1` music level or band as decoration should answer it. Whether music reaches
    /// decoration at all is decided upstream, by capture consent.
    static func scaledMusic(_ reading: Double) -> Double {
        min(max(reading * strength, 0), 1)
    }

    // MARK: - Activity

    /// A `0…1` activity reading — agent intensity, a moment's pulse — as decoration should
    /// answer it, or nil when the person has turned activity reactions off.
    static func activity(_ reading: Double) -> Double? {
        reactsToActivity ? min(max(reading * strength, 0), 1) : nil
    }

    /// A count — agents working — as decoration should answer it, or nil when activity
    /// reactions are off. Not capped: the binding that reads it states its own range.
    static func activityCount(_ count: Double) -> Double? {
        reactsToActivity ? max(count * strength, 0) : nil
    }

    /// `activity(_:)` for a picture that has no notion of absence: a stream at rest.
    static func scaledActivity(_ reading: Double) -> Double {
        activity(reading) ?? 0
    }

    /// A floor a reacting picture keeps while it reacts at all — a working mascot's minimum
    /// stream — so activity off or 0% leaves it still and anything above 100% does not raise it.
    static func activityFloor(_ floor: Double) -> Double {
        reactsToActivity ? floor * min(strength, 1) : 0
    }
}

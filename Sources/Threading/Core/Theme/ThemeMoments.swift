import AppKit

// MARK: - Theme Moments

/// What a theme does when something *happens* — a turn comes back, a session starts waiting on
/// the person — rather than how it looks while nothing does.
///
/// Every other piece of theme motion is ambient (a field that always drifts) or a gesture the
/// person makes (hovering the logo, picking the theme). A moment is the app's own event, answered
/// in the theme's voice: a shower of the theme's particles across the window, a sound from the
/// theme's own file, or both.
///
/// **The host decides when, the theme decides what.** The events are the ones the app already
/// derives for notifications and badges, observed as they are posted; nothing here polls a
/// session or reads a transcript. A burst of events is one moment — the presenter keeps one
/// playing at a time and a cooldown after it (`ThemeMomentLimits.cooldown`) — so five agents
/// finishing together are celebrated once, not five times. Particles obey `ThemeParticleHold`
/// like every other theme motion; a sound obeys the app's own silence gate and the user's
/// explicit sound choices, which always win over a theme's.
public struct ThemeMoments: Equatable {

    public var moments: [ThemeMomentEvent: Moment]

    public init(moments: [ThemeMomentEvent: Moment] = [:]) {
        self.moments = moments
    }

    public subscript(event: ThemeMomentEvent) -> Moment? {
        get { moments[event] }
        set { moments[event] = newValue }
    }

    public var isEmpty: Bool { moments.values.allSatisfy(\.isEmpty) }

    // MARK: - Moment

    public struct Moment: Equatable {
        /// Crossing the window once, the way an arrival's do, without the wash.
        public var particles: ThemeParticles?
        /// Seconds the shower is given off for, held to `ThemeMomentLimits.durationRange`.
        public var duration: Double
        /// A sound in the theme's asset store, played when the user's own choice for this event
        /// is the default.
        public var sound: String?

        public init(
            particles: ThemeParticles? = nil,
            duration: Double = ThemeMomentLimits.defaultDuration,
            sound: String? = nil
        ) {
            self.particles = particles
            self.duration = duration
            self.sound = sound
        }

        public var isEmpty: Bool { particles == nil && sound == nil }
    }
}

// MARK: - Event

/// The app events a theme may answer.
public enum ThemeMomentEvent: String, Codable, CaseIterable, Sendable {
    /// A turn came back: an agent that was working stopped.
    case turnFinished = "turn_finished"
    /// A session started waiting for the person — a permission, a question.
    case needsAttention = "needs_attention"
}

// MARK: - Codable

extension ThemeMoments: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode([String: Moment].self)
        var moments: [ThemeMomentEvent: Moment] = [:]
        for (key, moment) in raw {
            // A newer document's event, read by an older host: skipped, never fatal.
            guard let event = ThemeMomentEvent(rawValue: key) else { continue }
            moments[event] = moment
        }
        self.moments = moments
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(
            Dictionary(uniqueKeysWithValues: moments.map { ($0.key.rawValue, $0.value) })
        )
    }
}

extension ThemeMoments.Moment: Codable {
    private enum CodingKeys: String, CodingKey {
        case particles, duration, sound
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        particles = try container.decodeIfPresent(ThemeParticles.self, forKey: .particles)
        duration = try container.decodeIfPresent(Double.self, forKey: .duration)
            ?? ThemeMomentLimits.defaultDuration
        sound = try container.decodeIfPresent(String.self, forKey: .sound)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(particles, forKey: .particles)
        try container.encode(duration, forKey: .duration)
        try container.encodeIfPresent(sound, forKey: .sound)
    }
}

// MARK: - Limits

public enum ThemeMomentLimits {
    /// Long enough to notice from the corner of an eye, short enough never to be in the way.
    public static let durationRange: ClosedRange<Double> = 0.6...2.4
    public static let defaultDuration: Double = 1.4
    /// After one moment plays, events are absorbed for this long — the rule that makes a burst
    /// of five finishing agents one celebration.
    public static let cooldown: TimeInterval = 8
    /// A moment's shower keeps at most this many particles alive: a gesture, not an arrival.
    public static let maximumAlive = 260
    /// A sound is a short cue, not a song; the store refuses anything larger.
    public static let maximumSoundBytes = 1024 * 1024
    public static let maximumSoundSeconds: Double = 4
    /// Containers ImageIO's sibling for audio, `NSSound`, reads without a codec install.
    public static let soundExtensions: Set<String> = ["aiff", "aif", "caf", "wav", "m4a", "mp3"]

    /// The file a custom theme stores an event's sound under for a variant.
    public static func soundFileName(
        for event: ThemeMomentEvent,
        variant: AppTheme.VariantKind,
        extension pathExtension: String
    ) -> String {
        "\(variant.rawValue)-sound-\(event.rawValue).\(pathExtension)"
    }
}

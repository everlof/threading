import AppKit

// MARK: - Theme Mascot

/// A character the theme stands at the foot of the sidebar — a dog asleep while nothing runs,
/// bouncing while agents work, ears up when a session needs the person, and briefly overjoyed
/// when a turn comes back.
///
/// **A mood is the app's state, read; a pose is the theme's picture of it.** The host decides
/// the mood from the sessions it already tracks (`ThemeMascotMood.resolve`), and the theme
/// supplies one picture per mood it cares about, each with an optional looping motion and an
/// optional stream of particles. A mood the theme leaves out borrows another's pose
/// (`pose(for:)`), so a mascot with only an `idle` pose is valid and simply never changes.
///
/// **Decoration, never a control.** It sits beneath the project list — rows scroll over it, and
/// the list gains bottom breathing room so its last row can always be scrolled clear — takes no
/// clicks, claims no pointer and is not announced. Its motions are presentation-only keyframes
/// that loop in the render server, its streams share the logo's budget
/// (`ThemeParticleBudget.pointMaximumRate`), and every one of them is `ThemeParticleHold`'s to
/// stop: under Reduce Motion, the Theme animations setting or Low Power Mode the mascot still
/// changes pose with the app's state — that is information, not motion — but holds each one
/// still.
public struct ThemeMascot: Equatable {

    /// One picture per mood the theme draws; `idle` is required.
    public var poses: [ThemeMascotMood: Pose]
    /// Points tall. The width follows the pictures' own proportions.
    public var size: Double
    /// Where along the column's foot the mascot stands.
    public var placement: Placement

    public init(
        poses: [ThemeMascotMood: Pose],
        size: Double = ThemeMascotLimits.defaultSize,
        placement: Placement = .trailing
    ) {
        self.poses = poses
        self.size = size
        self.placement = placement
    }

    /// The pose drawn for `mood`: its own when stated, otherwise the one it borrows. Nil only for
    /// `celebrating`, which without a pose of its own is simply not played.
    public func pose(for mood: ThemeMascotMood) -> Pose? {
        if let own = poses[mood] { return own }
        switch mood {
        case .celebrating: return nil
        case .attention: return poses[.working] ?? poses[.idle]
        case .resting, .working, .idle: return poses[.idle]
        }
    }

    public enum Placement: String, Codable, CaseIterable {
        case leading, center, trailing
    }

    // MARK: - Pose

    public struct Pose: Equatable {
        /// The picture, resolved like every other theme asset.
        public var asset: String
        /// A motion looped while the mood lasts. Absent holds the picture still.
        public var motion: Motion?
        /// Seconds from one loop's start to the next, so a sleeping dog breathes slowly and a
        /// working one hops at once. Absent means the motion's own rhythm.
        public var every: Double?
        /// Given off as a stream while the mood lasts — a Z for sleeping, hearts for joy. While
        /// `working` the stream follows how busy the agents are, as the logo's does.
        public var particles: ThemeParticles?
        /// Where particles leave the picture, in its unit square: x from the leading edge, y
        /// from the top. Absent means the top centre.
        public var origin: SidebarStyle.Brand.LogoMotion.Origin?

        public init(
            asset: String,
            motion: Motion? = nil,
            every: Double? = nil,
            particles: ThemeParticles? = nil,
            origin: SidebarStyle.Brand.LogoMotion.Origin? = nil
        ) {
            self.asset = asset
            self.motion = motion
            self.every = every
            self.particles = particles
            self.origin = origin
        }

        public var resolvedOrigin: SidebarStyle.Brand.LogoMotion.Origin {
            origin ?? .init(x: 0.5, y: 0)
        }

        /// The loop's period, held to the bounds whatever the document says.
        public var resolvedEvery: Double {
            let natural = motion?.naturalPeriod ?? ThemeMascotLimits.everyRange.lowerBound
            let stated = every ?? natural
            let range = ThemeMascotLimits.everyRange
            return max(motion?.duration ?? 0, min(max(stated, range.lowerBound), range.upperBound))
        }
    }

    // MARK: - Motion

    /// A movement the host knows how to loop on a mascot. Every one is presentation-only and
    /// ends where it began, so a pose change or a theme switch mid-loop leaves nothing askew.
    /// Amplitudes scale with the mascot's size rather than being fixed points.
    public enum Motion: String, Codable, CaseIterable {
        /// Swells a few percent and settles, slowly — asleep.
        case breathe
        /// Rises and sinks a little, like something floating.
        case bob
        /// A jump: crouch, leap, land.
        case hop
        /// Rocks on its feet from side to side.
        case sway
        /// A quick side-to-side shudder — a wet dog.
        case shake
        /// One full turn — a dog chasing its tail.
        case spin
        /// Squashes, then pops out past its size and back.
        case pop

        /// How long one play of the motion takes.
        public var duration: Double {
            switch self {
            case .breathe: return 2.4
            case .bob: return 1.6
            case .hop: return 0.55
            case .sway: return 1.2
            case .shake: return 0.45
            case .spin: return 0.7
            case .pop: return 0.45
            }
        }

        /// The loop period a pose gets when it states no `every`.
        public var naturalPeriod: Double {
            switch self {
            case .breathe, .bob, .sway: return duration
            case .hop: return 0.9
            case .shake, .spin, .pop: return 3
            }
        }
    }
}

// MARK: - Mood

/// What the app is doing, as a mascot shows it. Resolved by the host from the sessions it
/// already tracks; a theme only ever names these.
public enum ThemeMascotMood: String, Codable, CaseIterable, Sendable {
    /// Nothing is running: every session dormant.
    case resting
    /// Agents are alive and none is working.
    case idle
    /// At least one agent is working.
    case working
    /// At least one session is waiting for the person.
    case attention
    /// For a moment after a turn comes back.
    case celebrating

    /// The mood for a snapshot of the app's sessions. Attention outranks work — a dog that keeps
    /// bouncing while a session waits on the person is hiding the one thing worth showing — and
    /// a celebration outranks both for its moment, because it is the answer to the work that
    /// just ended.
    public static func resolve(
        live: Int,
        working: Int,
        attention: Int,
        celebrating: Bool
    ) -> ThemeMascotMood {
        if celebrating { return .celebrating }
        if attention > 0 { return .attention }
        if working > 0 { return .working }
        if live > 0 { return .idle }
        return .resting
    }
}

// MARK: - Codable

extension ThemeMascot: Codable {
    private enum CodingKeys: String, CodingKey {
        case poses, size, placement
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decode([String: Pose].self, forKey: .poses)
        var poses: [ThemeMascotMood: Pose] = [:]
        for (key, pose) in raw {
            // An unknown mood is a newer document read by an older host: skipped, never fatal.
            guard let mood = ThemeMascotMood(rawValue: key) else { continue }
            poses[mood] = pose
        }
        self.poses = poses
        size = try container.decodeIfPresent(Double.self, forKey: .size)
            ?? ThemeMascotLimits.defaultSize
        placement = try container.decodeIfPresent(Placement.self, forKey: .placement) ?? .trailing
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(
            Dictionary(uniqueKeysWithValues: poses.map { ($0.key.rawValue, $0.value) }),
            forKey: .poses
        )
        try container.encode(size, forKey: .size)
        try container.encode(placement, forKey: .placement)
    }
}

extension ThemeMascot.Pose: Codable {
    private enum CodingKeys: String, CodingKey {
        case asset, motion, every, particles, origin
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        asset = try container.decode(String.self, forKey: .asset)
        motion = try container.decodeIfPresent(ThemeMascot.Motion.self, forKey: .motion)
        every = try container.decodeIfPresent(Double.self, forKey: .every)
        particles = try container.decodeIfPresent(ThemeParticles.self, forKey: .particles)
        origin = try container.decodeIfPresent(
            SidebarStyle.Brand.LogoMotion.Origin.self,
            forKey: .origin
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(asset, forKey: .asset)
        try container.encodeIfPresent(motion, forKey: .motion)
        try container.encodeIfPresent(every, forKey: .every)
        try container.encodeIfPresent(particles, forKey: .particles)
        try container.encodeIfPresent(origin, forKey: .origin)
    }
}

// MARK: - Limits

public enum ThemeMascotLimits {
    /// Points tall. Below 32 it is an icon; above 120 it stops standing at the foot of the list
    /// and starts covering it.
    public static let sizeRange: ClosedRange<Double> = 32...120
    public static let defaultSize: Double = 72
    /// Seconds between loops. Faster than every 0.4 s is a vibration; slower than 20 s nobody
    /// sees it move.
    public static let everyRange: ClosedRange<Double> = 0.4...20
    /// How long a celebration lasts before the mascot returns to what the app is doing.
    public static let celebrationDuration: TimeInterval = 3.2
    /// A pose picture is stored at 2× of the largest size, on its long side.
    public static let storedPixelSize = 256
    public static let maximumImageBytes = 2 * 1024 * 1024

    /// The file a custom theme stores a pose's picture under for a variant.
    public static func fileName(for mood: ThemeMascotMood, variant: AppTheme.VariantKind) -> String {
        "\(variant.rawValue)-mascot-\(mood.rawValue).png"
    }
}

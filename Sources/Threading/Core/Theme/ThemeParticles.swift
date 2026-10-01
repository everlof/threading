import AppKit

// MARK: - Theme Ink

/// A colour a theme states for something the host draws on its behalf: either one of the
/// variant's own semantic roles, or a literal.
///
/// A role is the better answer almost everywhere — `"accent"` follows the variant it is stated
/// in, so an adaptive theme's light and dark halves can share one particle block and still get
/// their own reds — but a literal is sometimes the point: a bubble is white on every ground.
/// On the wire a role is its wire name and a literal is hex, so the two spellings cannot
/// collide (`AppThemeRole` wire names never start with `#`).
public enum ThemeInk: Equatable {
    case role(AppThemeRole)
    case color(NSColor)

    /// The colour this ink paints with under `theme` in `appearance`.
    public func resolved(in theme: AppTheme, appearance: NSAppearance) -> NSColor {
        switch self {
        case .role(let role):
            return theme.resolved(role, appearance: appearance)
        case .color(let color):
            return color
        }
    }

    /// The wire spelling: a role's wire name or `#RRGGBB(AA)`.
    public var wireValue: String {
        switch self {
        case .role(let role): return role.wireName
        case .color(let color): return color.hexString
        }
    }

    /// Parses the wire spelling, or nil for a word that is neither a role nor a colour.
    public init?(wireValue: String) {
        let clean = wireValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.hasPrefix("#") {
            guard let color = NSColor(hex: clean) else { return nil }
            self = .color(color)
        } else if let role = AppThemeRole.named(clean) {
            self = .role(role)
        } else {
            return nil
        }
    }
}

extension ThemeInk: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let parsed = ThemeInk(wireValue: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "\(raw) is neither a theme role nor a #RRGGBB colour."
            )
        }
        self = parsed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue)
    }
}

// MARK: - Theme Particles

/// Particles a theme asks the host to draw — bubbles, snow, sparks, confetti, embers.
///
/// One vocabulary with three homes, so a theme states its particles once in one grammar and
/// every place it appears reads the same:
///
/// - `ThemeBackdrop.particles` — an ambient field moving under a ground the theme already
///   dresses: the sidebar's column (`SidebarStyle.background`) and the app's broad grounds
///   (`AppTheme.Material.backdrop`).
/// - `SidebarStyle.Brand.LogoMotion.particles` — what the theme's logo gives off when it is hovered,
///   pressed, first shown, and while agents are working.
/// - `ThemeTransition.particles` — the burst that carries a switch *into* the theme.
///
/// **Data, not code.** A style names a motion the host knows how to draw and a shape names
/// artwork the host draws itself, so a document cannot ship a shader or an unbounded emitter.
/// Everything a theme could get wrong stays the host's: the particle budget at each placement,
/// the ceiling on an ambient field's strength, the hold while a window is unseen, the user's
/// Theme Motion setting, and Reduce Motion — under which an ambient field becomes a still
/// scatter and the gestures and transitions do not play at all.
public struct ThemeParticles: Equatable {

    /// The motion. Each style has a shape it draws when the theme names none.
    public var style: Style
    /// Overrides the style's own artwork — snow drawn as dots, fizz drawn as sparks.
    public var shape: Shape?
    /// Names from the stating variant's sprite library (`AppTheme.Variant.sprites`), drawn in
    /// place of a host shape — paw prints, hearts, a theme's own little sheep. Each particle
    /// takes one. Empty means the host shape; validation refuses a block naming both, and a
    /// name that resolves to no stored image degrades to the style's own shape.
    public var sprites: [String]
    /// One to four inks; each particle takes one. Empty means the variant's accent.
    public var colors: [ThemeInk]
    /// 0…1 — how much of the placement's particle budget the theme asks for.
    public var density: Double
    /// Points across a particle at rest. Absent means the style's own size.
    public var size: Double?
    /// A multiplier on the style's own speed.
    public var speed: Double
    /// 0…1 over whatever is beneath. An ambient field is additionally held under
    /// `ThemeParticleLimits.ambientOpacityCeiling`, because it moves under text.
    public var opacity: Double

    public init(
        style: Style,
        shape: Shape? = nil,
        sprites: [String] = [],
        colors: [ThemeInk] = [],
        density: Double = ThemeParticleLimits.defaultDensity,
        size: Double? = nil,
        speed: Double = 1,
        opacity: Double = 1
    ) {
        self.style = style
        self.shape = shape
        self.sprites = sprites
        self.colors = colors
        self.density = density
        self.size = size
        self.speed = speed
        self.opacity = opacity
    }

    /// The artwork actually drawn.
    public var resolvedShape: Shape { shape ?? style.defaultShape }

    /// The inks actually drawn — the accent when the theme named none.
    public var resolvedInks: [ThemeInk] { colors.isEmpty ? [.role(.accent)] : colors }

    // MARK: - Style

    public enum Style: String, Codable, CaseIterable {
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

    public enum Shape: String, Codable, CaseIterable {
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

extension ThemeParticles: Codable {
    private enum CodingKeys: String, CodingKey {
        case style, shape, sprites, colors, density, size, speed, opacity
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        style = try container.decode(Style.self, forKey: .style)
        shape = try container.decodeIfPresent(Shape.self, forKey: .shape)
        sprites = try container.decodeIfPresent([String].self, forKey: .sprites) ?? []
        colors = try container.decodeIfPresent([ThemeInk].self, forKey: .colors) ?? []
        density = try container.decodeIfPresent(Double.self, forKey: .density)
            ?? ThemeParticleLimits.defaultDensity
        size = try container.decodeIfPresent(Double.self, forKey: .size)
        speed = try container.decodeIfPresent(Double.self, forKey: .speed) ?? 1
        opacity = try container.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(style, forKey: .style)
        try container.encodeIfPresent(shape, forKey: .shape)
        if !sprites.isEmpty { try container.encode(sprites, forKey: .sprites) }
        if !colors.isEmpty { try container.encode(colors, forKey: .colors) }
        try container.encode(density, forKey: .density)
        try container.encodeIfPresent(size, forKey: .size)
        try container.encode(speed, forKey: .speed)
        try container.encode(opacity, forKey: .opacity)
    }
}

// MARK: - Theme Transition

/// How a switch *into* a theme is carried: particles in the incoming variant's colours rise,
/// fall or twinkle across the window, a wash of the incoming ground dims the old chrome, the
/// theme is swapped at the moment it is most covered, and the wash lifts off the new one.
///
/// Played only on a deliberate switch — a pick in Settings, the command, an agent's
/// `set_app_theme` — and never for macOS changing appearance under an adaptive theme, a
/// launch restoring the standing choice, or a live edit repainting the theme already worn.
/// The host owns the overlay, its timing bound, pointer passthrough, accessibility silence,
/// and every reason not to play (Reduce Motion, the Theme Motion setting, no visible window).
public struct ThemeTransition: Equatable {
    public var particles: ThemeParticles
    /// Seconds from the first particle to the wash lifting, held to
    /// `ThemeParticleLimits.transitionDurationRange`.
    public var duration: Double
    /// What the wash dims the window toward. Absent means the incoming variant's ground,
    /// which is what makes the swap underneath it read as a dissolve rather than a cut.
    public var wash: ThemeInk?
    /// How far the wash rises at the swap, 0…`ThemeParticleLimits.maximumWashOpacity`.
    public var washOpacity: Double
    /// Adds a diagonal band of light that sweeps the window, crossing its middle at the swap.
    public var shimmer: Bool

    public init(
        particles: ThemeParticles,
        duration: Double = ThemeParticleLimits.defaultTransitionDuration,
        wash: ThemeInk? = nil,
        washOpacity: Double = ThemeParticleLimits.defaultWashOpacity,
        shimmer: Bool = false
    ) {
        self.particles = particles
        self.duration = duration
        self.wash = wash
        self.washOpacity = washOpacity
        self.shimmer = shimmer
    }
}

extension ThemeTransition: Codable {
    private enum CodingKeys: String, CodingKey {
        case particles, duration, wash, washOpacity, shimmer
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        particles = try container.decode(ThemeParticles.self, forKey: .particles)
        duration = try container.decodeIfPresent(Double.self, forKey: .duration)
            ?? ThemeParticleLimits.defaultTransitionDuration
        wash = try container.decodeIfPresent(ThemeInk.self, forKey: .wash)
        washOpacity = try container.decodeIfPresent(Double.self, forKey: .washOpacity)
            ?? ThemeParticleLimits.defaultWashOpacity
        shimmer = try container.decodeIfPresent(Bool.self, forKey: .shimmer) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(particles, forKey: .particles)
        try container.encode(duration, forKey: .duration)
        try container.encodeIfPresent(wash, forKey: .wash)
        try container.encode(washOpacity, forKey: .washOpacity)
        try container.encode(shimmer, forKey: .shimmer)
    }
}

// MARK: - Limits

/// The bounds validation holds particle blocks to, stated beside the model so a limit and the
/// field it limits travel together. The per-placement *budgets* — how many particles may be
/// alive at once — are the renderer's, because they are about frames rather than documents.
public enum ThemeParticleLimits {
    public static let maximumColors = 4
    /// Sprites one block may name. Every sprite is drawn in every ink, so this and
    /// `maximumColors` bound a block's emitter cells at sixteen whatever the library holds.
    public static let maximumSprites = 4
    public static let defaultDensity = 0.5
    public static let densityRange: ClosedRange<Double> = 0...1
    /// Points. Below one a particle is a sub-pixel shimmer nobody asked for; above twenty-four
    /// it is a decoration, not a particle.
    public static let sizeRange: ClosedRange<Double> = 1...24
    public static let speedRange: ClosedRange<Double> = 0.25...3
    public static let opacityRange: ClosedRange<Double> = 0...1

    /// An ambient field moves *under* the words a person reads, so its strength has a ceiling
    /// no document can raise — the extension backdrop plane's 60%, for the same reason.
    public static let ambientOpacityCeiling = 0.6

    /// Long enough to see, short enough never to be waited on. The swap happens inside it, so
    /// the upper bound is also how long the old theme can stay visible after a pick.
    public static let transitionDurationRange: ClosedRange<Double> = 0.4...2.4
    public static let defaultTransitionDuration = 1.2
    /// The wash may dim the old chrome a long way but never replace it: at full strength the
    /// window would blink to a flat colour, which is a cut with extra steps.
    public static let maximumWashOpacity = 0.9
    public static let defaultWashOpacity = 0.55
}

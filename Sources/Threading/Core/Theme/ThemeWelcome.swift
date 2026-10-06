import AppKit
import ThreadingRemoteKit

// MARK: - Theme Welcome

/// The new-session composer's welcome (⌘N) in the theme's hands: what fills the pane, what
/// stands above the greeting, what the greeting says and how it is set.
///
/// **The geometry stays the app's.** The prompt hangs from the pane's bottom edge and the hero
/// (a mark over the greeting) floats centred in the room above it. A theme designs *around*
/// that layout rather than moving it: its backdrop fills the whole pane, optional scrims keep
/// the two working regions legible over busy art, and an extension surface on
/// `composer.backdrop@1` is told where both regions sit, so a design can frame them instead of
/// guessing where they will be.
///
/// **The words are the author's.** Greeting and caption lines are shown as written in every
/// language (the `ThemeWords` rule), with `{token}`s the host fills from the moment they are
/// shown — the time, the date, the project — and optional conditions that make a line eligible
/// only at some hours, on some days or between two dates. Nothing a person reads to understand
/// state lives here: the prompt's placeholder is `ThemeWords.composerPlaceholder`, and every
/// control keeps its own localized words.
public struct ThemeWelcome: Equatable {

    /// Fills the composer pane beneath the hero and the prompt. Absent leaves the pane the app's.
    public var backdrop: ThemeBackdrop?
    /// What stands above the greeting. Absent means the app's mark.
    public var mark: Mark?
    /// The mark's side, in points. Absent means the app's size.
    public var markSize: Double?
    /// The heading line. Absent means the app's own greeting, set the app's way.
    public var greeting: Wording?
    /// An optional smaller line beneath the greeting. The app has none of its own.
    public var caption: Wording?
    /// Soft veils in the ground colour behind the hero and the prompt.
    public var scrim: Scrim?

    public init(
        backdrop: ThemeBackdrop? = nil,
        mark: Mark? = nil,
        markSize: Double? = nil,
        greeting: Wording? = nil,
        caption: Wording? = nil,
        scrim: Scrim? = nil
    ) {
        self.backdrop = backdrop
        self.mark = mark
        self.markSize = markSize
        self.greeting = greeting
        self.caption = caption
        self.scrim = scrim
    }

    public var isEmpty: Bool {
        (backdrop?.isEmpty ?? true) && mark == nil && markSize == nil
            && greeting == nil && caption == nil && scrim == nil
    }

    // MARK: Mark

    public enum Mark: String, Codable, CaseIterable {
        /// The Threading mark, drawn in as the app draws it.
        case app
        /// The theme's own logo — the sidebar brand's picture. The app's mark when it has none.
        case logo
        /// The theme's mascot, in the mood the window's sessions are in. The app's mark when the
        /// theme has no mascot.
        case mascot
        /// Nothing: the greeting stands alone. Spelled `none` on the wire; `hidden` in Swift,
        /// because `.none` against a `Mark?` silently means "not stated".
        case hidden = "none"
    }

    // MARK: Wording

    /// A pool of lines, one of which is shown each time the composer is arrived at.
    public struct Wording: Equatable {
        public var lines: [Line]
        /// Whether the app's own greetings stay in the pool beside the theme's. Only the greeting
        /// has app lines; a caption ignores it.
        public var includesAppLines: Bool
        public var style: TextStyle?

        public init(lines: [Line], includesAppLines: Bool = false, style: TextStyle? = nil) {
            self.lines = lines
            self.includesAppLines = includesAppLines
            self.style = style
        }
    }

    /// One line of a pool: the author's text, when it may be shown and its weight. Shared with
    /// the phone, which picks and renders the same lines on its own clock.
    public typealias Line = ThemeWelcomeGrammar.Line

    /// How a greeting or caption is set. Every field is optional; absent ones keep the app's.
    public struct TextStyle: Equatable {
        /// Size relative to the app's heading (greeting) or body (caption) size.
        public var scale: Double?
        public var weight: Weight?
        public var ink: ThemeInk?
        /// A family the theme ships (`add_app_theme_font`) or one installed on this Mac.
        public var fontFamily: String?
        /// A system design, used when no family is stated or it is unavailable.
        public var typeface: AppTheme.Material.Typeface?

        public init(
            scale: Double? = nil,
            weight: Weight? = nil,
            ink: ThemeInk? = nil,
            fontFamily: String? = nil,
            typeface: AppTheme.Material.Typeface? = nil
        ) {
            self.scale = scale
            self.weight = weight
            self.ink = ink
            self.fontFamily = fontFamily
            self.typeface = typeface
        }

        public enum Weight: String, Codable, CaseIterable {
            case light, regular, medium, semibold, bold, heavy

            public var appKitWeight: NSFont.Weight {
                switch self {
                case .light: return .light
                case .regular: return .regular
                case .medium: return .medium
                case .semibold: return .semibold
                case .bold: return .bold
                case .heavy: return .heavy
                }
            }
        }
    }

    /// Soft ground-coloured veils behind the two regions the person works in, so a busy picture
    /// or a bright particle field never sits straight under the greeting or the prompt.
    public struct Scrim: Equatable, Codable {
        /// The veil's peak opacity behind the hero.
        public var hero: Double?
        /// The veil's peak opacity behind the prompt.
        public var prompt: Double?

        public init(hero: Double? = nil, prompt: Double? = nil) {
            self.hero = hero
            self.prompt = prompt
        }
    }

    // MARK: Conditions

    // The grammar's vocabulary lives in ThreadingRemoteKit (`ThemeWelcomeGrammar`) so the phone
    // reads a theme's lines exactly as the Mac does. These names keep the Mac's spelling.

    /// When a line may be shown. Every stated facet must match; within a facet any value does.
    public typealias Condition = ThemeWelcomeGrammar.Condition
    /// The four parts of the day the app's own greeting already speaks in.
    public typealias Daypart = ThemeWelcomeGrammar.Daypart
    public typealias Weekday = ThemeWelcomeGrammar.Weekday
    /// An inclusive range of hours, 0…23. `from` after `to` wraps midnight (22–2).
    public typealias Hours = ThemeWelcomeGrammar.Hours
    /// An inclusive range of calendar days, written `MM-DD`, in any year.
    public typealias DateSpan = ThemeWelcomeGrammar.DateSpan
    public typealias MonthDay = ThemeWelcomeGrammar.MonthDay
    /// The `{token}` grammar a line is written in (`ThemeWelcomeGrammar.Template`).
    public typealias Template = ThemeWelcomeGrammar.Template
    /// Everything a token can be filled from, gathered by the host when the composer is shown.
    public typealias Context = ThemeWelcomeGrammar.Context
}

// MARK: - Limits

/// The grammar's own bounds (lines, weights, hours, months, date spans) are
/// `ThemeWelcomeGrammar.Limits`, restated here so every Mac call site reads one table.
public enum ThemeWelcomeLimits {
    /// A pool large enough for a year of dated lines and still bounded to scan per arrival.
    public static let maximumLines = ThemeWelcomeGrammar.Limits.maximumLines
    /// The hero floats in the room above the prompt; a longer line wraps past what it holds.
    public static let maximumLineLength = ThemeWelcomeGrammar.Limits.maximumLineLength
    public static let weights = ThemeWelcomeGrammar.Limits.weights
    public static let markSides: ClosedRange<Double> = 16...160
    public static let greetingScales: ClosedRange<Double> = 0.5...3
    public static let scrimOpacities: ClosedRange<Double> = 0...0.9
    public static let hours = ThemeWelcomeGrammar.Limits.hours
    public static let months = ThemeWelcomeGrammar.Limits.months
    public static let maximumDateSpans = ThemeWelcomeGrammar.Limits.maximumDateSpans
    /// A family name, not a sentence.
    public static let maximumFontFamilyLength = 128
}

// MARK: - Selection

extension ThemeWelcome.Wording {

    /// The lines that may be shown at `context`, rendered: their conditions hold and every
    /// token they use has a value.
    public func eligible(at context: ThemeWelcome.Context) -> [(line: ThemeWelcome.Line, text: String)] {
        ThemeWelcomeGrammar.eligible(lines, at: context)
    }

    /// One eligible line, weighted, or nil when none is.
    public func pick(
        at context: ThemeWelcome.Context,
        using generator: inout some RandomNumberGenerator
    ) -> ThemeWelcome.Line? {
        ThemeWelcomeGrammar.pick(lines, at: context, using: &generator)
    }
}

// MARK: - Codable

extension ThemeWelcome: Codable {
    private enum CodingKeys: String, CodingKey {
        case backdrop, mark, markSize, greeting, caption, scrim
    }

    /// Optional decoration decodes tolerantly, as the variant's other character blocks do: a
    /// field a newer build wrote in a shape this one does not know is dropped, not fatal.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        backdrop = try? container.decodeIfPresent(ThemeBackdrop.self, forKey: .backdrop)
        mark = try? container.decodeIfPresent(Mark.self, forKey: .mark)
        markSize = try? container.decodeIfPresent(Double.self, forKey: .markSize)
        greeting = try? container.decodeIfPresent(Wording.self, forKey: .greeting)
        caption = try? container.decodeIfPresent(Wording.self, forKey: .caption)
        scrim = try? container.decodeIfPresent(Scrim.self, forKey: .scrim)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let backdrop, !backdrop.isEmpty { try container.encode(backdrop, forKey: .backdrop) }
        try container.encodeIfPresent(mark, forKey: .mark)
        try container.encodeIfPresent(markSize, forKey: .markSize)
        try container.encodeIfPresent(greeting, forKey: .greeting)
        try container.encodeIfPresent(caption, forKey: .caption)
        try container.encodeIfPresent(scrim, forKey: .scrim)
    }
}

extension ThemeWelcome.Wording: Codable {
    private enum CodingKeys: String, CodingKey {
        case lines, includesAppLines, style
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lines = try container.decodeIfPresent([ThemeWelcome.Line].self, forKey: .lines) ?? []
        includesAppLines = try container.decodeIfPresent(Bool.self, forKey: .includesAppLines) ?? false
        style = try? container.decodeIfPresent(ThemeWelcome.TextStyle.self, forKey: .style)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(lines, forKey: .lines)
        if includesAppLines { try container.encode(true, forKey: .includesAppLines) }
        try container.encodeIfPresent(style, forKey: .style)
    }
}

extension ThemeWelcome.TextStyle: Codable {
    private enum CodingKeys: String, CodingKey {
        case scale, weight, ink, fontFamily, typeface
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        scale = try? container.decodeIfPresent(Double.self, forKey: .scale)
        weight = try? container.decodeIfPresent(Weight.self, forKey: .weight)
        ink = try? container.decodeIfPresent(ThemeInk.self, forKey: .ink)
        fontFamily = try? container.decodeIfPresent(String.self, forKey: .fontFamily)
        typeface = try? container.decodeIfPresent(AppTheme.Material.Typeface.self, forKey: .typeface)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(scale, forKey: .scale)
        try container.encodeIfPresent(weight, forKey: .weight)
        try container.encodeIfPresent(ink, forKey: .ink)
        try container.encodeIfPresent(fontFamily, forKey: .fontFamily)
        try container.encodeIfPresent(typeface, forKey: .typeface)
    }
}

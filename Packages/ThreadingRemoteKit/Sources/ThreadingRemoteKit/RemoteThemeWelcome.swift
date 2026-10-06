import Foundation

/// The theme's welcome as the phone's new-chat screen draws it: the Mac's `ThemeWelcome`
/// resolved for the variant it projects, with every ink a resolved colour and the picture
/// carried by the asset manifest (slot `welcome`) rather than here.
///
/// **What crosses.** The author's lines travel as written — text, conditions, weights — because
/// a line is picked and rendered on the *phone's* clock, calendar and locale with the shared
/// grammar (`ThemeWelcomeGrammar`); the Mac never renders one for it. Styles arrive resolved:
/// an ink is a hex colour, a font family is one the Mac could use, a typeface is a hint. The
/// backdrop's gradient and particles reuse the material's portable recipes.
///
/// **Who is greeted.** `user` is the Mac owner's given name, sent only to an owner's
/// connection and only when a line names `{user}`. A guest receives none, so on a guest's phone
/// every `{user}` line is ineligible, exactly as a `{project}` line is without a project.
///
/// **Tolerance.** Optional decoration from a newer Mac must never cost the palette. Each part
/// decodes on its own: an unreadable or out-of-range field is absent, a line that does not fit
/// the bounds is skipped without taking its pool, and the whole block is bounded in lines and
/// bytes before anything is built from it.
public struct RemoteThemeWelcome: Codable, Equatable, Sendable {

    // MARK: Limits

    public enum Limits {
        public static let maximumLines = ThemeWelcomeGrammar.Limits.maximumLines
        /// Entries examined per pool. Lines this build skips (a newer condition) do not end the
        /// list, so the scan needs its own bound, not just the result.
        public static let maximumExaminedLines = 2 * maximumLines
        public static let maximumLineCharacters = ThemeWelcomeGrammar.Limits.maximumLineLength
        /// A line is at most 160 characters; this bounds what is scanned to count them.
        public static let maximumLineBytes = 1_024
        /// Every line of both pools together. A full pool of plain lines is about 10 KB; this
        /// keeps a welcome-bearing theme comfortably inside the phone's 256 KB theme archive.
        public static let maximumTextBytes = 32 * 1_024
        public static let maximumFontFamilyBytes = 256
        public static let maximumUserBytes = 256
        /// `#RRGGBB` or `#RRGGBBAA`.
        public static let maximumInkBytes = 9
        public static let markSides: ClosedRange<Double> = 16...160
        public static let scales: ClosedRange<Double> = 0.5...3
        public static let scrimOpacities: ClosedRange<Double> = 0...0.9
    }

    // MARK: Vocabulary

    /// What stands above the greeting.
    public enum Mark: RemoteLosslessStringToken {
        /// The Threading mark.
        case app
        /// The theme's logo picture (asset slot `logo`), or the app's mark without one.
        case logo
        /// The theme's mascot in the catalogue's mood (`mascot.*`), or the app's mark without one.
        case mascot
        /// Nothing: the greeting stands alone. `none` on the wire.
        case hidden
        case unknown(String)

        public init(rawValue: String) {
            switch rawValue {
            case "app": self = .app
            case "logo": self = .logo
            case "mascot": self = .mascot
            case "none": self = .hidden
            default: self = .unknown(rawValue)
            }
        }

        public var rawValue: String {
            switch self {
            case .app: return "app"
            case .logo: return "logo"
            case .mascot: return "mascot"
            case .hidden: return "none"
            case let .unknown(value): return value
            }
        }
    }

    public enum Weight: RemoteLosslessStringToken {
        case light, regular, medium, semibold, bold, heavy
        case unknown(String)

        public init(rawValue: String) {
            switch rawValue {
            case "light": self = .light
            case "regular": self = .regular
            case "medium": self = .medium
            case "semibold": self = .semibold
            case "bold": self = .bold
            case "heavy": self = .heavy
            default: self = .unknown(rawValue)
            }
        }

        public var rawValue: String {
            switch self {
            case .light: return "light"
            case .regular: return "regular"
            case .medium: return "medium"
            case .semibold: return "semibold"
            case .bold: return "bold"
            case .heavy: return "heavy"
            case let .unknown(value): return value
            }
        }
    }

    /// How a greeting or caption is set, resolved by the Mac. Absent fields keep the phone's own.
    public struct Style: Codable, Equatable, Sendable {
        /// Relative to the phone's greeting (title) or caption (subheadline) size.
        public let scale: Double?
        public let weight: Weight?
        /// The ink resolved for the projected variant, `#RRGGBB(AA)`.
        public let ink: String?
        /// A family the Mac could use. Advisory, like the material's: the phone uses it only
        /// when the font arrived and registered, and falls back to `typeface` otherwise.
        public let fontFamily: String?
        public let typeface: RemoteThemeTypeface?

        public init(
            scale: Double? = nil,
            weight: Weight? = nil,
            ink: String? = nil,
            fontFamily: String? = nil,
            typeface: RemoteThemeTypeface? = nil
        ) {
            self.scale = scale.flatMap(Self.admittedScale)
            self.weight = weight
            self.ink = ink.flatMap(Self.admittedInk)
            self.fontFamily = fontFamily.flatMap(Self.admittedFamily)
            self.typeface = typeface
        }

        private enum CodingKeys: String, CodingKey { case scale, weight, ink, fontFamily, typeface }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                scale: try? values.decode(Double.self, forKey: .scale),
                weight: try? values.decode(Weight.self, forKey: .weight),
                ink: try? values.decode(String.self, forKey: .ink),
                fontFamily: try? values.decode(String.self, forKey: .fontFamily),
                typeface: try? values.decode(RemoteThemeTypeface.self, forKey: .typeface)
            )
        }

        public var isEmpty: Bool {
            scale == nil && weight == nil && ink == nil && fontFamily == nil && typeface == nil
        }

        private static func admittedScale(_ value: Double) -> Double? {
            value.isFinite && Limits.scales.contains(value) ? value : nil
        }

        private static func admittedInk(_ value: String) -> String? {
            value.hasPrefix("#") && value.utf8.count <= Limits.maximumInkBytes ? value : nil
        }

        private static func admittedFamily(_ value: String) -> String? {
            admittedName(value, maximumBytes: Limits.maximumFontFamilyBytes)
        }
    }

    /// A pool of lines, one of which the phone shows on each arrival.
    public struct Wording: Codable, Equatable, Sendable {
        public let lines: [ThemeWelcomeGrammar.Line]
        /// Whether the phone's own greeting stays in the pool beside the theme's. Greeting only.
        public let includesAppLines: Bool?
        public let style: Style?

        public init(lines: [ThemeWelcomeGrammar.Line], includesAppLines: Bool? = nil, style: Style? = nil) {
            self.lines = Array(lines.prefix(Limits.maximumExaminedLines).filter(Self.admits)
                .prefix(Limits.maximumLines))
            self.includesAppLines = includesAppLines == true ? true : nil
            self.style = style?.isEmpty == false ? style : nil
        }

        private enum CodingKeys: String, CodingKey { case lines, includesAppLines, style }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let lines = (try? values.decode(LineList.self, forKey: .lines))?.lines ?? []
            self.init(
                lines: lines,
                includesAppLines: try? values.decode(Bool.self, forKey: .includesAppLines),
                style: try? values.decode(Style.self, forKey: .style)
            )
        }

        public var includesHostLines: Bool { includesAppLines == true }

        /// The same shape with lines only while `budget` lasts, in order.
        func keeping(textBytes budget: inout Int) -> Wording {
            var kept: [ThemeWelcomeGrammar.Line] = []
            for line in lines {
                let bytes = line.text.utf8.count
                guard bytes <= budget else { break }
                budget -= bytes
                kept.append(line)
            }
            return Wording(lines: kept, includesAppLines: includesAppLines, style: style)
        }

        /// A line the grammar can hold: bounded text, a weight it counts, conditions in range.
        static func admits(_ line: ThemeWelcomeGrammar.Line) -> Bool {
            let text = line.text
            guard text.utf8.count <= Limits.maximumLineBytes, !text.isEmpty,
                  text.count <= Limits.maximumLineCharacters,
                  ThemeWelcomeGrammar.Limits.weights.contains(line.weight) else { return false }
            guard let when = line.when else { return true }
            return (when.hours?.isValid ?? true)
                && when.dates.count <= ThemeWelcomeGrammar.Limits.maximumDateSpans
                && when.months.allSatisfy(ThemeWelcomeGrammar.Limits.months.contains)
        }
    }

    /// Peak opacities of ground-coloured veils behind the hero and behind the composer.
    public struct Scrim: Codable, Equatable, Sendable {
        public let hero: Double?
        public let prompt: Double?

        public init(hero: Double? = nil, prompt: Double? = nil) {
            self.hero = hero.flatMap(Self.admitted)
            self.prompt = prompt.flatMap(Self.admitted)
        }

        private enum CodingKeys: String, CodingKey { case hero, prompt }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                hero: try? values.decode(Double.self, forKey: .hero),
                prompt: try? values.decode(Double.self, forKey: .prompt)
            )
        }

        public var isEmpty: Bool { hero == nil && prompt == nil }

        private static func admitted(_ value: Double) -> Double? {
            value.isFinite && Limits.scrimOpacities.contains(value) ? value : nil
        }
    }

    /// The screen's own ground: the portable gradient and particle recipes the material uses.
    /// A stated block replaces the material's decoration on the new-chat screen, even when it
    /// carries neither — a picture-only welcome is a `welcome` asset over a plain ground.
    public struct Backdrop: Codable, Equatable, Sendable {
        public let gradient: RemoteThemeGradient?
        public let particles: RemoteThemeParticles?

        public init(gradient: RemoteThemeGradient? = nil, particles: RemoteThemeParticles? = nil) {
            self.gradient = gradient?.hasValidGeometry == true ? gradient : nil
            self.particles = particles?.isValid == true ? particles : nil
        }

        private enum CodingKeys: String, CodingKey { case gradient, particles }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                gradient: try? values.decode(RemoteThemeGradient.self, forKey: .gradient),
                particles: try? values.decode(RemoteThemeParticles.self, forKey: .particles)
            )
        }
    }

    // MARK: Fields

    public let mark: Mark?
    /// The mark's side in points.
    public let markSize: Double?
    public let greeting: Wording?
    public let caption: Wording?
    public let scrim: Scrim?
    public let backdrop: Backdrop?
    /// The Mac owner's given name for `{user}`, on an owner's connection only.
    public let user: String?

    public init(
        mark: Mark? = nil,
        markSize: Double? = nil,
        greeting: Wording? = nil,
        caption: Wording? = nil,
        scrim: Scrim? = nil,
        backdrop: Backdrop? = nil,
        user: String? = nil
    ) {
        self.mark = mark
        self.markSize = markSize.flatMap { $0.isFinite && Limits.markSides.contains($0) ? $0 : nil }
        // One budget for both pools, greeting first: the line a person reads first keeps its
        // lines when an oversized caption would not fit beside it.
        var budget = Limits.maximumTextBytes
        self.greeting = greeting?.keeping(textBytes: &budget)
        self.caption = caption?.keeping(textBytes: &budget)
        self.scrim = scrim?.isEmpty == false ? scrim : nil
        self.backdrop = backdrop
        self.user = user.flatMap { admittedName($0, maximumBytes: Limits.maximumUserBytes) }
    }

    private enum CodingKeys: String, CodingKey {
        case mark, markSize, greeting, caption, scrim, backdrop, user
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            mark: try? values.decode(Mark.self, forKey: .mark),
            markSize: try? values.decode(Double.self, forKey: .markSize),
            greeting: try? values.decode(Wording.self, forKey: .greeting),
            caption: try? values.decode(Wording.self, forKey: .caption),
            scrim: try? values.decode(Scrim.self, forKey: .scrim),
            backdrop: try? values.decode(Backdrop.self, forKey: .backdrop),
            user: try? values.decode(String.self, forKey: .user)
        )
    }

    /// Nothing the phone would draw differently from its own new-chat screen.
    public var isEmpty: Bool {
        mark == nil && markSize == nil && greeting == nil && caption == nil
            && scrim == nil && backdrop == nil
    }

    /// Whether any of `lines` names `{user}`: the only case a name is worth sending.
    public static func namesUser(in lines: [ThemeWelcomeGrammar.Line]) -> Bool {
        lines.contains { line in
            ThemeWelcomeGrammar.Template.uses(line.text) { $0 == .user }
        }
    }
}

/// A name that is shown, never interpreted: bounded, non-empty and free of control characters.
private func admittedName(_ value: String, maximumBytes: Int) -> String? {
    guard !value.isEmpty, value.utf8.count <= maximumBytes,
          !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
    return value
}

/// A pool's lines decoded one entry at a time. An entry that does not decode — a condition a
/// newer Mac wrote — is skipped and never takes the rest of the pool with it. At most
/// `RemoteThemeWelcome.Limits.maximumExaminedLines` entries are examined.
private struct LineList: Decodable {
    let lines: [ThemeWelcomeGrammar.Line]

    private struct Skipped: Decodable {
        init(from decoder: Decoder) throws {}
    }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var lines: [ThemeWelcomeGrammar.Line] = []
        var examined = 0
        while !container.isAtEnd, examined < RemoteThemeWelcome.Limits.maximumExaminedLines {
            examined += 1
            if try container.decodeNil() { continue }
            if let line = try? container.decode(ThemeWelcomeGrammar.Line.self) {
                lines.append(line)
            } else {
                // A failed decode does not advance the container; consume the entry.
                _ = try container.decode(Skipped.self)
            }
        }
        self.lines = lines
    }
}

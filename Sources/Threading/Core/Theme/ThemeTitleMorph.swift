import Foundation

// MARK: - Theme Title Morph

/// How a theme would like names to change on screen — every session, project and checkout name
/// is a `MorphingTitleLabel` — and, for a scramble, which characters the decoder cycles through
/// before it settles: a hacker-movie theme decodes names from katakana, an airport theme from a
/// departures board's letters.
///
/// The theme states the *how*; the person's Motion setting decides *whether*. An explicit style
/// chosen there wins, and the default — "Theme's Choice" (`ChatNameMorphStyle.automatic`) —
/// takes the theme's. A scramble alphabet is honoured whenever the effective style is a scramble,
/// whoever chose it, because it says what a scramble looks like in this theme rather than
/// whether to scramble. Reduce Motion lands every name directly, as it always has.
public struct ThemeTitleMorph: Equatable {

    /// The transition the theme suggests. Never `.automatic`: a theme is the thing automatic
    /// defers to.
    public var style: ChatNameMorphStyle
    /// What a scramble cycles through, as one string of characters. Absent means the decoder's
    /// own Latin alphabet. Only meaningful for `.scramble`.
    public var characters: String?

    public init(style: ChatNameMorphStyle, characters: String? = nil) {
        self.style = style
        self.characters = characters
    }

    /// The scramble pool, cleaned: whitespace is never a glyph worth cycling through.
    public var scrambleCharacters: [Character]? {
        guard style == .scramble, let characters else { return nil }
        let pool = characters.filter { !$0.isWhitespace && !$0.isNewline }
        return pool.isEmpty ? nil : Array(pool)
    }
}

extension ThemeTitleMorph: Codable {
    private enum CodingKeys: String, CodingKey {
        case style, characters
    }

    /// A style this build does not know is refused rather than mapped onto a neighbour; the
    /// variant decoding it drops the block and keeps the rest of the theme.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decode(String.self, forKey: .style)
        guard let style = ChatNameMorphStyle(rawValue: raw), style != .automatic else {
            throw DecodingError.dataCorruptedError(
                forKey: .style,
                in: container,
                debugDescription: "Unknown title morph style \(raw)"
            )
        }
        self.style = style
        characters = try container.decodeIfPresent(String.self, forKey: .characters)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(style.rawValue, forKey: .style)
        try container.encodeIfPresent(characters, forKey: .characters)
    }
}

// MARK: - Limits

public enum ThemeTitleMorphLimits {
    /// Enough for an alphabet and its digits; a scramble picks one at random every tick, so a
    /// longer pool adds nothing a person could see.
    public static let maximumScrambleCharacters = 96
}

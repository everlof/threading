import Foundation

/// Turns the identifier a CLI stores into the name a person uses.
///
/// The composer offered "Default model", which names the *setting* rather than the answer —
/// the one thing a user wants from that chip is which model the session will actually run on,
/// and "Default" makes them go and look it up. Every identifier here comes from the user's own
/// config, so this only has to be readable, not exhaustive.
public enum ModelName {

    /// The suffix Claude uses for the long-context variant of a model.
    private static let longContextSuffix = "[1m]"
    private static let longContextLabel = "1M"

    /// Known families, longest first so `claude-fable-5` is matched before `claude`.
    ///
    /// A deliberately short table: an id it does not recognise is tidied rather than dropped,
    /// so a model released after this was written still reads as itself instead of as
    /// "Default".
    private static let families: [(id: String, name: String)] = [
        ("claude-fable-5", "Fable 5"),
        ("claude-opus-5", "Opus 5"),
        ("claude-opus-4-8", "Opus 4.8"),
        ("claude-sonnet-5", "Sonnet 5"),
        ("claude-haiku-4-5", "Haiku 4.5"),
        ("fable", "Fable"),
        ("opus", "Opus"),
        ("sonnet", "Sonnet"),
        ("haiku", "Haiku")
    ]

    /// The published tiers, most capable first.
    ///
    /// Declaration order *is* the order: `rawValue` is what sorts a model list, so a new tier is
    /// added in its place rather than given a number to remember. Anthropic's own tiering is what
    /// this follows — Fable above Opus above Sonnet above Haiku — which is also the order of the
    /// list prices, so the ranking is checkable against something outside this file.
    ///
    /// Deliberately families rather than versions: a menu ordered by dated version would put
    /// last year's Opus above this year's Sonnet, and would need editing on every release. The
    /// alias inside a family already tracks its latest.
    public enum Tier: Int, CaseIterable {
        case fable
        case opus
        case sonnet
        case haiku

        /// Every spelling that names this tier. Mythos is Fable's tier — the same capabilities at
        /// the same price through a different distribution — so it sorts as one.
        public var tokens: [String] {
            switch self {
            case .fable: return ["fable", "mythos"]
            case .opus: return ["opus"]
            case .sonnet: return ["sonnet"]
            case .haiku: return ["haiku"]
            }
        }
    }

    /// Which tier `identifier` belongs to, or nil for one no tier names.
    ///
    /// Containment, like `scope(_:meters:)` and for the same reason: the id a CLI hands us is
    /// `fable`, `claude-fable-5`, or `claude-fable-5[1m]` depending on where it was read, and a
    /// tier that only matched one spelling would sort the other two as unknown.
    ///
    /// Nil is a real answer and the one an organisation's own grant gets. It sorts *after* every
    /// named tier rather than being guessed into one: putting an unrecognised model above Opus
    /// on a hunch is worse than leaving it where the source listed it.
    public static func tier(of identifier: String) -> Tier? {
        let id = identifier.lowercased()
        return Tier.allCases.first { tier in
            tier.tokens.contains { id.contains($0) }
        }
    }

    /// `claude-fable-5[1m]` → `Fable 5 · 1M`, `opus[1m]` → `Opus · 1M`, `gpt-5-codex` →
    /// `gpt-5-codex`.
    public static func display(for identifier: String) -> String {
        var id = identifier.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return identifier }

        var suffix = ""
        if id.lowercased().hasSuffix(longContextSuffix) {
            id = String(id.dropLast(longContextSuffix.count))
            suffix = " · \(longContextLabel)"
        }

        let lowered = id.lowercased()
        if let family = families.first(where: { lowered == $0.id || lowered.hasPrefix($0.id) }) {
            return family.name + suffix
        }

        // Unknown: hand back what the config said. A wrong friendly name would be worse than
        // an unfamiliar accurate one, since this is the string that says what you are paying for.
        return id + suffix
    }

    /// Whether a rate limit scoped to `name` meters a session running `identifier`.
    ///
    /// The two vocabularies do not match on the nose and never will: a provider names the limit
    /// after the family it meters (`Fable`, `GPT-5.3-Codex-Spark`) while a session carries the
    /// id its CLI was launched with (`claude-fable-5[1m]`). Containment reads both, in the id
    /// and in the friendly name, so a limit matches the whole family rather than one dated
    /// version of it — which is the behaviour that survives the next model.
    ///
    /// Deliberately narrow in one direction: an unrecognised pairing is *not* a match, because a
    /// scoped limit wrongly applied would put a session in the red over a model it is not using.
    public static func scope(_ name: String, meters identifier: String) -> Bool {
        let scoped = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard !scoped.isEmpty else { return false }

        let id = identifier.trimmingCharacters(in: .whitespaces).lowercased()
        guard !id.isEmpty else { return false }

        return id.contains(scoped) || display(for: identifier).lowercased().contains(scoped)
    }
}
